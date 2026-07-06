#!/usr/bin/env bash
# Instalador DURAVEL do som interno do ProArt PX13 (TAS2783).
# Para kernels STOCK >= 7.1 (driver tas2783 upstream). Roda como usuario
# normal; pede sudo internamente quando precisa.
#   bash install-durable.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UCM=/usr/share/alsa/ucm2
LONG="ASUSTeKCOMPUTERINC.-ProArtPX13HN7306EAC-1.0-HN7306EAC"
CARD=1
PCARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
DKMS_NAME=snd-soc-tas2783-sdw-px13
DKMS_VER=1.0
KREL="$(uname -r)"

echo "==> 1/7 Modulo do kernel com controle 'Channel Playback' (precisa sudo)"
if command -v dkms >/dev/null 2>&1; then
  # remove instalacao manual antiga p/ nao competir com a do dkms
  sudo rm -f "/usr/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
  sudo mkdir -p "/usr/src/$DKMS_NAME-$DKMS_VER"
  sudo cp -f "$REPO/module/tas2783-sdw.c" "$REPO/module/tas2783.h" \
             "$REPO/module/Makefile" "$REPO/module/dkms.conf" \
             "/usr/src/$DKMS_NAME-$DKMS_VER/"
  sudo dkms install --force "$DKMS_NAME/$DKMS_VER" -k "$KREL"
  echo "    OK via DKMS (recompila sozinho a cada update de kernel)"
else
  echo "    dkms nao encontrado — build manual (refazer a cada update de kernel!)"
  ( cd "$REPO/module" && make KVER="$KREL" LLVM=1 )
  sudo install -Dm644 "$REPO/module/snd-soc-tas2783-sdw.ko" \
       "/usr/lib/modules/$KREL/updates/snd-soc-tas2783-sdw.ko"
  sudo depmod -a "$KREL"
fi

echo "==> 2/7 Blocos UCM (precisa sudo)"
sudo install -Dm644 "$REPO/configs/sof-soundwire_tas2783.conf"  "$UCM/sof-soundwire/tas2783.conf"
sudo install -Dm644 "$REPO/configs/codecs_tas2783_init.conf"    "$UCM/codecs/tas2783/init.conf"
sudo install -Dm644 "$REPO/configs/px13-longname-override.conf" "$UCM/conf.d/amd-soundwire/$LONG.conf"
echo "    OK (override unowned em conf.d/amd-soundwire/ -> sobrevive a updates)"

echo "==> 3/7 Ativando o modulo corrigido"
NEED_REBOOT=0
if ! amixer -D hw:$CARD controls 2>/dev/null | grep -q 'Channel Playback'; then
  systemctl --user stop wireplumber pipewire pipewire-pulse 2>/dev/null || true
  if sudo modprobe -r snd_soc_tas2783_sdw 2>/dev/null && sudo modprobe snd_soc_tas2783_sdw; then
    echo "    modulo recarregado ao vivo"
    sleep 2
  else
    NEED_REBOOT=1
    echo "    nao deu para recarregar ao vivo — REINICIE ao final"
  fi
else
  echo "    controle ja presente (modulo corrigido ja carregado)"
fi

echo "==> 4/7 Validando parse do UCM (deve listar 'Speaker')"
alsaucm -c $CARD list _devices/HiFi | sed 's/^/    /' || true

echo "==> 5/7 Reiniciando PipeWire e selecionando profile HiFi"
systemctl --user restart wireplumber pipewire pipewire-pulse
sleep 3
pactl set-card-profile "$PCARD" HiFi 2>/dev/null || echo "    (profile switch falhou — checar 'pactl list cards')"
sleep 2

echo "==> 6/7 Estado (esperado: Attached, canais 1/2, sink Speaker)"
for d in /sys/bus/soundwire/devices/sdw:*; do
  echo "    $(basename "$d"): $(cat "$d/status" 2>/dev/null)"
done
for n in 1 2; do
  amixer -D hw:$CARD cget name="tas2783-$n Channel Playback" 2>/dev/null | tail -1 | sed "s/^/    tas2783-$n:/"
done
wpctl status | sed -n '/Sinks:/,/Sources:/p' | sed 's/^/    /'
SPK=$(pactl list short sinks 2>/dev/null | awk '/amd_sdw/ && /[Ss]peaker/{print $2; exit}')
if [ -n "${SPK:-}" ]; then
  wpctl set-default "$(pactl list short sinks | awk -v s="$SPK" '$2==s{print $1; exit}')" 2>/dev/null || true
  echo "    sink padrao = $SPK"
fi

echo "==> 7/7 Persistindo estado ALSA"
sudo alsactl store || true

echo
if [ "$NEED_REBOOT" = 1 ]; then
  echo "==> REINICIE o computador e rode: speaker-test -D pulse -c2 -l1 -t wav"
else
  echo "==> TESTE DE SOM (estereo: 'Front Left' na esquerda, 'Front Right' na direita):"
  speaker-test -D pulse -c2 -l1 -t wav 2>/dev/null | grep Front || true
  echo
  echo "Se os lados sairem trocados, inverta os dois csets em"
  echo "  $UCM/sof-soundwire/tas2783.conf  (1<->2) e rode: systemctl --user restart pipewire wireplumber"
fi
