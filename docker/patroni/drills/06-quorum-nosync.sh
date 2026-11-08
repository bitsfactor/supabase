#!/usr/bin/env bash
# 演练 6:断主库机器(ny1)时,谁会被选为新主?  用法:06-quorum-nosync.sh [轮数,缺省 3] —— 每轮断 ny1 机器 HOLD 秒后恢复。
# 输出每轮:新主是谁、其余成员给的「法定票」日志、确认写入核对。LOS_NOFAILOVER=1 时先把 los 改成 nofailover(重建 los 容器)再测。
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ROUNDS=${1:-3}; HOLD=${HOLD:-70}
OUT="$PT_DIR/out"; mkdir -p "$OUT"
pt_compose up -d ha-mia ha-los ha-los2 >/dev/null 2>&1
PT_LOS_NOFAILOVER=$([ "${LOS_NOFAILOVER:-0}" = 1 ] && echo true || echo false) pt_compose up -d db-los >/dev/null 2>&1
wait_until 120 "集群健康" cluster_healthy mia
echo "los 的 nofailover 标签 = $(docker exec pt-los curl -s localhost:8008/patroni | python3 -c 'import sys,json;print(json.load(sys.stdin)["tags"])')"
[ "${LATENCY:-1}" = 1 ] && bash "$PT_DIR/drills/netem.sh" on
for r in $(seq 1 "$ROUNDS"); do
  ensure_leader ny1
  load_reset; : > "$OUT/06-$r.jsonl"
  clients_start ny mia; [ "${LATENCY:-1}" = 1 ] && bash "$PT_DIR/drills/netem.sh" on >/dev/null 2>&1
  sleep 12
  echo "---- 第 $r 轮:同步集合 = $(docker exec pt-mia curl -s localhost:8008/cluster | python3 -c 'import sys,json;d=json.load(sys.stdin);print([(m["name"],m["role"]) for m in d["members"]], d.get("sync_standby"))')"
  T0=$(vmnow)
  isolate "$(dbip ny1),$(haip ny1),$(etcdip ny1)" $(machine_containers ny1)
  sleep "$HOLD"
  for n in mia los los2; do echo "[$n]"; log_events $n "$T0" "promoted" "Got quorum vote" "not the healthiest" "Quorum requirement" "Setting leader" | head -8; done
  NL=""; for n in mia los los2; do [ "$(docker exec pt-$n curl -s -o /dev/null -w '%{http_code}' localhost:8008/primary)" = 200 ] && NL=$n; done
  echo "新主 = $NL"
  heal $(machine_containers ny1)
  wait_until 300 "集群健康" cluster_healthy mia
  clients_stop "$OUT/06-$r.jsonl"; cli_summary_table "$OUT/06-$r.jsonl"; cli_verify "$OUT/06-$r.jsonl" | tr -d ' \n'; echo
done
[ "${LATENCY:-1}" = 1 ] && bash "$PT_DIR/drills/netem.sh" off
PT_LOS_NOFAILOVER=false pt_compose up -d db-los >/dev/null 2>&1
