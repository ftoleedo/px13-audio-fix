# shellcheck shell=bash
# px13-audio-fix — runtime detection of the SoundWire audio hardware.
#
# WHY THIS FILE EXISTS
#   The first version of this repo hardcoded four machine-specific values that
#   turned out to differ between ProArt PX13 SKUs (and between kernels):
#
#     LONG  = ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC
#     CARD  = 1
#     PCARD = alsa_card.pci-0000_c4_00.5-platform-amd_sdw
#     PCI   = 0000:c4:00.5
#
#   The first one is the killer: ALSA UCM loads the override from
#   conf.d/<driver>/<CardLongName>.conf, and CardLongName is built from DMI.
#   On a HN7306EA (no trailing "C") the file installed under the HN7306EAC name
#   is simply never read -> no Speaker device -> "Dummy Output", with the
#   installer still exiting 0. Found by @jamescutts and pinpointed by @dmicheel
#   in https://github.com/CachyOS/linux-cachyos/issues/737
#
#   Nothing below may assume a card index, a PCI address or a model string.
#   Every value is probed; every probe has an env override for the odd case.
#
# Usage:  source "$(dirname "$0")/lib/px13-detect.sh"
# Overrides: PX13_CARD, PX13_LONGNAME, PX13_DRIVER, PX13_PCI, PX13_PW_CARD

px13_die() { echo "ERRO: $*" >&2; return 1; }

# Values written by the installer while the hardware was still healthy. Used
# ONLY as a last resort, because after a bad resume the card can be gone from
# /proc/asound and the PCI device unbound - i.e. exactly when live probing
# fails. The card INDEX is deliberately not cached: it is not stable.
PX13_CACHE="${PX13_CACHE:-/etc/px13-audio-fix.conf}"
px13_cache_get() { # $1 = key
	[ -r "$PX13_CACHE" ] || return 1
	sed -n "s/^$1=//p" "$PX13_CACHE" | tail -1 | grep . || return 1
}

# --- ALSA cards ------------------------------------------------------------
# "index<TAB>driver<TAB>longname" for every card, parsed from /proc/asound/cards:
#
#    1 [amdsoundwire   ]: amd-soundwire - amd-soundwire
#                         ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC
px13_cards() {
	[ -r /proc/asound/cards ] || return 1
	awk '
		/^[ ]*[0-9]+[ ]*\[/ {
			idx = $1 + 0
			p = index($0, "]: "); rest = substr($0, p + 3)
			q = index(rest, " - "); drv = (q ? substr(rest, 1, q - 1) : rest)
			if ((getline ln) > 0) {
				gsub(/^[ \t]+|[ \t]+$/, "", ln)
			} else ln = ""
			printf "%d\t%s\t%s\n", idx, drv, ln
		}
	' /proc/asound/cards
}

# Index of the AMD SoundWire card. Two independent signals, either is enough:
# the ALSA driver string mentions soundwire, or the card hangs off an "*sdw*"
# platform device in sysfs.
px13_find_card() {
	if [ -n "${PX13_CARD:-}" ]; then echo "$PX13_CARD"; return 0; fi
	local idx drv _ln dev
	while IFS=$'\t' read -r idx drv _ln; do
		case "$drv" in *[Ss]ound[Ww]ire*|*sdw*) echo "$idx"; return 0 ;; esac
		dev="$(readlink -f "/sys/class/sound/card$idx/device" 2>/dev/null || true)"
		case "$dev" in *sdw*) echo "$idx"; return 0 ;; esac
	done < <(px13_cards)
	return 1
}

px13_card_field() { # $1=index $2=field(2=driver,3=longname)
	local v
	v="$(px13_cards | awk -F'\t' -v i="$1" -v f="$2" '$1 == i { print $f; exit }')"
	[ -n "$v" ] || return 1
	echo "$v"
}

px13_card_driver() {
	[ -n "${PX13_DRIVER:-}" ] && { echo "$PX13_DRIVER"; return 0; }
	px13_card_field "$1" 2
}

# The exact string UCM uses as the override filename.
px13_card_longname() {
	[ -n "${PX13_LONGNAME:-}" ] && { echo "$PX13_LONGNAME"; return 0; }
	local ln
	ln="$(amixer -c "$1" info 2>/dev/null | awk -F"'" '/^Card /{print $4; exit}')"
	[ -n "$ln" ] || ln="$(px13_card_field "$1" 3)"
	[ -n "$ln" ] || return 1
	echo "$ln"
}

