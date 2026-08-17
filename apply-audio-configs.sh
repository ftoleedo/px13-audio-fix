#!/bin/bash
# LEGACY (kernels < 7.1, nealstar's patched kernel). On a stock kernel >= 7.1
# use install-durable.sh instead - it is SKU-independent and validates itself.
#
# Apply userspace TAS2783 configs (run AFTER rebooting into the patched kernel).
#
# Repo: https://github.com/ftoleedo/px13-audio-fix
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$SCRIPT_DIR/configs"
# shellcheck source=lib/px13-detect.sh
. "$SCRIPT_DIR/lib/px13-detect.sh"

CARD="$(px13_find_card)" || { echo "ERROR: no SoundWire ALSA card found"; exit 1; }
echo "==> Using ALSA card $CARD ($(px13_card_longname "$CARD" || echo '?'))"

if [ ! -d "$CONF_DIR" ]; then
    echo "ERROR: $CONF_DIR not found. Run this script from the cloned repo root."
    exit 1
fi

echo "==> Verifying the kernel has the patched controls..."
if ! amixer -c"$CARD" contents 2>/dev/null | grep -q "tas2783-1 Speaker Playback Switch"; then
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
PWCARD="$(px13_pw_card)" || PWCARD=""
if [ -n "$PWCARD" ]; then
    pactl set-card-profile "$PWCARD" HiFi || \
        echo "  (profile switch failed — check 'pactl list cards' manually)"
else
    echo "  (no SoundWire card in PipeWire — check 'pactl list cards')"
fi

sleep 1
echo ""
echo "==> Setting Speaker as default sink..."
if SPEAKER_SINK="$(px13_pw_speaker_sink)"; then
    SPEAKER_ID=$(pactl list short sinks | awk -v s="$SPEAKER_SINK" '$2 == s { print $1; exit }')
    wpctl set-default "$SPEAKER_ID"
    echo "  default sink = $SPEAKER_ID ($SPEAKER_SINK)"
else
    echo "  WARN: no SoundWire speaker sink found"
fi

echo ""
echo "==> Setting channel mapping (tas2783-1=Left, tas2783-2=Right)..."
amixer -c"$CARD" cset name='tas2783-1 Channel Playback' Left  > /dev/null
amixer -c"$CARD" cset name='tas2783-2 Channel Playback' Right > /dev/null
amixer -c"$CARD" cset name='tas2783-1 Amp Playback Switch' on     > /dev/null
amixer -c"$CARD" cset name='tas2783-1 Speaker Playback Switch' on > /dev/null
amixer -c"$CARD" cset name='tas2783-2 Amp Playback Switch' on     > /dev/null
amixer -c"$CARD" cset name='tas2783-2 Speaker Playback Switch' on > /dev/null

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
echo "  amixer -c$CARD cset name='tas2783-1 Channel Playback' Right"
echo "  amixer -c$CARD cset name='tas2783-2 Channel Playback' Left"
echo "  sudo alsactl store"
