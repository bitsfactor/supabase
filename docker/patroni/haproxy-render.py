#!/usr/bin/env python3
"""渲染库入口配置。HA_MODE=patroni(查 /primary,正式形态)| legacy(迁移前后备:单台直连旧主库,TCP 探活)。"""
import os
import string
import sys

mode = os.environ.get("HA_MODE", "patroni")
port = os.environ.get("ENTRY_PORT", "5433")
nodes = [n.split("=") for n in os.environ["HA_NODES"].split(",")]  # name=ip,name=ip
lines = []
if mode == "patroni":
    lines += [
        "    option httpchk GET /primary",
        "    http-check expect status 200",
        "    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions port 8008",
    ]
    lines += [f"    server {n} {ip}:5432 check" for n, ip in nodes]
else:
    legacy = os.environ["HA_LEGACY"].split("=")
    lines += [
        "    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions",
        f"    server {legacy[0]} {legacy[1]}:5432 check",
    ]
tpl = open("/opt/ha/haproxy.cfg.tpl").read()
sys.stdout.write(string.Template(tpl).substitute(ENTRY_PORT=port, BACKENDS="\n".join(lines)))
