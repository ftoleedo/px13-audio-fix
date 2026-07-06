#!/usr/bin/env bash
# PX13: desabilitar suspensao (s2idle trava a maquina e mata o audio neste kernel).
# Reversivel — ver fim do arquivo. Rodar: sudo bash disable-suspend.sh
set -euo pipefail

echo "==> 1) Removendo o hook de resume (nao funciona, pode atrapalhar o wake)"
rm -f /usr/lib/systemd/system-sleep/50-px13-soundwire && echo "    removido (ou ja ausente)"

echo "==> 2) Bloqueando TODA suspensao no systemd (mascara os targets de sono)"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
echo "    targets mascarados"

echo "==> 3) logind: fechar a tampa = TRAVAR a tela (nao suspender)"
install -d /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-px13-no-suspend.conf <<'EOF'
[Login]
HandleLidSwitch=lock
HandleLidSwitchExternalPower=lock
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF
systemctl restart systemd-logind || echo "    (logind restart adiado — efetivo no proximo login)"
echo "    logind configurado"

echo "==> 4) Conferindo"
echo "    CanSuspend: $(loginctl show-session 2>/dev/null | grep -i suspend || true)"
systemctl is-enabled suspend.target 2>/dev/null || true
echo
echo "PRONTO. A maquina nao suspende mais (tampa trava a tela). Audio fica estavel a cada boot."
echo
echo "Para REATIVAR a suspensao no futuro (quando o kernel corrigir o AMD SoundWire resume):"
echo "  sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target"
echo "  sudo rm /etc/systemd/logind.conf.d/10-px13-no-suspend.conf && sudo systemctl restart systemd-logind"
