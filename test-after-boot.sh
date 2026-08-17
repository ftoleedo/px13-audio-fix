#!/usr/bin/env bash
# Rodar logo APOS um boot limpo (sem ter suspendido / fechado a tampa ainda).
# Verifica se o barramento SoundWire subiu e toca um teste no alto-falante
# interno. Sem nada hardcoded: card, PCI e nomes do PipeWire sao detectados.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/px13-detect.sh
. "$REPO/lib/px13-detect.sh"

CARD="$(px13_find_card)" || { echo "ERRO: nenhum card SoundWire em /proc/asound/cards"; exit 1; }
PWCARD="$(px13_pw_card)" || PWCARD=""
echo "==> Card ALSA $CARD ($(px13_card_longname "$CARD" || echo '?')) / PipeWire: ${PWCARD:-nao encontrado}"

echo "==> Houve suspend/resume neste boot? (esperado: NADA)"
journalctl -k -b 0 --no-pager 2>/dev/null | grep -iE "suspend entry|resume: initialization timed out|amd_resume_child_device|BUSCLOCK" | head -5
echo "    (se aparecer algo acima, ja suspendeu — reinicie e teste de novo sem fechar a tampa)"

echo "==> Erros de soundwire neste boot? (esperado: NADA)"
journalctl -k -b 0 --no-pager 2>/dev/null | grep -iE "Program params failed|BUSCLOCK|tas2783.*timed out" | head -3 || true

echo "==> Estado dos perifericos SoundWire:$(px13_sdw_status_str)"

echo "==> Selecionando profile HiFi e definindo speaker como padrao"
[ -n "$PWCARD" ] && { pactl set-card-profile "$PWCARD" HiFi 2>&1 | sed 's/^/    /' || echo "    HiFi indisponivel — colar saida"; }
sleep 2
if SINK="$(px13_pw_speaker_sink)"; then
  ID="$(pactl list short sinks | awk -v s="$SINK" '$2 == s { print $1; exit }')"
  [ -n "$ID" ] && wpctl set-default "$ID" 2>/dev/null && echo "    sink Speaker = $SINK"
fi
echo "    --- sinks ---"; pactl list short sinks | grep -i sdw | sed 's/^/    /'

echo "==> Perifericos depois de ativar HiFi:$(px13_sdw_status_str)"

echo "==> TESTE DE SOM (alto-falante interno):"
echo "    tocando em: ${SINK:-<default>}"
paplay ${SINK:+--device=$SINK} /usr/share/sounds/freedesktop/stereo/complete.oga 2>&1 | sed 's/^/    /' || true
echo
echo "Ouviu? Se SIM -> confirma que o problema e so o suspend/resume; instale a"
echo "recuperacao com: bash install-resume-recovery.sh"
