#!/usr/bin/env python3
"""etcd(v3 的 HTTP 网关)里 Patroni 集群的 initialize 键在不在:打印 initialized / uninitialized,读不到就退出码 1(调用方当拒绝)。"""
import base64
import json
import os
import ssl
import sys
import urllib.request

context = ssl.create_default_context(cafile="/etc/patroni/tls/ca.crt")
context.load_cert_chain("/etc/patroni/tls/node.crt", "/etc/patroni/tls/node.key")
key = base64.b64encode(f"/one/{os.environ.get('PT_SCOPE', 'supabase-main')}/initialize".encode()).decode()
for host in os.environ["PT_ETCD_HOSTS"].split(","):
    try:
        request = urllib.request.Request(f"https://{host.strip()}/v3/kv/range", data=json.dumps({"key": key}).encode(),
                                         headers={"Content-Type": "application/json"})
        body = json.loads(urllib.request.urlopen(request, context=context, timeout=5).read())
    except Exception:
        continue
    print("initialized" if body.get("kvs") else "uninitialized")
    sys.exit(0)
sys.exit(1)
