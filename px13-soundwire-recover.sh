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
#   - STOP the session's PipeWire FIRST, then unbind PCI -> rmmod stack
#     (children first) -> modprobe -> bind. Unloading the codec while userspace
#     still holds the ALSA card blocks forever in snd_card_disconnect_sync():
#     an unkillable D state that can only be cleared by a reboot (seen on
#     7.2.2, 2026-09-01). 7.1 tolerated restarting PipeWire afterwards; 7.2
#     does not;
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

# Let the resume FINISH before tearing anything down. This is not politeness:
# unbinding the ACP 2 s after "PM: suspend exit" races the driver's own resume
# teardown. @leepaulmann hit it 1 resume in 10 on 7.1.9-arch1-2 (2026-09-05):
# NULL pointer dereference in release_resource() with the global resource_lock
# held for write, so every later amdgpu page fault spun on that lock - desktop
# frozen solid, only a power cycle cleared it. modprobe -r takes the same
# pci_device_remove path, so the lever is WHEN the teardown starts, not how.
# Healthy resumes finish SoundWire re-enumeration around t+7 s; 10 s leaves
# margin. Tunable for testing via PX13_RESUME_SETTLE.
sleep "${PX13_RESUME_SETTLE:-10}"

PCI="$(px13_acp_pci)" || PCI=""
if [ -z "$PCI" ]; then
  log "ERRO: nao achei o dispositivo PCI do ACP (nem no cache $PX13_CACHE)"
  exit 1
fi
DRV="$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null)"
[ -n "$DRV" ] || DRV="/sys/bus/pci/drivers/snd_pci_ps"
log "recover: iniciando em background (ACP $PCI, driver $(basename "$DRV"))"

is_bound() { [ -e "/sys/bus/pci/devices/$PCI/driver" ]; }

# --- session user (needed BEFORE the reload, see below) --------------------
UNAME="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 ~ /seat/ { print $3; exit }')"
[ -z "${UNAME:-}" ] && UNAME="$(id -nu 1000 2>/dev/null || echo root)"
UID_="$(id -u "$UNAME" 2>/dev/null || echo 1000)"; RT="/run/user/$UID_"
ru() { runuser -u "$UNAME" -- env XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@" 2>>"$LOG"; }

# Release the ALSA card BEFORE unloading anything. Removing the codec driver
# while userspace still holds the card blocks forever in
# snd_card_disconnect_sync() - an unkillable D state that takes the reboot with
# it (kernel 7.2.2, 2026-09-01). On 7.1 the same script got away with
# restarting PipeWire afterwards; do not rely on that.
release_card() {
  if [ -S "$RT/bus" ]; then
    # Stop the SOCKETS first. PipeWire is socket-activated: with pipewire.socket
    # still armed, anything touching it relaunches the service inside the sleep
    # below, systemd logs "Job for pipewire.service canceled", /dev/snd is held
    # again, and this function aborts the reload it was supposed to enable -
    # which is how every resume on 2026-09-11 left one amp without firmware.
    ru systemctl --user stop pipewire.socket pipewire-pulse.socket
    ru systemctl --user stop wireplumber.service pipewire-pulse.service pipewire.service
    log "recover: pipewire (sockets + servicos) parado antes do reload (libera o card)"
    sleep 2
  fi
  # fuser prints the PIDs on stdout and the file name on stderr
  local pids names
  pids="$(fuser /dev/snd/* 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  if [ -n "$pids" ]; then
    names="$(ps -o comm= -p $pids 2>/dev/null | sort -u | tr '\n' ' ')"
    log "AVISO: /dev/snd ainda aberto por [$pids] $names - o rmmod travaria"
    return 1
  fi
  return 0
}

# There is no "already Attached, skip" shortcut: s2idle wipes the TAS2783 DSP
# firmware even with the bus Attached ("error playback without fw download" in
# dmesg - the amp goes silent while every mixer level looks fine; seen
# 2026-07-30 on the 7.1 driver). Only a re-probe re-downloads it, so the
# default is to ALWAYS reload.
#
# PX13_RECOVER_POLICY (env, or a line in /etc/px13-audio-fix.conf):
#   auto    reload only if the ACP is unbound or a codec is not Attached.
#           Otherwise touch nothing: with the 7.3-based module the amps
#           re-initialise themselves on resume and the driver re-applies the
#           Channel Playback assignment, so a healthy resume needs no reload
#           and no PipeWire restart (measured 2026-09-12: stereo back on its
#           own, no 26 s gap, browser audio untouched).
#           DEFAULT on kernel >= 7.3. Not below: a PCM left open across s2idle
#           comes back running but silent there, because the SoundWire ports
#           are never re-prepared - fixed in 7.3's snd_soc_sdw_utils
#           ("prepare the stream again when resuming"), which a codec module
#           cannot carry. The PipeWire restart is what hides that on 7.1/7.2.
#   always  reload unconditionally. DEFAULT on kernel < 7.3.
#   never   touch nothing, log the bus state. For testing.
KMAJ="$(uname -r | cut -d. -f1)"; KMIN="$(uname -r | cut -d. -f2 | tr -dc 0-9)"
if [ "$KMAJ" -gt 7 ] || { [ "$KMAJ" -eq 7 ] && [ "${KMIN:-0}" -ge 3 ]; }; then
  DEFAULT_POLICY=auto; else DEFAULT_POLICY=always; fi
POLICY="${PX13_RECOVER_POLICY:-$(px13_cache_get PX13_RECOVER_POLICY 2>/dev/null || echo "$DEFAULT_POLICY")}"
case "$POLICY" in
  never)
    log "recover: POLICY=never - sem reload. bus:$(px13_sdw_status_str) bound:$(is_bound && echo sim || echo nao)"
    exit 0 ;;
  auto)
    if is_bound && px13_sdw_all_attached; then
      log "recover: POLICY=auto - bus sadio, nada a fazer. bus:$(px13_sdw_status_str)"
      exit 0
    fi
    log "recover: POLICY=auto - bus com problema, recarregando. bus:$(px13_sdw_status_str) bound:$(is_bound && echo sim || echo nao)" ;;
  always) ;;
  *) log "recover: POLICY='$POLICY' desconhecida - usando always" ;;
