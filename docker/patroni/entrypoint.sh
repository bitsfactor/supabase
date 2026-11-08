#!/bin/bash
# Patroni 容器入口:渲染配置 → 以 postgres 身份运行 Patroni(Postgres 由 Patroni 启停)。
set -euo pipefail
# 带参数(如 iptables / tc,测试环境断网演练用)就直接执行该命令
[ $# -gt 0 ] && exec "$@"
mkdir -p /var/run/postgresql /var/log/patroni /etc/patroni
chown postgres:postgres /var/run/postgresql /var/log/patroni
chmod 03775 /var/run/postgresql
# 数据目录必须已属于 postgres(uid 105)且为 0700;不在这里递归 chown(生产数据目录是 TB 级)。
chmod 0700 "${PGDATA:-/var/lib/postgresql/data}"
python3 /opt/patroni/render.py /opt/patroni/patroni.yml > /etc/patroni/patroni.yml
chown postgres:postgres /etc/patroni/patroni.yml
chmod 600 /etc/patroni/patroni.yml
exec gosu postgres patroni /etc/patroni/patroni.yml
