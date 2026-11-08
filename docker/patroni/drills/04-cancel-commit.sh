#!/usr/bin/env bash
# 演练 4:隔离期间「被取消的提交」。主库所在机器被隔离(同步确认不到),在它本机发两条写入:
#   A:语句超时 5 秒(< 租约 + 一轮循环)  B:语句超时 90 秒(> 租约 + 一轮循环)
# 看 A 是否「报成功」、恢复后(旧主被倒回)这条已确认的写入是否还在新主上。
set -euo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$PT_DIR/out"; mkdir -p "$OUT"; : > "$OUT/04.log"
R() { tee -a "$OUT/04.log"; }
HOLD=${HOLD:-80}
L=$(leader mia); echo "主库 $L" | R >&2
dbexec "$L" "create table if not exists pt_cancel (id int primary key, note text)" >/dev/null
dbexec "$L" "delete from pt_cancel" >/dev/null
sleep 2
T0=$(vmnow)
isolate "$(dbip "$L"),$(haip "$L"),$(etcdip "$L")" $(machine_containers "$L")
echo "T0(隔离主库机器 $L)=$T0" | R >&2
sleep 2
run_sess() { # run_sess <标签> <id> <语句超时 ms>
  docker exec -d "pt-$L" sh -c "PGPASSWORD='$PT_PW' PGOPTIONS='-c statement_timeout=$3' psql -h /var/run/postgresql -U supabase_admin -d postgres -At -c \"insert into pt_cancel values ($2, '$1')\" > /tmp/sess-$1.out 2>&1; echo \"exit=\$? at \$(date +%s.%N)\" >> /tmp/sess-$1.out"
}
run_sess A 1 5000
run_sess B 2 90000
run_sess C 3 0     # 无语句超时;5 秒后由另一个会话对它执行 pg_cancel_backend(模拟运维 / 连接池取消)
sleep 5
docker exec "pt-$L" sh -c "PGPASSWORD='$PT_PW' psql -h /var/run/postgresql -U supabase_admin -d postgres -Atc \"select pg_cancel_backend(pid) from pg_stat_activity where query like 'insert into pt_cancel values (3%' and pid <> pg_backend_pid()\"" | sed 's/^/cancel C: /' | R >&2
sleep "$HOLD"
echo "--- 会话输出(在被隔离的旧主本机)" | R >&2
for s in A B C; do echo "[$s]" | R >&2; docker exec "pt-$L" cat "/tmp/sess-$s.out" 2>&1 | R >&2; done
heal $(machine_containers "$L"); echo "已恢复网络 T=$(vmnow)" | R >&2
wait_until 300 "集群健康" cluster_healthy mia || echo "!! 集群未回到健康" | R >&2
sleep 5
NL=$(leader mia); echo "恢复后主库 $NL" | R >&2
ptctl mia list | R >&2
echo "--- 新主上这三条写入还在吗(C 的客户端若收到「提交成功」而这里没有 = 已确认写入丢了)" | R >&2
dbexec "$NL" "select id||chr(58)||note from pt_cancel order by id" | R >&2 || true
echo "(以上为空 = 都不在)" | R >&2
echo "--- 旧主($L)恢复后本机视图" | R >&2
dbexec "$L" "select id||chr(58)||note from pt_cancel order by id" | R >&2 || true
echo "--- 旧主倒回 / 重建的日志" | R >&2
log_events "$L" "$T0" "rewind" "reinit" "basebackup" "starting as" "demoted" | R >&2
