#!/bin/bash
# PX13 — recuperacao do audio SoundWire apos resume do s2idle.
# Roda como unidade transiente (systemd-run) disparada pelo hook
# /usr/lib/systemd/system-sleep/50-px13-soundwire — NUNCA inline no resume,
# para nao segurar o descongelamento da sessao (tela preta).
#
# Metodo (validado 2026-07-30): RELOAD COMPLETO dos modulos SoundWire/ACP.
# O unbind/bind raso do PCI nao funciona no kernel 7.1.5 — os slaves somem
# do barramento apos o s2idle e so a re-enumeracao do zero traz de volta.
#
#   - reload SEMPRE (mesmo Attached): o firmware do DSP do TAS2783 nao
#     sobrevive ao s2idle e so o re-probe re-baixa ("playback without fw
#     download" = amp mudo);
#   - unbind PCI -> rmmod stack (filhos primeiro) -> modprobe -> bind;
#   - espera Attached (ate 20 s);
#   - SEMPRE reinicia o pipewire da sessao (card sumido trava o grafo do
#     wireplumber e mata ate o audio Bluetooth — constatado 2026-07-29);
#   - se recuperou: reaplica profile HiFi e desmuta o speaker (so vira
#     default se o default atual for auto_null, p/ nao roubar do BT).
#
# Instalar: /usr/local/lib/px13-soundwire-recover.sh (root:root 0755)
# Rodar manual: sudo /usr/local/lib/px13-soundwire-recover.sh
set -u
PCI="0000:c4:00.5"
DRV="/sys/bus/pci/drivers/snd_pci_ps"
CARD="alsa_card.pci-0000_c4_00.5-platform-amd_sdw"
SINK="alsa_output.pci-0000_c4_00.5-platform-amd_sdw.HiFi__Speaker__sink"
LOG="/var/log/px13-soundwire-resume.log"
log(){ echo "$(date '+%F %T' 2>/dev/null||echo now) $*" >> "$LOG" 2>/dev/null; }

# da tempo do resume terminar e a sessao descongelar antes de mexer em qualquer coisa
sleep 2
log "recover: iniciando em background (ACP $PCI)"

is_bound(){ [ -e "/sys/bus/pci/devices/$PCI/driver" ]; }
all_attached(){
  local d ok=1 n=0
  for d in /sys/bus/soundwire/devices/sdw:0:1:*; do
    [ -e "$d/status" ] || continue; n=$((n+1))
    [ "$(cat "$d/status" 2>/dev/null)" = "Attached" ] || ok=0
  done
  [ "$n" -ge 1 ] && [ "$ok" = "1" ]
}
status_str(){ local d s="(vazio)"; for d in /sys/bus/soundwire/devices/sdw:0:1:*; do [ -e "$d" ] || continue; s="$s $(basename "$d"|cut -d: -f4,5)=$(cat "$d/status" 2>/dev/null)"; done; echo "$s"; }

# NAO ha atalho "ja Attached": o s2idle apaga o firmware do DSP do TAS2783
# mesmo com o barramento Attached ("error playback without fw download" no
# dmesg — amp fica mudo em silencio; constatado 2026-07-30). So o re-probe
# via reload de modulos re-baixa o firmware. Reload SEMPRE.
is_bound && all_attached && log "recover: codecs Attached, mas recarregando mesmo assim (fw do amp nao sobrevive ao s2idle)"

# --- reload completo dos modulos (ordem mapeada por lsmod, kernel 7.1.5) ---
[ -e "/sys/bus/pci/devices/$PCI/driver" ] && { echo "$PCI" > "$DRV/unbind" 2>>"$LOG"; sleep 1; }
MODS_DOWN=(snd_acp_sdw_legacy_mach snd_acp_sdw_mach snd_soc_rt721_sdca \
           snd_soc_tas2783_sdw snd_ps_sdw_dma snd_pci_ps \
           snd_sof_amd_acp70 snd_sof_amd_acp63 snd_sof_amd_vangogh \
           snd_sof_amd_rembrandt snd_sof_amd_renoir snd_sof_amd_acp \
           soundwire_amd soundwire_generic_allocation)
for m in "${MODS_DOWN[@]}"; do
  lsmod | grep -q "^$m " || continue
  modprobe -r "$m" 2>>"$LOG" || log "rmmod $m FALHOU (segue)"
done
sleep 2
for m in snd_pci_ps snd_soc_rt721_sdca snd_soc_tas2783_sdw snd_ps_sdw_dma snd_acp_sdw_legacy_mach; do
  modprobe "$m" 2>>"$LOG" || log "modprobe $m FALHOU"
done
sleep 2
is_bound || { echo "$PCI" > "$DRV/bind" 2>>"$LOG"; log "bind manual pos-reload"; }

# espera enumeracao/attach (ate 20 s)
for i in $(seq 1 40); do sleep 0.5; all_attached && break; done
log "recover pos-reload:$(status_str)"
all_attached || log "recover: codecs seguem fora — audio interno indisponivel (reboot); BT/HDMI liberados pelo restart abaixo"

# reinicia o pipewire da sessao SEMPRE: o sumico do card SoundWire no resume
# deixa o grafo do wireplumber travado e mata ate o audio Bluetooth
UNAME="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 ~ /seat/ {print $3; exit}')"
[ -z "${UNAME:-}" ] && UNAME="$(id -nu 1000 2>/dev/null || echo root)"
UID_="$(id -u "$UNAME" 2>/dev/null || echo 1000)"; RT="/run/user/$UID_"
ru(){ runuser -u "$UNAME" -- env XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@" 2>>"$LOG"; }
if [ -S "$RT/bus" ]; then
  ru systemctl --user restart wireplumber pipewire pipewire-pulse
  sleep 4
  if all_attached; then
    ru pactl set-card-profile "$CARD" HiFi; sleep 1
    ru pactl set-sink-mute "$SINK" 0
    # so assume o default se ninguem melhor estiver la (nao rouba do fone BT)
    DEF="$(ru pactl get-default-sink 2>/dev/null)"
    case "${DEF:-}" in ""|auto_null) ru pactl set-default-sink "$SINK" ;; esac
    log "recover: SUCESSO — pipewire reiniciado, HiFi/speaker de volta (default=${DEF:-vazio})"
  else
    log "recover: pipewire reiniciado sem speaker interno"
  fi
else
  log "AVISO: $RT/bus ausente — pipewire nao reiniciado"
fi
exit 0
