#!/usr/bin/env bash
# 演练 5:postgres.js 换主后恢复时间。每个变体:只起 node 客户端(ny 站点,经 ny1 入口),
# 计划内切换主库两次(→ mia、再→ ny1),输出每次停写秒数与逐秒的成功数 / 错误码。
# 用法:05-node-recovery.sh '名字|ENV=值 ENV=值' ...    (ENV 见 clients/node/client.mjs:NODE_PROFILE NODE_OPTS NODE_BACKOFF CONNECT_TIMEOUT)
set -uo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$PT_DIR/out"; mkdir -p "$OUT"
[ "${LATENCY:-1}" = 1 ] && bash "$PT_DIR/drills/netem.sh" on
run_variant() {
  local name=${1%%|*} envs=${1#*|}
  local s="$OUT/05-$name.jsonl"; : > "$s"
  ensure_leader ny1
  load_reset
  # 只起 node 客户端
  docker rm -f pt-cli-ny-node >/dev/null 2>&1
  env $envs TIMELINE=1 bash -c 'source "'"$PT_DIR"'/drills/lib.sh"; docker run -d --name pt-cli-ny-node --network "$PT_NET" --ip "$(cli_ip ny-node)" --cap-add NET_ADMIN --memory 512m -e PGHOST="$(haip ny1)" -e PGPORT=5000 -e PGPASSWORD="$PT_PW" -e CLIENT_NAME=ny-node -e GID_BASE=1 -e WORKERS=2 -e INTERVAL_MS=20 -e CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-}" -e NODE_BACKOFF="${NODE_BACKOFF:-}" -e TIMELINE=1 -e NODE_OPTS="${NODE_OPTS:-}" -e NODE_PROFILE="${NODE_PROFILE:-xvideo}" pt-clients:latest sh -c "exec node /app/node/client.mjs" >/dev/null'
  bash "$PT_DIR/drills/netem.sh" on >/dev/null 2>&1
  sleep 15
  local t1 t2
  t1=$(vmnow); ptctl ny1 switchover --leader ny1 --candidate mia --force >/dev/null 2>&1
  wait_until 90 "mia 为主" cluster_healthy ny1; sleep 20
  t2=$(vmnow); ptctl ny1 switchover --leader mia --candidate ny1 --force >/dev/null 2>&1
  wait_until 90 "ny1 为主" cluster_healthy ny1; sleep 25
  clients_stop "$s"
  python3 - "$s" "$name" "$t1" "$t2" <<'PY'
import json, sys
s = json.loads(open(sys.argv[1]).read().split("SUMMARY ", 1)[1]); t1, t2 = float(sys.argv[3]), float(sys.argv[4])
print("== %s  ok=%d failed=%d stray=%s" % (sys.argv[2], s["ok"], s["failedAttempts"], s.get("stray")))
for a, b in s["gaps"]:
    print("   停写 %.1f 秒(开始于 %+.1f 秒,相对最近一次切换)" % (b - a, a - (t2 if a > t2 - 5 else t1)))
tl = s.get("timeline") or {}
for t0, tag in ((t1, "切换1"), (t2, "切换2")):
    row = []
    for sec in range(int(t0) - 1, int(t0) + 26):
        d = tl.get(str(sec)) or {}
        row.append("%d:%s" % (sec - int(t0), ",".join("%s=%d" % (k, v) for k, v in sorted(d.items())) or "-"))
    print("   %s 逐秒:" % tag, " | ".join(row))
PY
}
for v in "$@"; do run_variant "$v"; done
[ "${LATENCY:-1}" = 1 ] && bash "$PT_DIR/drills/netem.sh" off
