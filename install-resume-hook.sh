#!/usr/bin/env bash
# Instala o hook de resume do SoundWire e testa a recuperacao SEM precisar suspender.
#   bash install-resume-hook.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK=/usr/lib/systemd/system-sleep/50-px13-soundwire

echo "==> Instalando hook em $HOOK (sudo)"
sudo install -Dm755 "$REPO/50-px13-soundwire" "$HOOK"
echo "    OK"

echo
echo "==> TESTE a seco: roda a recuperacao agora (com o barramento JA saudavel)."
echo "    Se sobreviver = o mecanismo de rebind funciona; logo funcionara no resume."
echo "    --- antes ---"
for d in /sys/bus/soundwire/devices/sdw:0:1:*; do echo "    $(basename "$d"): $(cat "$d/status")"; done
echo "    --- executando rebind (post/suspend simulado) ---"
sudo "$HOOK" post suspend
echo "    --- log ---"
sudo tail -n 8 /var/log/px13-soundwire-resume.log 2>/dev/null | sed 's/^/    /'
echo "    --- depois (esperado: todos Attached) ---"
for d in /sys/bus/soundwire/devices/sdw:0:1:*; do echo "    $(basename "$d"): $(cat "$d/status")"; done

echo
echo "==> Reativando profile/som apos o rebind"
sleep 1
SINK=alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink
pactl set-card-profile alsa_card.pci-0000_c4_00.5-platform-amd_sdw HiFi 2>/dev/null || true
sleep 1
pactl set-default-sink "$SINK" 2>/dev/null || true
pactl set-sink-mute "$SINK" 0 2>/dev/null || true
echo "    tocando teste pos-rebind..."
paplay --device="$SINK" /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true

echo
echo "Ouviu som apos o rebind? Se SIM, o hook esta validado."
echo "Confirmacao final: feche e abra a tampa (deixe suspender/acordar) e teste o som —"
echo "o hook roda sozinho no resume."
