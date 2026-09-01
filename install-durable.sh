#!/usr/bin/env bash
# Durable installer for the internal speakers of the ASUS ProArt PX13 (TAS2783).
# For STOCK kernels >= 7.1 (upstream tas2783 driver).
#
#   bash install-durable.sh          # asks for sudo when it needs it
#   sudo bash install-durable.sh     # also fine - drops back to $SUDO_USER
#                                    # for the PipeWire steps
#
# SKU-independent by design: the ALSA card index, the card long name, the ACP
# PCI address and the PipeWire card name are all PROBED at install time. An
# earlier version hardcoded them for a HN7306EAC and failed silently on every
# other SKU (HN7306EA, HN7306EA-LX005X) - see lib/px13-detect.sh.
#
# Escape hatches (rarely needed): PX13_CARD, PX13_LONGNAME, PX13_DRIVER,
# PX13_USER (who owns the desktop session, when started as root).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/px13-detect.sh
. "$REPO/lib/px13-detect.sh"

UCM="${UCM_DIR:-/usr/share/alsa/ucm2}"
DKMS_NAME=snd-soc-tas2783-sdw-px13
DKMS_VER=1.0
KREL="$(uname -r)"
MARKER="px13-audio-fix"

fail() { echo; echo "FAILED: $*" >&2; exit 1; }

# System steps go through root_run (sudo, or straight through when already
# root); session steps go through asuser (never as root).
px13_init_privs || fail "started as root with no desktop session to fall back to.
    'systemctl --user' does not exist for root, so the PipeWire half of this
    installer cannot run. Either:
      bash install-durable.sh                      (recommended - I sudo myself)
      sudo PX13_USER=<youruser> bash install-durable.sh"
root_run() { px13_root_run "$@"; }
asuser()   { px13_asuser "$@"; }
SESSION_OK=1; px13_session_ok || SESSION_OK=0

echo "==> 0/8 Detecting the hardware (nothing below is hardcoded)"
CARD="$(px13_find_card)" || fail "no SoundWire ALSA card found.
    'cat /proc/asound/cards' shows no card whose driver mentions soundwire.
    Is snd_pci_ps loaded? Is this really a SoundWire machine?"
DRIVER="$(px13_card_driver "$CARD")" || fail "could not read the ALSA driver name of card $CARD"
LONG="$(px13_card_longname "$CARD")" || fail "could not read the CardLongName of card $CARD.
    UCM keys its override file on that exact string; without it nothing can be installed."
COMPONENTS="$(px13_card_components "$CARD")"

printf '    card index    : %s\n'   "$CARD"
printf '    ALSA driver   : %s\n'   "$DRIVER"
printf '    CardLongName  : %s\n'   "$LONG"
printf '    components    : %s\n'   "${COMPONENTS:-(empty)}"
printf '    UCM override  : %s\n'   "$UCM/conf.d/$DRIVER/$LONG.conf"
[ -n "$PX13_SESSION_USER" ] && printf '    running as    : root (PipeWire steps as %s)\n' "$PX13_SESSION_USER"
[ "$SESSION_OK" = 0 ] && printf '    WARNING       : no session bus at %s - userspace steps will be skipped\n' "$PX13_SESSION_RT/bus"

px13_has_tas2783 "$CARD" || fail "no TAS2783 amplifier found on this machine.
    Neither a 'tas2783-*' mixer control nor a TI (0102) SoundWire peripheral is
    present. This repo would not fix anything here."

[ -f "$UCM/conf.d/$DRIVER/$DRIVER.conf" ] || fail "base UCM config not found:
    $UCM/conf.d/$DRIVER/$DRIVER.conf
    The override includes it. Install/upgrade alsa-ucm-conf (>= 1.2.13)."