esac
is_bound && px13_sdw_all_attached &&
  log "recover: codecs Attached, mas recarregando mesmo assim (POLICY=$POLICY)"

# --- full module reload (order derived from lsmod at run time, see below) -----
if ! release_card; then
  log "recover: ABORTANDO o reload - o card segue em uso e o rmmod travaria o kernel"
  [ -S "$RT/bus" ] && ru systemctl --user start pipewire.socket pipewire-pulse.socket \
                                                  pipewire.service pipewire-pulse.service \
                                                  wireplumber.service
  exit 1
fi
[ -e "/sys/bus/pci/devices/$PCI/driver" ] && { echo "$PCI" > "$DRV/unbind" 2>>"$LOG"; sleep 1; }

# Unload order is derived from lsmod, not from a list. A fixed list rots with
# every kernel: the one mapped on 7.1.5 knew snd_sof_amd_acp70/acp63/..., and
# on 7.3 the platform module is snd_sof_amd_acp7x - not on the list, so it
# stayed loaded, kept snd_sof_amd_acp busy, which kept soundwire_amd busy, which
# kept soundwire_generic_allocation busy: three "rmmod FALHOU" per resume from a
# single missing name, and no SoundWire master reload at all.
#
# Instead: take every loaded module of the ACP/SoundWire stack (pattern below,
# codec sets included so rt711/rt722/cs35l56/... machines work too) and unload,
# in passes, whichever ones have a zero refcount, until the set is empty or a
# pass removes nothing. Children fall first by construction.
is_stack_module() {
  case "$1" in
    snd_soc_rt[0-9]*|snd_soc_tas[0-9]*|snd_soc_cs[0-9]*|snd_soc_sdw_utils|\
    snd_acp_sdw_*|snd_ps_sdw_dma|snd_pci_ps|snd_sof_amd_*|snd_amd_sdw_acpi|\
    soundwire_amd|soundwire_generic_allocation) return 0 ;;
    *) return 1 ;;
  esac
}
CODECS=()
while read -r m; do [ -n "$m" ] && CODECS+=("$m"); done < <(
  lsmod | awk '$1 ~ /^snd_soc_(rt[0-9]+|tas[0-9]+|cs[0-9]+)/ { print $1 }'
)
for pass in 1 2 3 4 5 6 7 8; do
  removed=0 left=""
  while read -r m refs _; do
    is_stack_module "$m" || continue
    if [ "$refs" = 0 ]; then
      if modprobe -r "$m" 2>>"$LOG"; then removed=$((removed+1)); else left="$left $m"; fi
    else
      left="$left $m($refs)"
    fi
  done < <(lsmod | awk 'NR>1 { print $1, $3 }')
  [ -z "$left" ] && { log "recover: stack descarregada em $pass passe(s)"; break; }
  [ "$removed" = 0 ] && { log "recover: rmmod estagnou no passe $pass - ficaram:$left"; break; }
done
sleep 2
for m in snd_pci_ps ${CODECS[@]+"${CODECS[@]}"} snd_soc_rt721_sdca snd_soc_tas2783_sdw \
         snd_ps_sdw_dma snd_acp_sdw_legacy_mach; do
  modprobe "$m" 2>>"$LOG" || log "modprobe $m FALHOU"
done
sleep 2
is_bound || { echo "$PCI" > "$DRV/bind" 2>>"$LOG"; log "bind manual pos-reload"; }

# wait for enumeration/attach (up to 20 s)
for _ in $(seq 1 40); do sleep 0.5; px13_sdw_all_attached && break; done
log "recover pos-reload:$(px13_sdw_status_str)"
px13_sdw_all_attached || log "recover: codecs seguem fora - audio interno indisponivel (reboot); BT/HDMI liberados pelo restart abaixo"

# ALWAYS restart the session's PipeWire: a vanished SoundWire card leaves the
# WirePlumber graph wedged and takes Bluetooth audio down with it
if [ -S "$RT/bus" ]; then
  ru systemctl --user start pipewire.socket pipewire-pulse.socket
  ru systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
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
      log "recover: AVISO - browsers ja abertos (Brave/Chromium/Electron) nao reenumeram microfones apos o restart do pipewire: sites dirao 'microfone nao encontrado' ate reiniciar o browser (brave://restart)"
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
