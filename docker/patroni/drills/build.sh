#!/usr/bin/env bash
# 构建测试用镜像:pt-patroni(库 + Patroni)、pt-haproxy(库入口)、pt-legacy(旧架构库)、pt-clients(三种客户端)。
source "$(dirname "$0")/lib.sh"
cd "$PT_DIR"
mkdir -p legacy-init
for f in realtime webhooks roles jwt _supabase logs pooler; do cp "../volumes/db/$f.sql" "legacy-init/$f.sql"; done
docker build -q -t pt-patroni:latest -f Dockerfile .
docker build -q -t pt-haproxy:latest -f Dockerfile.haproxy .
docker build -q -t pt-legacy:latest -f Dockerfile.legacy .
docker build -q -t pt-clients:latest -f Dockerfile.clients .
