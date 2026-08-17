#!/bin/bash
# PX13 - SoundWire audio recovery after s2idle resume.
# Runs as a transient unit (systemd-run) fired by the sleep hook
# /usr/lib/systemd/system-sleep/50-px13-soundwire - NEVER inline in the resume
# path, or the user session stays frozen (black screen) until it finishes.
#
# Method (validated 2026-07-30): FULL RELOAD of the SoundWire/ACP module stack.
# A shallow PCI unbind/bind does not work on kernel 7.1.5 - the slaves drop off
# the bus after s2idle and only a from-scratch re-enumeration brings them back.
#
#   - reload ALWAYS (even when Attached): the TAS2783 DSP firmware does not
#     survive s2idle and only a re-probe re-downloads it ("playback without fw
#     download" = silently muted amp);
#   - unbind PCI -> rmmod stack (children first) -> modprobe -> bind;
#   - wait for Attached (up to 20 s);
#   - ALWAYS restart the session's PipeWire (a vanished card wedges the
#     WirePlumber graph and kills even Bluetooth audio - seen 2026-07-29);
#   - on success: reapply the HiFi profile and unmute the speaker (only becomes
#     the default sink if the current default is auto_null, so it never steals
#     from a Bluetooth headset).
#
# Nothing here is hardcoded to one PX13 SKU: the PCI address, the PipeWire card
# and the speaker sink are all probed (see lib/px13-detect.sh).
#
# Install: bash install-resume-recovery.sh
# Manual run: sudo /usr/local/lib/px13-soundwire-recover.sh
set -u

DETECT="${PX13_DETECT_LIB:-/usr/local/lib/px13-audio-detect.sh}"
LOG="/var/log/px13-soundwire-resume.log"
log() { echo "$(date '+%F %T' 2>/dev/null || echo now) $*" >> "$LOG" 2>/dev/null; }

if [ ! -r "$DETECT" ]; then
  log "ERRO: $DETECT ausente - rode install-resume-recovery.sh"
  exit 1
fi
# shellcheck source=lib/px13-detect.sh
. "$DETECT"

# give the resume time to finish and the session to thaw before touching anything
sleep 2

PCI="$(px13_acp_pci)" || PCI=""
if [ -z "$PCI" ]; then
  log "ERRO: nao achei o dispositivo PCI do ACP (nem no cache $PX13_CACHE)"
  exit 1
fi
DRV="$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null)"
[ -n "$DRV" ] || DRV="/sys/bus/pci/drivers/snd_pci_ps"
log "recover: iniciando em background (ACP $PCI, driver $(basename "$DRV"))"

is_bound() { [ -e "/sys/bus/pci/devices/$PCI/driver" ]; }

# There is no "already Attached, skip" shortcut: s2idle wipes the TAS2783 DSP
# firmware even with the bus Attached ("error playback without fw download" in
# dmesg - the amp goes silent while every mixer level looks fine; seen
# 2026-07-30). Only a re-probe re-downloads it. ALWAYS reload.
is_bound && px13_sdw_all_attached &&
  log "recover: codecs Attached, mas recarregando mesmo assim (fw do amp nao sobrevive ao s2idle)"

# --- full module reload (order mapped with lsmod, kernel 7.1.5) -------------
[ -e "/sys/bus/pci/devices/$PCI/driver" ] && { echo "$PCI" > "$DRV/unbind" 2>>"$LOG"; sleep 1; }

# codec modules first (children); discovered from lsmod so other SoundWire
# codec sets (rt711/rt722/cs35l56/...) are handled too, not just this laptop's.
CODECS=()
while read -r m; do [ -n "$m" ] && CODECS+=("$m"); done < <(
  lsmod | awk '$1 ~ /^snd_soc_(rt[0-9]+|tas[0-9]+|cs[0-9]+)/ { print $1 }'
)
MODS_DOWN=(snd_acp_sdw_legacy_mach snd_acp_sdw_mach ${CODECS[@]+"${CODECS[@]}"} \
           snd_soc_rt721_sdca snd_soc_tas2783_sdw snd_ps_sdw_dma snd_pci_ps \
           snd_sof_amd_acp70 snd_sof_amd_acp63 snd_sof_amd_vangogh \
           snd_sof_amd_rembrandt snd_sof_amd_renoir snd_sof_amd_acp \
           soundwire_amd soundwire_generic_allocation)
for m in "${MODS_DOWN[@]}"; do
  lsmod | grep -q "^$m " || continue
  modprobe -r "$m" 2>>"$LOG" || log "rmmod $m FALHOU (segue)"
done
sleep 2
for m in snd_pci_ps ${CODECS[@]+"${CODECS[@]}"} snd_soc_rt721_sdca snd_soc_tas2783_sdw \
         snd_ps_sdw_dma snd_acp_sdw_legacy_mach; do
  modprobe "$m" 2>>"$LOG" || log "modprobe $m FALHOU"
done
sleep 2
is_bound || { echo "$PCI" > "$DRV/bind" 2>>"$LOG"; log "bind manual pos-reload"; }

# wait for enumeration/attach (up to 20 s)
for i in $(seq 1 40); do sleep 0.5; px13_sdw_all_attached && break; done
log "recover pos-reload:$(px13_sdw_status_str)"
px13_sdw_all_attached || log "recover: codecs seguem fora - audio interno indisponivel (reboot); BT/HDMI liberados pelo restart abaixo"

# ALWAYS restart the session's PipeWire: a vanished SoundWire card leaves the
# WirePlumber graph wedged and takes Bluetooth audio down with it
UNAME="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 ~ /seat/ { print $3; exit }')"
[ -z "${UNAME:-}" ] && UNAME="$(id -nu 1000 2>/dev/null || echo root)"
UID_="$(id -u "$UNAME" 2>/dev/null || echo 1000)"; RT="/run/user/$UID_"
ru() { runuser -u "$UNAME" -- env XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@" 2>>"$LOG"; }
if [ -S "$RT/bus" ]; then
  ru systemctl --user restart wireplumber pipewire pipewire-pulse
  sleep 4
  if px13_sdw_all_attached; then
    CARD="$(px13_pw_card_as ru)"
    [ -n "${CARD:-}" ] && { ru pactl set-card-profile "$CARD" HiFi; sleep 1; }
    SINK="$(px13_pw_speaker_sink_as ru)" || SINK=""
    if [ -n "$SINK" ]; then
      ru pactl set-sink-mute "$SINK" 0
      # only take the default if nobody better holds it (never steal from BT)
      DEF="$(ru pactl get-default-sink 2>/dev/null)"
      case "${DEF:-}" in ""|auto_null) ru pactl set-default-sink "$SINK" ;; esac
      log "recover: SUCESSO - pipewire reiniciado, HiFi/speaker de volta (card=${CARD:-?} sink=$SINK default=${DEF:-vazio})"
    else
      log "recover: bus OK mas nenhum sink SoundWire no pipewire"
    fi
  else
    log "recover: pipewire reiniciado sem speaker interno"
  fi
else
  log "AVISO: $RT/bus ausente - pipewire nao reiniciado"
fi
exit 0