echo "==> 1/8 Kernel module with the 'Channel Playback' control (needs root)"
if command -v dkms >/dev/null 2>&1; then
  # drop an older manual install so it does not compete with the dkms one
  root_run rm -f "/usr/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
  root_run mkdir -p "/usr/src/$DKMS_NAME-$DKMS_VER"
  root_run cp -f "$REPO/module/tas2783-sdw.c" "$REPO/module/tas2783.h" \
                 "$REPO/module/Makefile" "$REPO/module/dkms.conf" \
                 "/usr/src/$DKMS_NAME-$DKMS_VER/"
  root_run dkms install --force "$DKMS_NAME/$DKMS_VER" -k "$KREL"
  echo "    OK via DKMS (rebuilds itself on every kernel update)"
else
  echo "    dkms not found - manual build (redo it after every kernel update!)"
  ( cd "$REPO/module" && make KVER="$KREL" )
  root_run install -Dm644 "$REPO/module/snd-soc-tas2783-sdw.ko" \
       "/usr/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
  root_run depmod -a "$KREL"
fi

echo "==> 2/8 UCM blocks (needs root)"
OVERRIDE="$UCM/conf.d/$DRIVER/$LONG.conf"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
sed -e "s|@DRIVER@|$DRIVER|g" -e "s|@LONGNAME@|$LONG|g" \
    "$REPO/configs/ucm-card-override.conf.in" > "$TMP"
root_run install -Dm644 "$REPO/configs/sof-soundwire_tas2783.conf" "$UCM/sof-soundwire/tas2783.conf"
root_run install -Dm644 "$REPO/configs/codecs_tas2783_init.conf"   "$UCM/codecs/tas2783/init.conf"
root_run install -Dm644 "$TMP" "$OVERRIDE"
echo "    OK (unowned override in conf.d/$DRIVER/ -> survives package updates)"

