#!/usr/bin/env python3
"""渲染库入口配置(HAProxy 2.8)。入口端口 ENTRY_PORT(缺省 5000)。HA_MODE:
  patroni(缺省)查每个成员 Patroni REST 的 /primary(HTTPS + 客户端证书),只转给主;
  static   迁移前后备:固定转给当前主库(HA_STATIC=名=IP[:端口],端口缺省 5432),TCP 探活。
两种模式换主 / 后端下线时都 on-marked-down shutdown-sessions 掐断旧连接。
HA_NODES(patroni 模式):名=IP[:库端口[:REST端口]],逗号分隔;库端口缺省 5432、REST 缺省 8008。
证书(patroni 模式):/tls/ca.crt 与 /tls/node.pem(本机 Patroni 证书 + 私钥,同一 CA 签发即被各成员 REST 接受)。"""
import os
import string
import sys

mode = os.environ.get("HA_MODE", "patroni")
port = os.environ.get("ENTRY_PORT", "5000")
lines = []
if mode == "patroni":
    lines += [
        "    option httpchk GET /primary",
        "    http-check expect status 200",
        "    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions"
        " check-ssl verify required ca-file /tls/ca.crt crt /tls/node.pem",
    ]
    for item in os.environ["HA_NODES"].split(","):
        name, addr = item.split("=")
        host, *ports = addr.split(":")
        pg = ports[0] if ports else "5432"
        rest = ports[1] if len(ports) > 1 else "8008"
        lines.append(f"    server {name} {host}:{pg} check port {rest}")
elif mode == "static":
    name, addr = os.environ["HA_STATIC"].split("=")
    host, _, pg = addr.partition(":")
    lines += [
        "    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions",
        f"    server {name} {host}:{pg or '5432'} check",
    ]
else:
    sys.exit(f"haproxy-render.py: unknown HA_MODE {mode}")
tpl = open("/opt/ha/haproxy.cfg.tpl").read()
sys.stdout.write(string.Template(tpl).substitute(ENTRY_PORT=port, BACKENDS="\n".join(lines)))
