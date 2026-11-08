#!/usr/bin/env bash
# 演练 7:各驱动在「主库被隔离、提交等不到同步确认」时,取消方式对结果的影响。
# 隔离现主库机器(放行一个探针客户端),探针同时发写入;主库被 Patroni 停掉、旧主倒回后,核对哪些「返回成功」的写入在新主上没有。
set -uo pipefail
source "$(dirname "$0")/lib.sh"
HOLD=${HOLD:-60}
ensure_leader ny1
L=ny1; dbexec $L "create table if not exists pt_cancel (id int primary key, note text)" >/dev/null; dbexec $L "truncate pt_cancel" >/dev/null
sleep 2
# 放行 10.77.0.32/27 这个客户端网段(探针容器从中分到地址),其余一律隔离
CLIENT_NET=10.77.0.32/27
isolate "$(dbip $L),$(haip $L),$(etcdip $L),$CLIENT_NET" $(machine_containers $L)
T0=$(vmnow)
probe() { # probe <id> <MODE> <命令...>
  local id=$1 mode=$2; shift 2
  docker run -d --name "pt-cli-probe-$id" --network "$PT_NET" --ip "10.77.0.$((40+id))" --memory 256m -e PGHOST="$(dbip $L)" -e PGPASSWORD="$PT_PW" -e MODE="$mode" -e ROW_ID="$id" pt-clients:latest "$@" >/dev/null
}
probe 1 cancel       node /app/node/cancel.mjs
probe 2 stmt         node /app/node/cancel.mjs
probe 3 end          node /app/node/cancel.mjs
probe 4 ctx          pgx-client
probe 5 cancel       python /app/py/cancel.py
probe 6 cancel_safe  python /app/py/cancel.py
probe 7 stmt         python /app/py/cancel.py
sleep 20
echo "---- 探针返回(隔离后 20 秒内)"
for i in 1 2 3 4 5 6 7; do docker logs "pt-cli-probe-$i" 2>&1 | grep -E "RESULT|NOTICE" ; done
sleep "$HOLD"
echo "---- 主库被停后探针的最终状态"
for i in 1 2 3 4 5 6 7; do echo "probe $i: $(docker logs "pt-cli-probe-$i" 2>&1 | grep -E 'RESULT' | tail -1) [容器状态 $(docker inspect -f '{{.State.Status}}' pt-cli-probe-$i)]"; done
heal $(machine_containers $L)
wait_until 300 "集群健康" cluster_healthy mia
sleep 5
NL=$(leader mia); echo "新主 = $NL"
echo "---- 新主上存在的行(id:note)"; dbexec "$NL" "select id||chr(58)||note from pt_cancel order by id" | tr '\n' ' '; echo
echo "---- 旧主($L)倒回后本机"; dbexec $L "select id||chr(58)||note from pt_cancel order by id" | tr '\n' ' '; echo
for i in 1 2 3 4 5 6 7; do docker rm -f "pt-cli-probe-$i" >/dev/null 2>&1; done
