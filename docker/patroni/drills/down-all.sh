#!/usr/bin/env bash
# 删掉演练环境:只删本目录建的、按精确名字(容器 pt-*、卷 pt-*、网络 patroni-test),不做任何 prune。
source "$(dirname "$0")/lib.sh"
for c in $(docker ps -a --format '{{.Names}}' | grep -E '^pt-(ny1|mia|los|los2|ha-(ny1|mia|los|los2)|etcd-(ny1|mia|los|los2|x|x2)|cli-[a-z0-9-]+)$'); do docker rm -f "$c" >/dev/null; done
for n in $PT_NODES; do docker volume rm "pt-data-$n" "pt-cfg-$n" >/dev/null 2>&1 || true; done
docker volume rm pt-out >/dev/null 2>&1 || true
docker network rm "$PT_NET" >/dev/null 2>&1 || true
