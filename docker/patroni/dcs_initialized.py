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
def post(host, path, body, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = token
    request = urllib.request.Request(f"https://{host.strip()}{path}", data=json.dumps(body).encode(), headers=headers)
    return json.loads(urllib.request.urlopen(request, context=context, timeout=5).read())


for host in os.environ["PT_ETCD_HOSTS"].split(","):
    try:
        token = None
        if os.environ.get("PT_ETCD_USER"):       # 接管后 etcd 开了认证
            token = post(host, "/v3/auth/authenticate", {"name": os.environ["PT_ETCD_USER"], "password": os.environ["PT_ETCD_PASSWORD"]})["token"]
        body = post(host, "/v3/kv/range", {"key": key}, token)
    except Exception:
        continue
    print("initialized" if body.get("kvs") else "uninitialized")
    sys.exit(0)
sys.exit(1)
