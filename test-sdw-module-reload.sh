#!/bin/bash
# PX13 — EXPERIMENTO: recarga completa dos modulos SoundWire/ACP para tentar
# ressuscitar o audio interno apos s2idle SEM reboot (o unbind/bind raso do
# PCI nao funciona mais no kernel 7.1.5; os slaves somem do barramento).
#
# Rodar: sudo ~/Documentos/Projetos/px13-audio-fix/test-sdw-module-reload.sh
# Log:   /var/log/px13-sdw-reload-test.log
#
# RISCO: rmmod de stack de audio zumbi pode travar o kernel (worst case =
# reboot no botao, que ja e o fallback atual de qualquer jeito).
set -u
PCI="0000:c4:00.5"
DRV="/sys/bus/pci/drivers/snd_pci_ps"
CARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
SINK="alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink"
LOG="/var/log/px13-sdw-reload-test.log"
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

[ "$(id -u)" = 0 ] || { echo "rode com sudo"; exit 1; }

sdw_status(){ local d s="(vazio)"; for d in /sys/bus/soundwire/devices/sdw:0:1:*; do [ -e "$d" ] || continue; s="$s $(basename "$d"|cut -d: -f4,5)=$(cat "$d/status" 2>/dev/null)"; done; echo "$s"; }
all_attached(){
  local d ok=1 n=0
  for d in /sys/bus/soundwire/devices/sdw:0:1:*; do
    [ -e "$d/status" ] || continue; n=$((n+1))
    [ "$(cat "$d/status" 2>/dev/null)" = "Attached" ] || ok=0
  done
  [ "$n" -ge 1 ] && [ "$ok" = "1" ]
}

log "=== inicio: sdw=$(sdw_status)"

# 1. desliga o PCI do driver, se ainda bound
[ -e "/sys/bus/pci/devices/$PCI/driver" ] && { echo "$PCI" > "$DRV/unbind" 2>>"$LOG"; sleep 1; log "unbind feito"; }

# 2. remove modulos, filhos primeiro (ordem mapeada por lsmod em 2026-07-30)
MODS_DOWN=(snd_acp_sdw_legacy_mach snd_acp_sdw_mach snd_soc_rt721_sdca \
           snd_soc_tas2783_sdw snd_ps_sdw_dma snd_pci_ps \
           snd_sof_amd_acp70 snd_sof_amd_acp63 snd_sof_amd_vangogh \
           snd_sof_amd_rembrandt snd_sof_amd_renoir snd_sof_amd_acp \
           soundwire_amd soundwire_generic_allocation)
for m in "${MODS_DOWN[@]}"; do
  lsmod | grep -q "^$m " || continue
  if modprobe -r "$m" 2>>"$LOG"; then log "rmmod $m OK"; else log "rmmod $m FALHOU (segue)"; fi
done
sleep 2

# 3. recarrega o stack (snd_pci_ps puxa soundwire_amd; codecs/mach explicitos)
for m in snd_pci_ps snd_soc_rt721_sdca snd_soc_tas2783_sdw snd_ps_sdw_dma snd_acp_sdw_legacy_mach; do
  modprobe "$m" 2>>"$LOG" && log "modprobe $m OK" || log "modprobe $m FALHOU"
done
sleep 2

# 4. garante o bind do PCI
[ -e "/sys/bus/pci/devices/$PCI/driver" ] || { echo "$PCI" > "$DRV/bind" 2>>"$LOG"; log "bind manual"; }

# 5. espera enumeracao/attach (ate 20 s)
for i in $(seq 1 40); do sleep 0.5; all_attached && break; done
log "pos-reload: sdw=$(sdw_status)"

if ! all_attached; then
  log ">>> FALHOU: codecs nao anexaram. Audio interno segue exigindo reboot."
  log "dmesg recente:"; journalctl -k --since '-2 minutes' --no-pager | grep -iE 'sdw|soundwire|acp|snd' | tail -20 | tee -a "$LOG"
  exit 1
fi

# 6. FUNCIONOU no kernel: reconstroi a sessao de audio e toca um teste
log ">>> CODECS ATTACHED! reconstruindo pipewire..."
UNAME="${SUDO_USER:-$(id -nu 1000)}"; RT="/run/user/$(id -u $UNAME)"
ru(){ runuser -u "$UNAME" -- env XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@" 2>>"$LOG"; }
ru systemctl --user restart wireplumber pipewire pipewire-pulse
sleep 4
ru pactl set-card-profile "$CARD" HiFi; sleep 1
ru pactl set-default-sink "$SINK"
ru pactl set-sink-mute "$SINK" 0
ru paplay /usr/share/sounds/freedesktop/stereo/complete.oga
log ">>> SUCESSO — se voce OUVIU o som no alto-falante, o metodo funciona e vai pro script definitivo."
exit 0
