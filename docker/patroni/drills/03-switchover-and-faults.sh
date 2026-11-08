#!/usr/bin/env bash
# 演练 3:计划内切回 ny1;断一张票;断一台从库;断主库所在机器;两台库同时断(主库 + 同步候选 mia)。
# 前置:01 已跑完(02 可有可无)。每个场景一组新客户端(ny 站点,经「存活机器」的库入口),LATENCY=1 注入真实延迟。
set -euo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$PT_DIR/out"; mkdir -p "$OUT"; : > "$OUT/03.log"
R() { tee -a "$OUT/03.log"; }
HOLD=${HOLD:-75}
ONLY=${ONLY:-}   # 只跑指定场景(空格分隔场景名;slots 为复制槽检查),缺省全跑
want() { [ -z "$ONLY" ] || [[ " $ONLY " == *" $1 "* ]]; }
pt_compose up -d ha-mia ha-los ha-los2 >/dev/null 2>&1
[ "${LATENCY:-0}" = 1 ] && bash "$PT_DIR/drills/netem.sh" on

back_to_ny1() {
  local cur; cur=$(leader mia); [ -z "$cur" ] && cur=$(leader ny1)
  [ "$cur" = ny1 ] && return 0
  ptctl mia switchover --leader "$cur" --candidate ny1 --force >/dev/null 2>&1 || true
  wait_until 120 "ny1 成为主" bash -c "docker exec pt-ny1 curl -s -m 2 -o /dev/null -w '%{http_code}' http://localhost:8008/primary | grep -q 200"
  wait_until 120 "集群健康" cluster_healthy mia
}

scenario() { # scenario <名字> <入口节点> <动作函数> —— 动作函数自己负责计时点与恢复
  local name=$1 entry=$2 action=$3 s="$OUT/03-$1.jsonl"
  : > "$s"
  echo "==== 场景 $name(客户端经 $entry 的库入口;主库开始时在 $(leader mia))" | R >&2
  load_reset
  clients_start ny "$entry"
  [ "${LATENCY:-0}" = 1 ] && bash "$PT_DIR/drills/netem.sh" on
  sleep 15
  local T0; T0=$(vmnow)
  "$action" "$T0" 2>&1 | R >&2
  sleep 15
  clients_stop "$s"
  cli_summary_table "$s" | R
  wait_until 240 "集群健康" cluster_healthy mia || echo "!! 场景后集群未回到健康" | R >&2
  sleep 3; cli_verify "$s" | R
  ptctl mia list | R >&2
  back_to_ny1
}

# --- 场景动作 ---
act_switchover() { # 先把主换到 mia(造一个非首选主),再计划内切回 ny1 —— 计时点在切回
  ptctl mia switchover --leader ny1 --candidate mia --force >/dev/null 2>&1
  wait_until 90 "mia 成为主" bash -c "docker exec pt-mia curl -s -m 2 -o /dev/null -w '%{http_code}' http://localhost:8008/primary | grep -q 200"
  sleep 12
  local t; t=$(vmnow); echo "切回 ny1 开始 T=$t" 
  ptctl mia switchover --leader mia --candidate ny1 --force 2>&1 | tail -1
  wait_until 90 "ny1 成为主" bash -c "docker exec pt-ny1 curl -s -m 2 -o /dev/null -w '%{http_code}' http://localhost:8008/primary | grep -q 200"
  echo "ny1 已是主,用时 $(python3 -c "print(round($(vmnow)-$t,1))") 秒"
  log_events ny1 "$t" "promoted" "demoted" "switchover" | head -8
}
cut_machines() { # cut_machines <T0> <节点...> —— 断这些「机器」HOLD 秒后恢复
  local T0=$1; shift
  local cs="" ips="" n
  for n in "$@"; do cs="$cs $(machine_containers "$n")"; ips="$ips,$(dbip "$n"),$(haip "$n"),$(etcdip "$n")"; done
  for n in "$@"; do isolate "$(dbip "$n"),$(haip "$n"),$(etcdip "$n")" $(machine_containers "$n"); done
  echo "断网: $*  T0=$T0"
  local i; for i in $(seq 1 $((HOLD/15))); do sleep 15; echo "  +$((i*15))s 主库: $(for v in ny1 mia los los2; do r=$(leader $v); [ -n "$r" ] && { echo -n "$r"; break; }; done)"; done
  for n in "$@"; do heal $(machine_containers "$n"); done
  echo "已恢复网络 T=$(vmnow)"
}
act_cut_vote()   { isolate "" pt-etcd-x; echo "断第五张票 pt-etcd-x T0=$1"; sleep "$HOLD"; heal pt-etcd-x; echo "已恢复"; }
act_cut_replica() { cut_machines "$1" mia; }
act_cut_leader()  { cut_machines "$1" ny1; for v in mia los los2; do echo "[$v]"; log_events $v "$1" "promoted" "demoted"; done; }
act_cut_two()     { cut_machines "$1" ny1 mia; for v in los los2; do echo "[$v]"; log_events $v "$1" "promoted" "demoted" "failsafe" "Setting" "No sync"; done; }

