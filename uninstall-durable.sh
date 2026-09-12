#!/usr/bin/env bash
# Reverts the system changes made by install-durable.sh.
#
# This does not uninstall the optional suspend/resume recovery. If that is
# still present, the shared detection helper and cache are deliberately kept.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/px13-detect.sh
. "$REPO/lib/px13-detect.sh"

UCM="${UCM_DIR:-/usr/share/alsa/ucm2}"
DKMS_NAME=snd-soc-tas2783-sdw-px13
DKMS_VER=1.0
MARKER=px13-audio-fix
RECOVERY_HOOK=/usr/lib/systemd/system-sleep/50-px13-soundwire
RECOVERY_SCRIPT=/usr/local/lib/px13-soundwire-recover.sh
DETECT=/usr/local/lib/px13-audio-detect.sh
CACHE=/etc/px13-audio-fix.conf
UDEV_RULE=90-px13-rt721-no-autosuspend.rules
ASSUME_YES=0

usage() {
	cat <<'EOF'
Usage: bash uninstall-durable.sh [--yes]

Revert the files and kernel module installed by install-durable.sh.
  --yes   do not ask for confirmation
  -h, --help

The separate suspend/resume recovery is left installed. Files modified after
installation are preserved and reported instead of being deleted.
EOF
}

case "${1:-}" in
	"") ;;
	--yes) ASSUME_YES=1 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

if [ "$ASSUME_YES" = 0 ]; then
	printf '%s\n' \
		'This will remove the PX13 DKMS/manual module and UCM files installed by' \
		'install-durable.sh, and the rt721 udev rule. The optional resume recovery will be kept.'
	printf 'Continue? [y/N] '
	read -r answer
	case "$answer" in [yY]|[yY][eE][sS]) ;; *) echo 'Cancelled.'; exit 0 ;; esac
fi

root_run() { px13_root_run "$@"; }
# Authenticate once before discovery commands are used in process substitutions.
root_run true

removed=0
preserved=0

remove_unchanged() { # source installed-path
	local source="$1" installed="$2"
	[ -e "$installed" ] || return 0
	if cmp -s "$source" "$installed"; then
		root_run rm -f -- "$installed"
		echo "    removed $installed"
		removed=$((removed + 1))
	else
		echo "    PRESERVED (content changed): $installed" >&2
		preserved=$((preserved + 1))
	fi
}

echo '==> 1/6 Removing UCM files'
# Regenerate each marked override from its driver directory and long-name file
# name. Search all drivers so cleanup also covers an earlier invocation on
# another SKU, but preserve an override if it was edited after installation.
while IFS= read -r -d '' file; do
	if grep -qF "$MARKER" "$file" 2>/dev/null; then
		driver="$(basename "$(dirname "$file")")"
		longname="$(basename "$file" .conf)"
		expected="$(mktemp)"
		sed -e "s|@DRIVER@|$driver|g" -e "s|@LONGNAME@|$longname|g" \
			"$REPO/configs/ucm-card-override.conf.in" > "$expected"
		if cmp -s "$expected" "$file"; then
			root_run rm -f -- "$file"
			echo "    removed $file"
			removed=$((removed + 1))
		else
			echo "    PRESERVED (content changed): $file" >&2
			preserved=$((preserved + 1))
		fi
		rm -f -- "$expected"
	fi
done < <(root_run find "$UCM/conf.d" -type f -name '*.conf' -print0 2>/dev/null)

remove_unchanged "$REPO/configs/sof-soundwire_tas2783.conf" "$UCM/sof-soundwire/tas2783.conf"
remove_unchanged "$REPO/configs/codecs_tas2783_init.conf" "$UCM/codecs/tas2783/init.conf"
root_run rmdir -- "$UCM/codecs/tas2783" 2>/dev/null || true

echo '==> 2/6 Removing the DKMS installation'
if command -v dkms >/dev/null 2>&1 && dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null | grep -q .; then
	root_run dkms remove "$DKMS_NAME/$DKMS_VER" --all
	removed=$((removed + 1))
	echo "    removed $DKMS_NAME/$DKMS_VER from DKMS"
else
	echo '    no registered DKMS installation found'
fi
if [ -d "/usr/src/$DKMS_NAME-$DKMS_VER" ]; then
	root_run rm -rf -- "/usr/src/$DKMS_NAME-$DKMS_VER"
	echo "    removed /usr/src/$DKMS_NAME-$DKMS_VER"
	removed=$((removed + 1))
fi

echo '==> 3/6 Removing manual module installations'
manual_removed=0
while IFS= read -r -d '' module; do
	root_run rm -f -- "$module"
	kernel="${module#/usr/lib/modules/}"
	kernel="${kernel%%/*}"
	root_run depmod -a "$kernel"
	echo "    removed $module"
	manual_removed=$((manual_removed + 1))
	removed=$((removed + 1))
done < <(root_run find /usr/lib/modules -path '*/updates/snd-soc-tas2783-sdw.ko' -type f -print0 2>/dev/null)
[ "$manual_removed" -gt 0 ] || echo '    no manual module installations found'

echo '==> 4/6 Cleaning shared metadata'
if [ -e "$RECOVERY_HOOK" ] || [ -e "$RECOVERY_SCRIPT" ]; then
	echo '    resume recovery is installed; keeping its shared helper and cache:'
	echo "      $DETECT"
	echo "      $CACHE"
else
	remove_unchanged "$REPO/lib/px13-detect.sh" "$DETECT"
	if [ -e "$CACHE" ]; then
		root_run rm -f -- "$CACHE"
		echo "    removed $CACHE"
		removed=$((removed + 1))
	fi
	root_run rmdir -- /usr/local/lib 2>/dev/null || true
fi

echo '==> 5/6 Removing the rt721 udev rule'
if [ -e "/etc/udev/rules.d/$UDEV_RULE" ]; then
	remove_unchanged "$REPO/$UDEV_RULE" "/etc/udev/rules.d/$UDEV_RULE"
	root_run udevadm control --reload
	# the live device keeps power/control=on until reboot; that is harmless
else
	echo '    no udev rule installed'
fi

echo '==> 6/6 Finishing'
echo "    removed items: $removed"
if [ "$preserved" -gt 0 ]; then
	echo "    WARNING: preserved modified files: $preserved" >&2
	echo '    Review the PRESERVED paths above manually.' >&2
fi
echo
echo 'The currently loaded tas2783 module is unchanged for safety.'
echo 'Reboot to load the stock kernel module and let PipeWire rebuild its profile.'