# " cfg-amp:2 mic:acp-dmic cfg-mics:1 hs:rt721"  — what UCM matches its regexes
# against. The missing " spk:tas2783" here is bug #1 of the README.
px13_card_components() {
	amixer -c "$1" info 2>/dev/null |
		sed -n "s/^[[:space:]]*Components[[:space:]]*:[[:space:]]*'\(.*\)'\$/\1/p"
}

# --- SoundWire peripherals -------------------------------------------------
# Slaves are "sdw:<link>:<mfg>:<part>:<class>[:<unique>]"; masters are
# "sdw-master-N-M" and must not be counted. 0102 = Texas Instruments.
px13_sdw_slaves() {
	local d
	for d in /sys/bus/soundwire/devices/sdw:*; do
		[ -e "$d/status" ] || continue
		echo "$d"
	done
}

px13_sdw_all_attached() {
	local d n=0 ok=1
	while read -r d; do
		[ -n "$d" ] || continue
		n=$((n + 1))
		[ "$(cat "$d/status" 2>/dev/null)" = "Attached" ] || ok=0
	done < <(px13_sdw_slaves)
	[ "$n" -ge 1 ] && [ "$ok" = 1 ]
}

px13_sdw_status_str() {
	local d s=""
	while read -r d; do
		[ -n "$d" ] || continue
		s="$s $(basename "$d" | cut -d: -f4,5)=$(cat "$d/status" 2>/dev/null)"
	done < <(px13_sdw_slaves)
	echo "${s:- (nenhum periferico no barramento)}"
}

# Is a TI amp on the bus? Works before the codec driver is even loaded.
# Always "amixer -D hw:N", never "-c N": the plain -c view goes through the UCM
# ctl remap, which renames/hides controls (see codecs/tas2783/init.conf).
px13_has_tas2783() {
	local card="${1:-}" d
	[ -n "$card" ] && amixer -D "hw:$card" controls 2>/dev/null | grep -q 'tas2783' && return 0
	for d in /sys/bus/soundwire/devices/sdw:*:0102:*; do
		[ -e "$d" ] && return 0
	done
	return 1
}

# How many amps expose controls (1, 2, ...). 0 = driver not loaded yet.
px13_amp_count() {
	amixer -D "hw:$1" controls 2>/dev/null \
		| sed -n "s/.*name='tas2783-\([0-9]\+\) .*/\1/p" | sort -un | wc -l
}

# --- PCI (ACP / SoundWire manager) -----------------------------------------
px13_acp_pci() {
	[ -n "${PX13_PCI:-}" ] && { echo "$PX13_PCI"; return 0; }
	local d card dev
	for d in /sys/bus/pci/drivers/snd_pci_ps/0000:*; do
		[ -e "$d" ] && { basename "$d"; return 0; }
	done
	# fallback: climb from the ALSA card to its first PCI parent
	card="$(px13_find_card)" || card=""
	dev=""
	[ -n "$card" ] && dev="$(readlink -f "/sys/class/sound/card$card/device" 2>/dev/null || true)"
	while [ -n "$dev" ] && [ "$dev" != "/" ]; do
		case "$(basename "$dev")" in
			[0-9a-f]*:[0-9a-f]*:[0-9a-f]*.[0-9]*)
				[ -e "/sys/bus/pci/devices/$(basename "$dev")" ] && { basename "$dev"; return 0; } ;;
		esac
		dev="$(dirname "$dev")"
	done
	px13_cache_get PX13_ACP_PCI
}

# --- PipeWire / PulseAudio names -------------------------------------------
# Everything here is derived from the live graph, never from a PCI address.
px13_pw_card() {
	[ -n "${PX13_PW_CARD:-}" ] && { echo "$PX13_PW_CARD"; return 0; }
	pactl list short cards 2>/dev/null | awk '/sdw/ { print $2; exit }'
}

px13_pw_speaker_sink() {
	local s
	s="$(pactl list short sinks 2>/dev/null | awk '/sdw/ && /[Ss]peaker/ { print $2; exit }')"
	[ -n "$s" ] || s="$(pactl list short sinks 2>/dev/null | awk '/sdw/ { print $2; exit }')"
	[ -n "$s" ] || return 1
	echo "$s"
}

# Same, but running as root on behalf of a session user (resume hook).
px13_pw_card_as() { # $1 = runner function name
	"$1" pactl list short cards 2>/dev/null | awk '/sdw/ { print $2; exit }'
}
px13_pw_speaker_sink_as() { # $1 = runner function name
	local s
	s="$("$1" pactl list short sinks 2>/dev/null | awk '/sdw/ && /[Ss]peaker/ { print $2; exit }')"
	[ -n "$s" ] || s="$("$1" pactl list short sinks 2>/dev/null | awk '/sdw/ { print $2; exit }')"
	[ -n "$s" ] || return 1
	echo "$s"
}
