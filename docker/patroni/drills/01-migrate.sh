#!/usr/bin/env bash
# 演练 1:冷迁移 —— 旧架构(一主三从,原版 supabase 库容器)→ Patroni,全程持续写入(三种客户端经库入口)。
# 前置:up-legacy.sh 已跑完。环境变量 STOP_FIRST=1(缺省,先停旧主再提升,不需倒回)| 0(按进度文件列的顺序:先提升后停旧主)。
# 输出:out/01-migrate.log(逐步时间)、out/01-summary.jsonl(客户端汇总)。
set -euo pipefail
source "$(dirname "$0")/lib.sh"
mkdir -p "$PT_DIR/out"; OUT="$PT_DIR/out"; : > "$OUT/01-summary.jsonl"
STOP_FIRST=${STOP_FIRST:-1}
mark() { echo "$(vmnow) $*" | tee -a "$OUT/01-migrate.log" >&2; }
: > "$OUT/01-migrate.log"

patroni_member_up() { # 等某成员的 Patroni REST 报告 running
  wait_until 240 "pt-$1 Patroni running" bash -c "docker exec pt-$1 curl -s -m 2 http://localhost:8008/patroni | grep -q '\"state\": \"running\"'"
}
swap_to_patroni() { # swap_to_patroni <节点> —— 停旧容器(干净停机)、同一数据卷换 Patroni 容器
  local n=$1
  docker stop -t 60 "pt-$n" >/dev/null; docker rm "pt-$n" >/dev/null
  pt_compose up -d "db-$n" >/dev/null 2>&1
}

mark "START 持续写入(三客户端 × 经库入口 → 旧主 ny1)"
clients_start ny ny1
sleep 8

mark "ETCD 起 5 个投票机"
pt_compose up -d etcd-ny1 etcd-mia etcd-los etcd-los2 etcd-x >/dev/null 2>&1
sleep 5

mark "SWAP mia → Patroni(备集群,跟随旧主 ny1;第一个成员,借现有数据目录建集群)"
docker stop -t 60 pt-mia >/dev/null; docker rm pt-mia >/dev/null
PT_STANDBY_HOST=$(dbip ny1) PT_STANDBY_SLOT=us_mia_slot pt_compose up -d db-mia >/dev/null 2>&1
patroni_member_up mia; mark "mia 已由 Patroni 拉起: $(ptctl mia list -f json 2>/dev/null | tr -d '\n ' | cut -c1-300)"

mark "SWAP los → Patroni"; swap_to_patroni los; patroni_member_up los
mark "SWAP los2 → Patroni"; swap_to_patroni los2; patroni_member_up los2
sleep 12
ptctl mia list | tee -a "$OUT/01-migrate.log" >&2
mark "REPL 各 Patroni 从库回放进度(应全部追平 ny1)"

# ---- 切主 ----
[ "${LATENCY:-0}" = 1 ] && bash "$PT_DIR/drills/netem.sh" on   # 容器此时都已建好:注入站点间真实往返
mark "CUT-BEGIN ny1 设只读并断开会话"
legacy_exec ny1 "alter system set default_transaction_read_only = on" >/dev/null
legacy_exec ny1 "select pg_reload_conf()" >/dev/null
legacy_exec ny1 "select count(pg_terminate_backend(pid)) from pg_stat_activity where backend_type='client backend' and pid <> pg_backend_pid()" >/dev/null
LSN=$(legacy_exec ny1 "select pg_current_wal_lsn()")
wait_until 60 "mia 回放到 $LSN" bash -c "[ \"\$(docker exec -e PGPASSWORD=$PT_PW pt-mia psql -h /var/run/postgresql -U supabase_admin -d postgres -Atc \"select pg_last_wal_replay_lsn() >= '$LSN'::pg_lsn\")\" = t ]"
mark "CUT-REPLAYED mia 已回放到 ny1 最后位置 $LSN"
if [ "$STOP_FIRST" = 1 ]; then
  docker stop -t 60 pt-ny1 >/dev/null; mark "CUT-NY1-STOPPED 旧主干净停机(先于提升:其关机检查点已流给 mia,日后不需倒回)"
fi
ptctl mia edit-config --force -s standby_cluster=null -s synchronous_mode=quorum >/dev/null 2>&1
mark "CUT-PROMOTE 已去掉备集群(Patroni 提升中)"
docker exec -e HA_MODE=patroni pt-ha-ny1 sh -c 'python3 /opt/ha/haproxy-render.py > /tmp/haproxy.cfg.new && mv /tmp/haproxy.cfg.new /tmp/haproxy.cfg && kill -USR2 1'   # 平滑重载,不重建容器
mark "CUT-ENTRY 库入口平滑重载为按 /primary 找主"
wait_until 90 "mia 成为主" bash -c "[ \"$(leader mia)\" = mia ]" || true
wait_until 90 "mia 成为主" bash -c "docker exec pt-mia curl -s -m 2 -o /dev/null -w '%{http_code}' http://localhost:8008/primary | grep -q 200"
mark "CUT-PRIMARY mia 已是主(/primary=200)"
if [ "$STOP_FIRST" != 1 ]; then docker stop -t 60 pt-ny1 >/dev/null; mark "CUT-NY1-STOPPED(提升之后才停)"; fi

# ---- 旧主以 Patroni 从库身份回来 ----
docker run --rm --memory 256m --user root --entrypoint sh -v pt-data-ny1:/d pt-patroni:latest -c "sed -i '/default_transaction_read_only/d' /d/postgresql.auto.conf"   # 切主时只在旧主本机写过,须清掉,否则日后它当主会是只读
docker rm pt-ny1 >/dev/null
pt_compose up -d db-ny1 >/dev/null 2>&1
patroni_member_up ny1; mark "ny1 已作为 Patroni 从库加入"
wait_until 120 "ny1 追平(集群健康)" cluster_healthy mia || true
ptctl mia list | tee -a "$OUT/01-migrate.log" >&2
sleep 10

mark "SWITCHBACK 计划内切回 ny1"
ptctl mia switchover --leader mia --candidate ny1 --force 2>&1 | tail -3 | tee -a "$OUT/01-migrate.log" >&2
wait_until 60 "ny1 成为主" bash -c "docker exec pt-ny1 curl -s -m 2 -o /dev/null -w '%{http_code}' http://localhost:8008/primary | grep -q 200"
mark "SWITCHBACK-DONE ny1 已是主"
sleep 15

[ "${LATENCY:-0}" = 1 ] && bash "$PT_DIR/drills/netem.sh" off
mark "STOP 停客户端并核对"
clients_stop "$OUT/01-summary.jsonl"
ptctl ny1 list | tee -a "$OUT/01-migrate.log" >&2
cli_summary_table "$OUT/01-summary.jsonl" | tee -a "$OUT/01-migrate.log"
sleep 3
cli_verify "$OUT/01-summary.jsonl" | tee -a "$OUT/01-migrate.log"
