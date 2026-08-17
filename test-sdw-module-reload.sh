#!/usr/bin/env bash
# Bring the internal audio back RIGHT NOW after a bad resume, without rebooting.
#
# Runs exactly the same recovery the sleep hook uses (full SoundWire/ACP module
# reload - a shallow PCI unbind/bind does not re-enumerate the slaves on kernel
# 7.1.5), then plays a test sound and reports SUCCESS/FAIL.
#
#   sudo ./test-sdw-module-reload.sh
#
# RISK: rmmod of a zombie audio stack can wedge the kernel (worst case = power
# button, which is the current fallback anyway).
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PX13_DETECT_LIB="$REPO/lib/px13-detect.sh"
# shellcheck source=lib/px13-detect.sh
. "$PX13_DETECT_LIB"

[ "$(id -u)" = 0 ] || { echo "run me with sudo"; exit 1; }

echo "=== before: $(px13_sdw_status_str)"
echo "=== ACP PCI: $(px13_acp_pci || echo '(not found)')"
echo "=== running the recovery (~30 s, audio drops out)..."
bash "$REPO/px13-soundwire-recover.sh"
echo "=== after : $(px13_sdw_status_str)"
echo "=== log ---"
tail -n 8 /var/log/px13-soundwire-resume.log 2>/dev/null | sed 's/^/    /'

if ! px13_sdw_all_attached; then
  echo ">>> FAILED: the codecs did not re-attach. Internal audio still needs a reboot."
  journalctl -k --since '-2 minutes' --no-pager | grep -iE 'sdw|soundwire|acp|snd' | tail -20
  exit 1
fi

UNAME="${SUDO_USER:-$(id -nu 1000)}"; RT="/run/user/$(id -u "$UNAME")"
ru() { runuser -u "$UNAME" -- env XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@"; }
sleep 2
SINK="$(px13_pw_speaker_sink_as ru)" || SINK=""
if [ -n "$SINK" ]; then
  echo ">>> playing a test sound on $SINK"
  ru pactl set-sink-mute "$SINK" 0 2>/dev/null || true
  ru paplay --device="$SINK" /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
else
  echo ">>> WARNING: bus is Attached but PipeWire shows no SoundWire sink"
fi
echo ">>> If you HEARD the sound on the internal speakers, the recovery works."
exit 0
