#!/usr/bin/env bash
# Verify the four invariants this fix depends on. Run it after a kernel or
# alsa-ucm-conf update - each of these has already failed silently at least
# once, leaving audio degraded with nothing in the logs.
#
#   bash check-audio.sh          # prints PASS/FAIL per check, exits 1 on any FAIL
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/px13-detect.sh
. "$REPO/lib/px13-detect.sh"

RC=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        -> %s\n' "$2"; RC=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }

echo "px13-audio-fix - health check on kernel $(uname -r)"
echo

CARD="$(px13_find_card)" || { bad "SoundWire card present" "no card in /proc/asound whose driver mentions soundwire"; exit 1; }
ok "SoundWire card present (card $CARD, $(px13_card_longname "$CARD" || echo '?'))"

# 1. the patched module, not the stock one -----------------------------------
MODPATH="$(modinfo -k "$(uname -r)" snd_soc_tas2783_sdw -F filename 2>/dev/null)"
case "$MODPATH" in
  */updates/*) ok "patched module installed ($MODPATH)" ;;
  "")          bad "patched module installed" "snd_soc_tas2783_sdw not found for this kernel" ;;
  *)           bad "patched module installed" "stock module in use ($MODPATH).
           A kernel update rebuilt nothing. Check: dkms status
           Then: bash install-durable.sh" ;;
esac

if command -v dkms >/dev/null 2>&1; then
  DK="$(dkms status snd-soc-tas2783-sdw-px13 2>/dev/null | grep -c "$(uname -r).*installed")"
  [ "${DK:-0}" -ge 1 ] && ok "DKMS built for this kernel" \
    || bad "DKMS built for this kernel" "dkms status shows no 'installed' line for $(uname -r).
           Usually the driver API moved upstream; see /var/lib/dkms/snd-soc-tas2783-sdw-px13/1.0/build/make.log"
fi

# 2. the per-amp channel control ---------------------------------------------
AMPS="$(px13_amp_count "$CARD")"
CH="$(amixer -D "hw:$CARD" controls 2>/dev/null | grep -c 'Channel Playback')"
if [ "${CH:-0}" -ge 2 ]; then
  V1="$(amixer -D "hw:$CARD" cget name='tas2783-1 Channel Playback' 2>/dev/null | sed -n 's/^ *: values=//p')"
  V2="$(amixer -D "hw:$CARD" cget name='tas2783-2 Channel Playback' 2>/dev/null | sed -n 's/^ *: values=//p')"
  if [ "${V1:-0}" != "${V2:-0}" ] && [ "${V1:-0}" != 0 ] && [ "${V2:-0}" != 0 ]; then
    ok "stereo channel assignment (amp1=$V1 amp2=$V2, 1=Left 2=Right)"
  else
    bad "stereo channel assignment" "both amps on the same channel (amp1=${V1:-?} amp2=${V2:-?}) -> mono.
           Reapply the profile: systemctl --user restart wireplumber pipewire"
  fi
elif [ "${AMPS:-0}" -lt 2 ]; then
  warn "only ${AMPS:-0} amp(s) with controls - single-amp variant, mono is expected"
else
  # "installed on disk" and "running in memory" are different things: modprobe -r
  # fails while the stack is in use, so a fresh install can sit there unloaded.
  MEM="$(cat /sys/module/snd_soc_tas2783_sdw/srcversion 2>/dev/null)"
  DISK="$(modinfo -k "$(uname -r)" snd_soc_tas2783_sdw -F srcversion 2>/dev/null)"
  if [ -n "$MEM" ] && [ -n "$DISK" ] && [ "$MEM" != "$DISK" ]; then
    bad "stereo channel assignment" "the patched module is installed but the OLD one is still in memory
           (srcversion $MEM in memory vs $DISK on disk).
           Reboot, or reload the whole stack: sudo bash test-sdw-module-reload.sh"
  else
    bad "stereo channel assignment" "no 'Channel Playback' control: the stock driver is loaded, not the patched one."
  fi
fi

# 3. UCM exposes a Speaker device --------------------------------------------
if alsaucm -c "$CARD" list _devices/HiFi 2>/dev/null | grep -qw Speaker; then
  ok "UCM exposes a Speaker device"
else
  bad "UCM exposes a Speaker device" "the long-name override is missing or under another SKU's name.
           Run: bash install-durable.sh"
fi

# 4. the sink is actually audible --------------------------------------------
if SINK="$(px13_pw_speaker_sink)"; then
  MUTE="$(pactl get-sink-mute "$SINK" 2>/dev/null | awk '{print $2}')"
  VOL="$(pactl get-sink-volume "$SINK" 2>/dev/null | sed -n 's/.*\/ *\([0-9]\+\)%.*/\1/p' | head -1)"
  if [ "${MUTE:-no}" = yes ]; then
    bad "speaker sink audible" "sink is muted: pactl set-sink-mute $SINK 0"
  elif [ -n "${VOL:-}" ] && [ "$VOL" -eq 0 ] 2>/dev/null; then
    bad "speaker sink audible" "sink volume is 0% - silent while everything else looks right.
           Fix: pactl set-sink-volume $SINK 60%"
  else
    ok "speaker sink audible (volume ${VOL:-?}%, not muted)"
  fi
else
  bad "speaker sink audible" "PipeWire shows no SoundWire speaker sink"
fi

echo
[ "$RC" = 0 ] && echo "All good. Play something: speaker-test -D pulse -c2 -l1 -t wav" \
              || echo "Something is off - see the arrows above."
exit "$RC"
