#!/usr/bin/env bash
# Rodar logo APOS um boot limpo (sem ter suspendido / fechado a tampa ainda).
# Verifica se o barramento SoundWire subiu e toca um teste no alto-falante interno.
set -u
CARD=alsa_card.pci-0000_c4_00.5-platform-amd_sdw

echo "==> Houve suspend/resume neste boot? (esperado: NADA)"
journalctl -k -b 0 --no-pager 2>/dev/null | grep -iE "suspend entry|resume: initialization timed out|amd_resume_child_device|BUSCLOCK" | head -5
echo "    (se aparecer algo acima, ja suspendeu — reinicie e teste de novo sem fechar a tampa)"

echo "==> Erros de soundwire neste boot? (esperado: NADA)"
journalctl -k -b 0 --no-pager 2>/dev/null | grep -iE "Program params failed|BUSCLOCK|tas2783.*timed out" | head -3 || true

echo "==> Estado dos perifericos SoundWire:"
for d in /sys/bus/soundwire/devices/sdw:*; do echo "    $(basename "$d"): $(cat "$d/status")"; done

echo "==> Selecionando profile HiFi e definindo speaker como padrao"
pactl set-card-profile "$CARD" HiFi 2>&1 | sed 's/^/    /' || echo "    HiFi indisponivel — colar saida"
sleep 2
SPK=$(pactl list short sinks 2>/dev/null | awk '/amd_sdw/ && /[Ss]peaker/{print $1; exit}')
[ -n "${SPK:-}" ] && wpctl set-default "$SPK" 2>/dev/null && echo "    sink Speaker = $SPK"
echo "    --- sinks ---"; pactl list short sinks | grep -iE "amd_sdw|sdw" | sed 's/^/    /'

echo "==> Perifericos depois de ativar HiFi:"
for d in /sys/bus/soundwire/devices/sdw:*; do echo "    $(basename "$d"): $(cat "$d/status")"; done

echo "==> TESTE DE SOM (alto-falante interno):"
SINK=$(pactl list short sinks | awk '/amd_sdw/ && /[Ss]peaker/{print $2; exit}')
[ -z "${SINK:-}" ] && SINK=$(pactl list short sinks | awk '/amd_sdw/{print $2; exit}')
echo "    tocando em: ${SINK:-<default>}"
paplay ${SINK:+--device=$SINK} /usr/share/sounds/freedesktop/stereo/complete.oga 2>&1 | sed 's/^/    /' || true
echo
echo "Ouviu? Se SIM -> confirma que o problema e so o suspend/resume; eu monto o hook de recuperacao no resume."
