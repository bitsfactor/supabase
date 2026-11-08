#!/usr/bin/env bash
# 演练公共函数。硬约束:只连本机独立 colima 实例 patroni-test,绝不碰 default 实例 / 线上。
# 用法:source drills/lib.sh
PT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 两种运行位置:
#  - 本机独立 colima 实例 patroni-test(缺省);
#  - 测试节点(PT_ON_NODE=1,脚本放在 /opt/patroni-test/src/ 下,直接用节点上的 docker;只碰 pt- 前缀的容器 / 卷和网络 patroni-test)。
if [ "${PT_ON_NODE:-}" = 1 ]; then
  case "$PT_DIR" in /opt/patroni-test/*) ;; *) echo "PT_ON_NODE=1 只允许在 /opt/patroni-test 下运行" >&2; exit 1;; esac
else
  PT_PROFILE=patroni-test
  export DOCKER_HOST="unix://${COLIMA_HOME:-$HOME/.colima}/${PT_PROFILE}/docker.sock"
  unset DOCKER_CONTEXT
fi
PT_PW="pt-test-password"; export PT_PW
PT_NET=patroni-test
PT_NODES="ny1 mia los los2"
PT_LA="los los2"                        # 洛杉矶站点
# 固定地址(与 compose.yml 一致):站点网段 ny .0/26  mia .64/26  la .128/26  x .192/26
dbip() { case $1 in ny1) echo 10.77.0.21;; mia) echo 10.77.0.85;; los) echo 10.77.0.149;; los2) echo 10.77.0.151;; esac; }
haip() { case $1 in ny1) echo 10.77.0.22;; mia) echo 10.77.0.86;; los) echo 10.77.0.150;; los2) echo 10.77.0.152;; esac; }
LA_CIDR=10.77.0.128/26
ETCD_NAMES="ny1 mia los los2 x"

pt_guard() {
  if [ "${PT_ON_NODE:-}" = 1 ]; then return 0; fi
  [ -S "${DOCKER_HOST#unix://}" ] || { echo "patroni-test 的 docker 套接字不存在:先 colima start patroni-test" >&2; return 1; }
  [ "$(docker info --format '{{.Name}}')" = "colima-patroni-test" ] || { echo "不是 patroni-test 实例,拒绝执行" >&2; return 1; }
}
pt_guard || exit 1

pt_compose() { docker compose -f "$PT_DIR/compose.yml" "$@"; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
# 虚拟机时钟(所有日志时间戳与客户端时间都是它,别用本机的 date)
vmnow() { docker exec pt-ha-ny1 python3 -c 'import time;print("%.3f"%time.time())'; }
dbexec() { # dbexec <节点> <sql>  (超级用户,经本机套接字,返回值只带数据)
  docker exec -e PGPASSWORD="$PT_PW" "pt-$1" psql -h /var/run/postgresql -U supabase_admin -d postgres -Atq -c "$2"
}
legacy_exec() { docker exec -e PGPASSWORD="$PT_PW" "pt-$1" psql -h /var/run/postgresql -U supabase_admin -d postgres -Atq -c "$2"; }
ptctl() { # ptctl <节点> <patronictl 参数...>
  local n=$1; shift
  docker exec -u postgres "pt-$n" patronictl -c /etc/patroni/patroni.yml "$@"
}
leader() { # 返回当前主(经任一存活节点的 REST)
  local n=${1:-mia}
  docker exec "pt-$n" curl -s -m 2 http://localhost:8008/cluster 2>/dev/null | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(",".join(m["name"] for m in d["members"] if m["role"]=="leader"))
except Exception: print("")'
}
cluster_json() { docker exec "pt-${1:-mia}" curl -s -m 2 http://localhost:8008/cluster; }
wait_until() { # wait_until <超时秒> <描述> <命令...>
  local t=$1 d=$2; shift 2; local i=0
  until "$@" >/dev/null 2>&1; do i=$((i+1)); [ $i -gt $((t*2)) ] && { log "超时:$d"; return 1; }; sleep 0.5; done
}
# 断网:isolate <放行地址(逗号分隔)> <容器...> —— 这些容器只与放行地址往来,其余入站出站全部丢弃
# (丢弃而不是拒绝:与真实断网一致,对端的连接挂住而不是立刻报错)。heal 清掉规则。
LA_CIDR=10.77.0.128/26
fw_exec() { docker run --rm --memory 64m --cap-add NET_ADMIN --network "container:$1" pt-clients:latest iptables "${@:2}"; }
isolate_one() {
  local c=$1 allow=$2
  fw_exec "$c" -F INPUT; fw_exec "$c" -F OUTPUT
  fw_exec "$c" -A INPUT -i lo -j ACCEPT; fw_exec "$c" -A OUTPUT -o lo -j ACCEPT
  local a
  for a in ${allow//,/ }; do fw_exec "$c" -A INPUT -s "$a" -j ACCEPT; fw_exec "$c" -A OUTPUT -d "$a" -j ACCEPT; done
  fw_exec "$c" -A INPUT -j DROP; fw_exec "$c" -A OUTPUT -j DROP
}
isolate() { local allow=$1; shift; local c; for c in "$@"; do isolate_one "$c" "$allow" & done; wait; }
heal() { local c; for c in "$@"; do ( fw_exec "$c" -F INPUT; fw_exec "$c" -F OUTPUT ) & done; wait; }
# 一台「机器」= 库 + 入口 + 投票机 + 同机客户端
machine_ips() { echo "$(dbip "$1"),$(haip "$1")"; }
LA_CONTAINERS="pt-los pt-los2 pt-ha-los pt-ha-los2 pt-etcd-los pt-etcd-los2 pt-cli-la-node pt-cli-la-go pt-cli-la-py"

# ---- 持续写客户端:三种 × 站点(ny 连 pt-ha-ny1,la 连 pt-ha-los),都经库入口 5433 ----
cli_ip() { case $1 in ny-node) echo 10.77.0.31;; ny-go) echo 10.77.0.32;; ny-py) echo 10.77.0.33;; la-node) echo 10.77.0.161;; la-go) echo 10.77.0.162;; la-py) echo 10.77.0.163;; esac; }
cli_gid() { case $1 in ny-node) echo 1;; ny-go) echo 3;; ny-py) echo 5;; la-node) echo 11;; la-go) echo 13;; la-py) echo 15;; esac; }
clients_start() { # clients_start <ny|la> [入口节点,缺省 ny→ny1 la→los]
  local site=$1 entry=${2:-}; [ -z "$entry" ] && { [ "$site" = ny ] && entry=ny1 || entry=los; }
  local k cmd
  for k in node go py; do
    case $k in node) cmd="node /app/node/client.mjs";; go) cmd="pgx-client";; py) cmd="python /app/py/client.py";; esac
    docker rm -f "pt-cli-$site-$k" >/dev/null 2>&1 || true
    docker run -d --name "pt-cli-$site-$k" --network "$PT_NET" --ip "$(cli_ip "$site-$k")" --cap-add NET_ADMIN --memory 512m \
      -e PGHOST="$(haip "$entry")" -e PGPORT=5433 -e PGPASSWORD="$PT_PW" -e CLIENT_NAME="$site-$k" -e GID_BASE="$(cli_gid "$site-$k")" \
      -e WORKERS=2 -e INTERVAL_MS=20 -e CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}" -e NODE_BACKOFF="${NODE_BACKOFF:-}" pt-clients:latest sh -c "exec $cmd" >/dev/null
  done
}
clients_stop() { # clients_stop <输出文件> —— 优雅停(等它们打印汇总),汇总追加到文件,再删容器
  local out=$1 c
  for c in $(docker ps -a --format '{{.Names}}' | grep -E '^pt-cli-(ny|la)-(node|go|py)$'); do docker stop -t 25 "$c" >/dev/null & done; wait
  for c in $(docker ps -a --format '{{.Names}}' | grep -E '^pt-cli-(ny|la)-(node|go|py)$'); do
    docker logs "$c" 2>&1 | grep '^SUMMARY ' >> "$out" || echo "(无汇总:$c)" >&2
    docker rm "$c" >/dev/null
  done
}
cli_summary_table() { # 打印汇总文件的对比表
  python3 - "$1" <<'PY'
import json, sys
print("%-9s %8s %7s %10s %10s  失败样例(耗时/原因)" % ("客户端", "成功写", "失败次", "停写秒(最长)", "单次最长秒"))
for l in open(sys.argv[1]):
    if not l.startswith("SUMMARY "):
        continue
    s = json.loads(l[8:])
    f = s["fails"][0] if s["fails"] else None
    print("%-9s %8d %7d %10.2f %10.2f  %s" % (s["client"], s["ok"], s["failedAttempts"], s["maxAckGapS"], s["maxAttemptS"],
          ("%.1fs %s" % (f["dur"], f["err"])) if f else "-"))
PY
}
cli_verify() { # cli_verify <汇总文件> —— 在一个客户端镜像里对 4 台库逐台核对(零丢失 / 零分叉)
  docker run --rm -i --memory 512m --network "$PT_NET" -e PGPASSWORD="$PT_PW" pt-clients:latest \
    python /app/py/verify.py /dev/stdin "$(dbip ny1),$(dbip mia),$(dbip los),$(dbip los2)" < "$1"
}

# ---- 节点本机状态轮询(断网的节点也能 docker exec 进去看):读写 / 只读 / 库不在 ----
poll_start() { # poll_start <节点>
  docker exec -d "pt-$1" sh -c "echo \$\$ > /tmp/poll.pid; : > /tmp/state.log; while :; do s=\$(PGPASSWORD='$PT_PW' timeout 2 psql -h /var/run/postgresql -U supabase_admin -d postgres -Atq -c \"select case when pg_is_in_recovery() then 'ro' else 'rw' end\" 2>/dev/null || echo down); echo \"\$(date +%s.%N) \$s\" >> /tmp/state.log; sleep 0.4; done"
}
poll_stop() { docker exec "pt-$1" sh -c 'kill $(cat /tmp/poll.pid) 2>/dev/null; true'; }
poll_changes() { # poll_changes <节点> <T0> —— 状态变化时间线(相对 T0 的秒数)
  docker exec "pt-$1" cat /tmp/state.log | python3 -c '
import sys
t0=float(sys.argv[1]); prev=None
for l in sys.stdin:
    p=l.split()
    if len(p)<2: continue
    if p[1]!=prev:
        print("    %+7.1fs  %s" % (float(p[0])-t0, p[1])); prev=p[1]' "$2"
}
log_events() { # log_events <节点> <T0> [关键词...] —— Patroni 日志里的关键事件
  local n=$1 t0=$2; shift 2
  docker logs --timestamps "pt-$n" 2>&1 | python3 "$PT_DIR/drills/events.py" "$t0" "$@" | sed 's/^/    /'
}
etcdip() { case $1 in ny1) echo 10.77.0.11;; mia) echo 10.77.0.75;; los) echo 10.77.0.139;; los2) echo 10.77.0.141;; x) echo 10.77.0.203;; esac; }
machine_containers() { local n; for n in "$@"; do echo "pt-$n pt-ha-$n pt-etcd-$n"; done; }
# 集群是否健康:有主、四个成员都在、从库全部 streaming
cluster_healthy() {
  docker exec "pt-${1:-mia}" curl -s -m 2 http://localhost:8008/cluster | python3 -c '
import sys,json
m=json.load(sys.stdin)["members"]
ok=len(m)==4 and sum(1 for x in m if x["role"]=="leader")==1 and all((x["state"]=="running") if x["role"]=="leader" else (x["state"]=="streaming") for x in m) and all(x.get("lag",0) in (0,None) for x in m if x["role"]!="leader")
sys.exit(0 if ok else 1)'
}

# 每轮演练前清空写入表(各客户端的序号从 0 重新数;不清的话,序号与上一轮重叠,「已确认写入都在」的核对会白过)
load_reset() {
  local n; for n in ny1 mia los2 los; do
    if [ "$(docker exec "pt-$n" curl -s -m 2 -o /dev/null -w '%{http_code}' http://localhost:8008/primary 2>/dev/null)" = 200 ]; then dbexec "$n" "truncate pt_load"; return 0; fi
  done
  return 1
}
