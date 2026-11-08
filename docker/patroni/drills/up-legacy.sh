#!/usr/bin/env bash
# 起「旧架构」:一主二从(ny1 主;mia / los 直连 ny1;us-los2 生产里不进 Patroni,不建),全是原版 supabase 库容器,
# 数据目录 / 配置与生产同形(含 postgresql.auto.conf 的生产参数,按测试机缩小)。可重跑:已存在则先 down-all.sh。
set -euo pipefail
source "$(dirname "$0")/lib.sh"

docker network inspect "$PT_NET" >/dev/null 2>&1 || docker network create --subnet 10.77.0.0/24 "$PT_NET" >/dev/null
for n in $PT_NODES; do
  docker volume create "pt-data-$n" >/dev/null; docker volume create "pt-cfg-$n" >/dev/null
done
docker volume create pt-out >/dev/null

legacy_run() { # legacy_run <节点>
  local n=$1
  docker run -d --name "pt-$n" --network "$PT_NET" --ip "$(dbip "$n")" --restart no --shm-size 256m --memory 4g --cap-add NET_ADMIN \
    -e POSTGRES_HOST=/var/run/postgresql -e PGPORT=5432 -e POSTGRES_PASSWORD="$PT_PW" -e PGPASSWORD="$PT_PW" \
    -e POSTGRES_DB=postgres -e JWT_SECRET=pt-jwt-secret-pt-jwt-secret-pt-jwt-secret -e JWT_EXP=3600 \
    -v "pt-data-$n:/var/lib/postgresql/data" -v "pt-cfg-$n:/etc/postgresql-custom" \
    pt-legacy:latest postgres -c config_file=/etc/postgresql/postgresql.conf -c log_min_messages=fatal >/dev/null
}
wait_pg() { # wait_pg <节点> [起点时间 UTC] —— 入口脚本打印 "Skipping initialization" 才是正式服务(首次初始化阶段的临时服务不算;log_min_messages=fatal 下没有 ready 日志)
  local since=${2:-1970-01-01T00:00:00Z} need=${3:-1}
  wait_until 240 "pt-$1 正式服务启动" bash -c "[ \$(docker logs --since $since pt-$1 2>&1 | grep -cE 'Skipping initialization|init process complete') -ge $need ]"
  wait_until 180 "pt-$1 接受连接" docker exec -e PGPASSWORD="$PT_PW" "pt-$1" psql -h "$(dbip "$1")" -U supabase_admin -d postgres -Atc 'select 1'
}
basebackup() { # basebackup <新节点> <上游IP> <槽名>
  docker run --rm --memory 1g --network "$PT_NET" --user root --entrypoint sh -e PGPASSWORD="$PT_PW" \
    -v "pt-data-$1:/var/lib/postgresql/data" pt-legacy:latest -c "
      chown postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data &&
      exec gosu postgres pg_basebackup -h $2 -U supabase_replication_admin -D /var/lib/postgresql/data -X stream -R -S $3 -C" >/dev/null
}

"$(dirname "$0")/tls-init.sh" >/dev/null; set -a; . "$PT_TLS/passwords.env"; set +a
log "起 ny1(首次初始化约 1 分钟)"
legacy_run ny1; wait_pg ny1
legacy_exec ny1 "alter role supabase_replication_admin password '$PT_PW'"
# 镜像自带 pg_hba 的 all 不匹配复制连接;生产这条是怎么来的见进度文件「待核实」。
legacy_hba() { docker exec -u postgres "pt-$1" sh -c "echo 'host replication supabase_replication_admin 10.0.0.0/8 scram-sha-256' >> /etc/postgresql/pg_hba.conf" && legacy_exec "$1" "select pg_reload_conf()" >/dev/null; }
legacy_hba ny1
# 生产 ny1 的 postgresql.auto.conf(按测试机缩小;含曾经当过从库留下的 primary_conninfo / slot 名)
for kv in "max_connections=2000" "shared_buffers='256MB'" "work_mem='8MB'" "maintenance_work_mem='128MB'" "hot_standby='on'" \
  "primary_conninfo='user=postgres password=REDACTED host=10.77.0.149 port=5433 sslmode=prefer target_session_attrs=any'" \
  "primary_slot_name='us_ny1_slot'" "max_wal_size='2GB'" "checkpoint_completion_target='0.9'" "effective_cache_size='1GB'" \
  "random_page_cost='1.1'" "effective_io_concurrency=200"; do
  k=${kv%%=*}; v=${kv#*=}; legacy_exec ny1 "alter system set $k = $v" >/dev/null
done
T_R=$(date -u +%Y-%m-%dT%H:%M:%SZ); docker restart pt-ny1 >/dev/null; wait_pg ny1 "$T_R"
legacy_exec ny1 "select pg_reload_conf()" >/dev/null
legacy_exec ny1 "create table if not exists pt_load (seq bigint primary key, client text, ts timestamptz default now())" >/dev/null
legacy_exec ny1 "select pg_create_logical_replication_slot('cainophile_test','pgoutput')" >/dev/null   # 模拟 realtime 的逻辑槽
legacy_exec ny1 "create table if not exists pt_seed as select g as id, md5(g::text) as v from generate_series(1,200000) g" >/dev/null

log "起 mia / los(直连 ny1)"
basebackup mia "$(dbip ny1)" us_mia_slot;  legacy_run mia
basebackup los "$(dbip ny1)" us_los_slot;  legacy_run los
wait_pg mia; wait_pg los
# 模拟生产的端口发布「宿主 5433 → 容器 5432」:入口、备集群、Patroni 成员间都按 5433 找库
for n in ny1 mia los; do fw_exec "pt-$n" -t nat -A PREROUTING -p tcp --dport 5433 -j REDIRECT --to-ports 5432; done

log "旧架构库入口(只指向 ny1)"
HA_MODE=static HA_STATIC=ny1=$(dbip ny1):5433 pt_compose up -d ha-ny1 >/dev/null 2>&1
wait_until 30 "库入口可用" docker exec -e PGPASSWORD="$PT_PW" pt-ny1 psql -h "$(haip ny1)" -p $ENTRY_PORT -U supabase_admin -d postgres -Atc 'select 1'
log "复制状态:"; legacy_exec ny1 "select application_name, state, sync_state from pg_stat_replication order by 1"