# An override installed under a DIFFERENT long name (e.g. copied from a
# HN7306EAC guide onto a HN7306EA) is dead weight: UCM never reads it. Remove
# the ones this repo wrote, keep everything else untouched.
for f in "$UCM/conf.d/$DRIVER"/*.conf; do
  [ -f "$f" ] || continue
  [ "$f" = "$OVERRIDE" ] && continue
  if grep -q "$MARKER" "$f" 2>/dev/null; then
    root_run rm -f "$f"
    echo "    removed stale override for another SKU: $(basename "$f")"
  fi
done

# Detection helper + a cache of the values that are hard to probe once the
# hardware has already fallen off the bus (used by the resume recovery).
root_run install -Dm644 "$REPO/lib/px13-detect.sh" /usr/local/lib/px13-audio-detect.sh
PCI="$(px13_acp_pci)" || PCI=""
printf '# generated by px13-audio-fix on %s - do not edit by hand\nPX13_ACP_PCI=%s\nPX13_CARD_LONGNAME=%s\n' \
  "$(date '+%F %T')" "$PCI" "$LONG" | root_run tee /etc/px13-audio-fix.conf >/dev/null
echo "    cached: ACP PCI=${PCI:-?} -> /etc/px13-audio-fix.conf"

echo "==> 3/8 Activating the fixed module"
NEED_REBOOT=0
if ! amixer -D "hw:$CARD" controls 2>/dev/null | grep -q 'Channel Playback'; then
  [ "$SESSION_OK" = 1 ] && asuser systemctl --user stop wireplumber pipewire pipewire-pulse 2>/dev/null || true
  if root_run modprobe -r snd_soc_tas2783_sdw 2>/dev/null && root_run modprobe snd_soc_tas2783_sdw; then
    echo "    module reloaded live"
    sleep 2
  else
    NEED_REBOOT=1
    echo "    could not reload live - REBOOT at the end"
  fi
else
  echo "    control already present (fixed module already loaded)"
fi

echo "==> 4/8 Validating the UCM parse (must list 'Speaker')"
UCM_DEVS="$(alsaucm -c "$CARD" list _devices/HiFi 2>&1)" || true
echo "$UCM_DEVS" | sed 's/^/    /'
if ! echo "$UCM_DEVS" | grep -qw 'Speaker'; then
  echo
  echo "    diagnostics:" >&2
  echo "      installed override : $OVERRIDE" >&2
  echo "      exists             : $([ -f "$OVERRIDE" ] && echo yes || echo NO)" >&2
  echo "      CardLongName       : $LONG" >&2
  echo "      components         : ${COMPONENTS:-(empty)}" >&2
  fail "UCM still exposes no Speaker device for card $CARD.
    This is exactly the silent failure this installer now refuses to hide.
    Re-run with the long name forced if you believe the probe is wrong:
      PX13_LONGNAME='<name>' bash install-durable.sh
    and open an issue with the diagnostics above."
fi
echo "    OK - Speaker device present"

if [ "$SESSION_OK" = 0 ]; then
  echo "==> 5-8/8 SKIPPED: no desktop session bus reachable from here."
  echo
  echo "The system side is installed. Finish it from your own session with:"
  echo "  systemctl --user restart wireplumber pipewire pipewire-pulse"
  echo "  bash $REPO/install-durable.sh     # (re-run, it is idempotent)"
  exit 0
fi

echo "==> 5/8 Restarting PipeWire and selecting the HiFi profile"
asuser systemctl --user restart wireplumber pipewire pipewire-pulse
sleep 3
PCARD="$(px13_pw_card_as asuser)" || true
if [ -n "${PCARD:-}" ]; then
  echo "    PipeWire card: $PCARD"
  asuser pactl set-card-profile "$PCARD" HiFi 2>/dev/null || echo "    (profile switch failed - check 'pactl list cards')"
else
  echo "    WARNING: no SoundWire card in PipeWire yet"
fi
sleep 2

echo "==> 6/8 State (expected: Attached, channels 1/2, Speaker sink)"
echo "    soundwire:$(px13_sdw_status_str)"
AMPS="$(px13_amp_count "$CARD")"
for n in $(seq 1 "${AMPS:-0}"); do
  amixer -D "hw:$CARD" cget name="tas2783-$n Channel Playback" 2>/dev/null | tail -1 | sed "s/^/    tas2783-$n:/"
done
[ "${AMPS:-0}" -lt 2 ] && echo "    note: only $AMPS amp(s) with controls - stereo assignment skipped"
asuser wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' | sed 's/^/    /' || true
if SPK="$(px13_pw_speaker_sink_as asuser)"; then
  ID="$(asuser pactl list short sinks 2>/dev/null | awk -v s="$SPK" '$2 == s { print $1; exit }')" || ID=""
  [ -n "$ID" ] && asuser wpctl set-default "$ID" 2>/dev/null || true
  echo "    default sink = $SPK"
  # A sink at 0% is the "everything looks right and nothing comes out" trap:
  # WirePlumber persists a per-route volume, and a driver/control change under
  # it (a kernel update swapping the module) can leave that stored volume at
  # zero. Unmute and lift it only when it is at rock bottom - never touch a
  # volume the user actually chose.
  asuser pactl set-sink-mute "$SPK" 0 2>/dev/null || true
  VOL="$(asuser pactl get-sink-volume "$SPK" 2>/dev/null | sed -n 's/.*\/ *\([0-9]\+\)%.*/\1/p' | head -1)" || VOL=""
  if [ -n "${VOL:-}" ] && [ "$VOL" -eq 0 ] 2>/dev/null; then
    asuser pactl set-sink-volume "$SPK" 60% 2>/dev/null || true
    echo "    speaker volume was 0% (silent sink) -> raised to 60%"
  fi
fi

echo "==> 7/8 Persisting the ALSA state"
root_run alsactl store || true

echo "==> 8/8 Done"
echo
if [ "$NEED_REBOOT" = 1 ]; then
  echo "REBOOT, then run: speaker-test -D pulse -c2 -l1 -t wav"
else
  echo "SOUND TEST (stereo: 'Front Left' on the left, 'Front Right' on the right):"
  asuser speaker-test -D pulse -c2 -l1 -t wav 2>/dev/null | grep Front || true
  echo
  echo "If the sides come out swapped, swap the two csets in"
  echo "  $UCM/sof-soundwire/tas2783.conf  (1 <-> 2)  and run:"
  echo "  systemctl --user restart pipewire wireplumber"
fi
echo
echo "Suspend/resume recovery is a separate, optional step:"
echo "  bash install-resume-recovery.sh"