back_to_ny1   # 起点统一:主库在 ny1、集群健康

if want slots; then
# --- (g) 复制槽:ignore_slots 对逻辑槽(realtime 的 cainophile_*) ---
echo "==== 复制槽(ignore_slots)" | R >&2
L=$(leader mia)
echo "现主 $L 上的槽:" | R >&2; dbexec "$L" "select slot_name||' '||slot_type||' active='||active from pg_replication_slots order by 1" | R >&2
echo "去掉 ignore_slots,观察一轮循环(15 秒)后逻辑槽是否被 Patroni 删掉:" | R >&2
ptctl mia edit-config --force -s 'ignore_slots=null' >/dev/null 2>&1; sleep 20
dbexec "$L" "select slot_name||' '||slot_type from pg_replication_slots where slot_type='logical'" | R >&2 || true
echo "(以上为空 = 没有 ignore_slots 时逻辑槽被删)" | R >&2
dbexec "$L" "select pg_create_logical_replication_slot('cainophile_test','pgoutput')" >/dev/null 2>&1 || true
ptctl mia edit-config --force -s 'ignore_slots=[{"type":"logical"}]' >/dev/null 2>&1; sleep 20
echo "恢复 ignore_slots 后,20 秒后逻辑槽仍在:" | R >&2
dbexec "$L" "select slot_name||' '||slot_type from pg_replication_slots where slot_type='logical'" | R >&2
echo "(物理槽由 Patroni 管;旧架构遗留的 us_*_slot 是否被清理:)" | R >&2
dbexec "$L" "select slot_name from pg_replication_slots where slot_name like 'us_%'" | R >&2
fi

# 计划内切换:客户端连接超时 15 秒(xvideo 现值)与 3 秒各一轮,对比停写秒数
want switchover-ct15 && CONNECT_TIMEOUT=15 scenario switchover-ct15 ny1 act_switchover
want switchover-ct3 && CONNECT_TIMEOUT=3 scenario switchover-ct3 ny1 act_switchover
want switchover-ct3-fastbackoff && CONNECT_TIMEOUT=3 NODE_BACKOFF=fast scenario switchover-ct3-fastbackoff ny1 act_switchover   # postgres.js 缺省退避最长约 20 秒,换成封顶 2 秒
want cut-vote && scenario cut-vote    ny1 act_cut_vote
want cut-replica && scenario cut-replica ny1 act_cut_replica
want cut-leader && scenario cut-leader  mia act_cut_leader
want cut-two && scenario cut-two     los2 act_cut_two
[ "${LATENCY:-0}" = 1 ] && bash "$PT_DIR/drills/netem.sh" off
echo "完成" | R >&2
