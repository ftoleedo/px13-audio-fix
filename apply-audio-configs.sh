#!/bin/bash
# Apply userspace TAS2783 configs (run AFTER rebooting into the new patched kernel).
#
# Repo: https://github.com/YOURUSER/px13-audio-fix
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$SCRIPT_DIR/configs"

if [ ! -d "$CONF_DIR" ]; then
    echo "ERROR: $CONF_DIR not found. Run this script from the cloned repo root."
    exit 1
fi

echo "==> Verifying the kernel has the patched controls..."
if ! amixer -c1 contents 2>/dev/null | grep -q "tas2783-1 Speaker Playback Switch"; then
    echo "ERROR: control 'tas2783-1 Speaker Playback Switch' not found."
    echo "       Did you reboot into the patched kernel?"
    echo "       uname -r: $(uname -r)"
    exit 1
fi
echo "OK: patched controls present"

echo ""
echo "==> Installing UCM configs..."
sudo install -d /usr/share/alsa/ucm2/codecs/tas2783
sudo install -m644 "$CONF_DIR/codecs_tas2783_init.conf"   /usr/share/alsa/ucm2/codecs/tas2783/init.conf
sudo install -m644 "$CONF_DIR/sof-soundwire_tas2783.conf" /usr/share/alsa/ucm2/sof-soundwire/tas2783.conf
sudo install -m644 "$CONF_DIR/sof-soundwire_acp-dmic.conf" /usr/share/alsa/ucm2/sof-soundwire/acp-dmic.conf

echo ""
echo "==> Updating regex in sof-soundwire.conf (adds tas2783(-1)?)..."
SOF_CONF=/usr/share/alsa/ucm2/sof-soundwire/sof-soundwire.conf
if ! grep -q "tas2783" "$SOF_CONF"; then
    sudo cp "$SOF_CONF" "$SOF_CONF.bak.$(date +%s)"
    sudo sed -i 's|Regex "(rt1318(-1)?\|cs35l56(-bridge)?)"|Regex "(rt1318(-1)?\|cs35l56(-bridge)?\|tas2783(-1)?)"|' "$SOF_CONF"
    echo "  regex updated"
else
    echo "  regex already contains tas2783, skipping"
fi

echo ""
echo "==> Disabling old WirePlumber pro-audio override (if present)..."
for f in ~/.config/wireplumber/wireplumber.conf.d/*pro-audio*.conf \
         ~/.config/wireplumber/wireplumber.conf.d/51-strix-halo-audio.conf; do
    if [ -f "$f" ]; then
        mv "$f" "$f.disabled"
        echo "  disabled: $(basename "$f")"
    fi
done

echo ""
echo "==> Installing WirePlumber 51-amd-sdw-channels.conf..."
mkdir -p ~/.config/wireplumber/wireplumber.conf.d/
install -m644 "$CONF_DIR/51-amd-sdw-channels.conf" ~/.config/wireplumber/wireplumber.conf.d/

echo ""
echo "==> Installing PipeWire 99-echo-cancel.conf..."
mkdir -p ~/.config/pipewire/pipewire.conf.d/
install -m644 "$CONF_DIR/99-echo-cancel.conf" ~/.config/pipewire/pipewire.conf.d/

echo ""
echo "==> Restarting PipeWire/WirePlumber..."
systemctl --user restart pipewire pipewire-pulse wireplumber

sleep 2
echo ""
echo "==> Switching card profile to HiFi..."
pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw HiFi || \
    echo "  (profile switch failed — check 'pactl list cards' manually)"

sleep 1
echo ""
echo "==> Setting Speaker as default sink..."
SPEAKER_ID=$(wpctl status | awk '/Audio Coprocessor Speaker/ {gsub(/[^0-9]/,"",$1); print $1; exit}')
if [ -n "$SPEAKER_ID" ]; then
    wpctl set-default "$SPEAKER_ID"
    echo "  default sink = $SPEAKER_ID (Audio Coprocessor Speaker)"
else
    echo "  WARN: Audio Coprocessor Speaker not found in wpctl status"
fi

echo ""
echo "==> Setting channel mapping (tas2783-1=Left, tas2783-2=Right)..."
amixer -c1 cset name='tas2783-1 Channel Playback' Left  > /dev/null
amixer -c1 cset name='tas2783-2 Channel Playback' Right > /dev/null
amixer -c1 cset name='tas2783-1 Amp Playback Switch' on     > /dev/null
amixer -c1 cset name='tas2783-1 Speaker Playback Switch' on > /dev/null
amixer -c1 cset name='tas2783-2 Amp Playback Switch' on     > /dev/null
amixer -c1 cset name='tas2783-2 Speaker Playback Switch' on > /dev/null

echo ""
echo "==> Persisting ALSA state (channels, switches, volumes)..."
sudo alsactl store

echo ""
echo "==> Sinks now:"
wpctl status | grep -A6 "Sinks:" | head -10

echo ""
echo "DONE. Test with:"
echo "  paplay /usr/share/sounds/freedesktop/stereo/bell.oga"
echo "  speaker-test -D pulse -c 2 -l 1 -t wav"
echo ""
echo "If 'Front Left' comes from the right speaker (channels swapped on your hardware), run:"
echo "  amixer -c1 cset name='tas2783-1 Channel Playback' Right"
echo "  amixer -c1 cset name='tas2783-2 Channel Playback' Left"
echo "  sudo alsactl store"
