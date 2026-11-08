#!/usr/bin/env bash
# 演练 2:主库所在机房(纽约:ny1 + 其库入口 + 一张票 + ny 客户端)整体断网,不通知,90 秒后直接恢复。
# 前置:drills 01 已跑完(Patroni 集群健康)。LATENCY=1 时按真实站点间往返注入延迟。
set -euo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$PT_DIR/out"; mkdir -p "$OUT"; : > "$OUT/02-summary.jsonl"
HOLD=${HOLD:-90}
R() { tee -a "$OUT/02-site-cut.log"; }
: > "$OUT/02-site-cut.log"

pt_compose up -d ha-mia ha-los >/dev/null 2>&1
wait_until 300 "集群健康" cluster_healthy mia
ensure_leader ny1
sleep 5
load_reset
clients_start ny ny1; clients_start la los
[ "${LATENCY:-0}" = 1 ] && bash "$PT_DIR/drills/netem.sh" on
sleep 20
for n in ny1 mia los; do poll_start "$n"; done
T0=$(vmnow); echo "T0(断网)=$T0 主库=ny1" | R >&2
isolate "$NY_CIDR" $NY_CONTAINERS
for i in $(seq 1 $((HOLD/10))); do sleep 10; echo "  +$((i*10))s 存活侧看到的主库: $(leader mia)" | R >&2; done
T1=$(vmnow); echo "T1(恢复网络)=$T1" | R >&2
heal $NY_CONTAINERS
wait_until 240 "ny1 重新成为 streaming 从库" bash -c "docker exec pt-mia curl -s -m 2 $CURLTLS https://localhost:8008/cluster | python3 -c 'import sys,json; m={x[\"name\"]:x for x in json.load(sys.stdin)[\"members\"]}; sys.exit(0 if m[\"ny1\"][\"state\"]==\"streaming\" and m[\"ny1\"][\"role\"]!=\"leader\" else 1)'" || echo "ny1 未在 240 秒内回到 streaming" | R >&2
T2=$(vmnow); echo "T2(旧主重新 streaming)=$T2,恢复后用了 $(python3 -c "print(round($T2-$T1,1))") 秒" | R >&2
sleep 15
for n in ny1 mia los; do poll_stop "$n"; done
echo "--- 各节点本机读写状态变化(相对断网时刻)" | R >&2
for n in ny1 mia los; do echo "  $n:" | R >&2; poll_changes "$n" "$T0" | R >&2; done
echo "--- Patroni 关键事件" | R >&2
for n in ny1 mia los; do echo "  $n:" | R >&2; log_events "$n" "$T0" | R >&2; done
ptctl mia list | R >&2
clients_stop "$OUT/02-summary.jsonl"
echo "--- 客户端(ny 经 ny1 入口,在被断网的机房里;la 经 los 入口)" | R >&2
cli_summary_table "$OUT/02-summary.jsonl" | R
echo "--- 零丢失 / 零分叉" | R >&2
sleep 3; cli_verify "$OUT/02-summary.jsonl" | R
[ "${LATENCY:-0}" = 1 ] && bash "$PT_DIR/drills/netem.sh" off
