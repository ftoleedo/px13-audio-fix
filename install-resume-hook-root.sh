#!/usr/bin/env bash
# Parte ROOT do hook de resume (rodar via: pkexec bash install-resume-hook-root.sh).
# So faz operacoes privilegiadas; a reativacao de som (pactl/paplay) e feita depois
# na sessao do usuario.
set -u
REPO=/home/fbr/Documentos/Projetos/px13-audio-fix
HOOK=/usr/lib/systemd/system-sleep/50-px13-soundwire

echo "==> Instalando hook em $HOOK"
install -Dm755 "$REPO/50-px13-soundwire" "$HOOK" && echo "    OK"

echo "==> Estado ANTES do rebind:"
for d in /sys/bus/soundwire/devices/sdw:0:1:*; do echo "    $(basename "$d"): $(cat "$d/status")"; done

echo "==> Executando recuperacao (simula post-resume)..."
"$HOOK" post suspend

echo "==> Log:"
tail -n 8 /var/log/px13-soundwire-resume.log 2>/dev/null | sed 's/^/    /'

echo "==> Estado DEPOIS (esperado: todos Attached):"
for d in /sys/bus/soundwire/devices/sdw:0:1:*; do echo "    $(basename "$d"): $(cat "$d/status")"; done
echo "==> Pronto. Agora o Claude reativa o som na sua sessao."
