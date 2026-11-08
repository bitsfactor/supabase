#!/usr/bin/env bash
# 生成测试证书与口令到 out/tls(只在本机 / 测试节点,不入库)。可重跑:已有则沿用。
source "$(dirname "$0")/lib.sh"
ETCD_MEMBERS="ny1=$(etcdip ny1) mia=$(etcdip mia) los=$(etcdip los) x=$(etcdip x) x2=$(etcdip x2)" \
DB_MEMBERS="ny1=$(dbip ny1) mia=$(dbip mia) los=$(dbip los)" \
  "$PT_DIR/tls/gen-certs.sh" "$PT_TLS"
