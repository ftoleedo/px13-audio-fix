#!/usr/bin/env python3
"""check-zoom-routing.py — onde o áudio do Zoom está saindo DE FATOS.

Rode DURANTE a chamada, com o fone já selecionado dentro do Zoom:

    python3 check-zoom-routing.py

Não conserta nada: mede e diz em qual dos dois casos você está.

  CASO A — o stream do Zoom está ligado no alto-falante: o Zoom não aplicou a
           seleção; o áudio seguiu o sink padrão. O script imprime o comando que
           move o stream agora mesmo.
  CASO B — o stream do Zoom está ligado no fone mas o som sai na caixa: o problema
           é de rota ALSA/UCM (lado deste repositório) e o script imprime o que
           colar para diagnóstico.

A saída é pensada para ser colada direto numa issue.
"""

import json
import re
import shutil
import subprocess
import sys

MATCH = "zoom"  # substring (case-insensitive) do nome do app a procurar


def sh(cmd, timeout=25):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=timeout).stdout
    except Exception as exc:  # noqa: BLE001
        return f"(falhou: {cmd}: {exc})\n"


def need(*cmds):
    missing = [c for c in cmds if not shutil.which(c)]
    if missing:
        sys.exit(f"faltam comandos no PATH: {' '.join(missing)} "
                 "(instale pipewire/wireplumber)")


def section(title):
    print(f"\n== {title} ==")


def sinks_short():
    """{id: node.name} do lado PulseAudio."""
    out = {}
    for line in sh("pactl list sinks short").splitlines():
        f = line.split("\t")
        if len(f) >= 2:
            out[f[0]] = f[1]
    return out


def dump_streams():
    """(mapa serial/id -> node name dos sinks, lista de props dos streams de saída)."""
    try:
        dump = json.loads(sh("pw-dump", timeout=30) or "[]")
    except json.JSONDecodeError:
        return {}, []
    sink_names, streams = {}, []
    for obj in dump:
        p = obj.get("info", {}).get("props", {})
        mc = p.get("media.class")
        if mc == "Audio/Sink":
            for key in ("object.serial", "node.id"):
                if p.get(key) is not None:
                    sink_names[str(p[key])] = p.get("node.name")
        elif mc == "Stream/Output/Audio":
            streams.append(p)
    return sink_names, streams


def sink_inputs():
    """Lista de dicts {idx, sink, app, role} lida de `pactl list sink-inputs`."""
    items, cur = [], {}

    def flush():
        if cur.get("idx"):
            items.append(dict(cur))

    for line in sh("pactl list sink-inputs").splitlines():
        m = re.match(r"Sink Input #(\d+)", line)
        if m:
            flush()
            cur = {"idx": m.group(1)}
            continue
        for key, pat in (("sink", r"^\s+Sink: (\S+)"),
                         ("app", r'^\s+application\.name = "([^"]*)"'),
                         ("role", r'^\s+media\.role = "([^"]*)"'),
                         ("media", r'^\s+media\.name = "([^"]*)"')):
            m = re.match(pat, line)
            if m:
                cur[key] = m.group(1)
    flush()
    return items


def main():
    need("wpctl", "pactl", "pw-dump")
    print("== versão ==")
    print("  pipewire:  ", sh("pipewire --version").strip().splitlines()[-1])
    print("  wireplumber:", sh("wireplumber --version").strip().splitlines()[-1])

    section("sink padrão (* = padrão) ")
    block = sh("wpctl status").split("Sources:")[0].split("Sinks:")[-1]
    for line in block.splitlines():
        if "." in line and "[" in line:
            print("  " + line.strip())

    section("portas e disponibilidade (jack detectado?)")
    txt = sh("pactl list sinks")
    for block in txt.split("\n\n"):
        name = re.search(r"^\tName: (\S+)", block, re.M)
        if not name:
            continue
        port = re.search(r"^\tActive Port: (.*)$", block, re.M)
        state = re.search(r"^\tState: (\S+)", block, re.M)
        print(f"  {name.group(1)}")
        print(f"      estado: {state.group(1) if state else '?'}   "
              f"porta ativa: {port.group(1) if port else '?'}")
        for pname, avail in re.findall(
                r"^\t\t([^:]+):.*?(not available|availability unknown|available)",
                block, re.M):
            print(f"      porta {pname}: {avail}")

    section("streams de reprodução e onde o PipeWire os ligou")
    sink_names, streams = dump_streams()
    if not streams:
        print("  (nenhum stream de reprodução no momento — rode durante a chamada)")
    for s in streams:
        tgt = s.get("target.object") or s.get("node.target") or ""
        where = sink_names.get(str(tgt)) or (
            "(sem alvo explícito -> sink padrão)" if not tgt else f"(alvo desconhecido: {tgt})")
        app = s.get("application.name") or s.get("application.process.binary") or "?"
        print(f"  app={app}  role={s.get('media.role', '-')}  ->  {where}")
        print(f"      media.name={s.get('media.name', '-')}  "
              f"node.target={s.get('node.target', '-')}  "
              f"target.object={s.get('target.object', '-')}")

    section("visão PulseAudio (índices para mover na mão)")
    by_id = sinks_short()
    inputs = sink_inputs()
    for i in inputs:
        print(f"  sink-input #{i['idx']}  sink={i.get('sink')} "
              f"({by_id.get(str(i.get('sink')), '?')})  app={i.get('app', '?')}  "
              f"role={i.get('role', '-')}")
    for sid, name in by_id.items():
        print(f"  sink {sid} = {name}")

    section("diagnóstico")
    cands = [i for i in inputs if re.search(MATCH, i.get("app", "") or "", re.I)]
    if not cands:
        print(f"  Nenhum stream de app contendo '{MATCH}' foi encontrado.")
        print("  Entre na chamada com o fone selecionado no Zoom e rode de novo.")
        return

    hp = [sid for sid, name in by_id.items()
          if "headphone" in name.lower() or "headset" in name.lower()]
    for i in cands:
        name = by_id.get(str(i.get("sink")), "?")
        print(f"  stream do Zoom (sink-input #{i['idx']}) está em: {name}")
        if "headphone" in name.lower() or "headset" in name.lower():
            print("  CASO B — o stream está no fone. Se o som sai na caixa, a rota")
            print("           ALSA/UCM é a culpada. Cole também:")
            print("             amixer -D hw:1 contents | head -40")
            print("             sudo dmesg | tail -40")
        else:
            print("  CASO A — o Zoom NÃO aplicou a seleção: o áudio seguiu o sink padrão.")
            if hp:
                print("  Move o stream agora (vale até o stream fechar):")
                print(f"    pactl move-sink-input {i['idx']} {hp[0]}")
            print("  Ou faz o fone virar o padrão de tudo:")
            print("    wpctl status      # ache o id do sink do fone")
            print("    wpctl set-default <id>")


if __name__ == "__main__":
    main()
