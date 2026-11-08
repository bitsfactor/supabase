#!/bin/bash
# Patroni 容器入口:渲染配置 → 以 postgres 身份运行 Patroni(Postgres 由 Patroni 启停)。
set -euo pipefail
# 带参数(如 iptables / tc,测试环境断网演练用)就直接执行该命令
[ $# -gt 0 ] && exec "$@"
# 仅测试环境:模拟「宿主 5433 → 容器 5432」的端口发布(生产由 docker 的 ports 做);生产不设此变量
[ -n "${PT_TEST_PG_REDIRECT:-}" ] && iptables -t nat -A PREROUTING -p tcp --dport "$PT_TEST_PG_REDIRECT" -j REDIRECT --to-ports 5432
mkdir -p /var/run/postgresql /var/log/patroni /etc/patroni
chown postgres:postgres /var/run/postgresql /var/log/patroni
chmod 03775 /var/run/postgresql
# 数据目录必须已属于 postgres(uid 105)且为 0700;不在这里递归 chown(生产数据目录是 TB 级)。
chmod 0700 "${PGDATA:-/var/lib/postgresql/data}"
# 证书:从只读挂载的 /tls 拷出并交给 postgres(私钥 0600),Patroni 与 patronictl 都读 /etc/patroni/tls
install -d -o postgres -g postgres -m 0700 /etc/patroni/tls
for f in /tls/*; do install -o postgres -g postgres -m 0600 "$f" "/etc/patroni/tls/$(basename "$f")"; done
python3 /opt/patroni/render.py /opt/patroni/patroni.yml > /etc/patroni/patroni.yml
chown postgres:postgres /etc/patroni/patroni.yml
chmod 600 /etc/patroni/patroni.yml
exec gosu postgres patroni /etc/patroni/patroni.yml
