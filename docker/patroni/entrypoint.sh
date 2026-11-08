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
# 全新的数据卷(新机器加入时)顶层目录归 root:只改顶层的属主,不递归(生产数据目录是 TB 级)。
chown postgres:postgres "${PGDATA:-/var/lib/postgresql/data}"
chmod 0700 "${PGDATA:-/var/lib/postgresql/data}"
# 证书:从只读挂载的 /tls 拷出并交给 postgres(私钥 0600),Patroni 与 patronictl 都读 /etc/patroni/tls
install -d -o postgres -g postgres -m 0700 /etc/patroni/tls
for f in /tls/*; do install -o postgres -g postgres -m 0600 "$f" "/etc/patroni/tls/$(basename "$f")"; done
# 失败即拒绝:数据目录里已有库、而集群在 etcd 里还没初始化、又没设 PT_STANDBY_HOST(迁移期当备用集群)—— Patroni 会把这份数据
# 当成新集群的主库直接拉起(旧主库没停就是第二个主)。读不到 etcd 同样拒绝。
if [ -f "${PGDATA:-/var/lib/postgresql/data}/PG_VERSION" ] && [ -z "${PT_STANDBY_HOST:-}" ]; then
  state=$(python3 /opt/patroni/dcs_initialized.py) || state="unreadable"
  if [ "$state" != "initialized" ]; then
    echo "entrypoint: refusing to start: existing data directory, cluster not initialized in etcd ($state) and PT_STANDBY_HOST is empty" >&2
    exit 78
  fi
fi
/opt/patroni/pgsodium-key.sh
python3 /opt/patroni/render.py /opt/patroni/patroni.yml > /etc/patroni/patroni.yml
chown postgres:postgres /etc/patroni/patroni.yml
chmod 600 /etc/patroni/patroni.yml
# 底座 compose 的 db 服务带 PGPASSWORD(超级用户口令,给 docker exec psql 用);libpq 的环境变量优先于 pgpass 文件,
# 会让 walreceiver 拿它去连上游的复制账号而认证失败。只在 Patroni 进程树里去掉,docker exec 看到的容器环境不变。
unset PGPASSWORD
exec gosu postgres patroni /etc/patroni/patroni.yml
