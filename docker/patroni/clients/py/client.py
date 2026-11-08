"""psycopg3 + psycopg_pool 持续写客户端。环境变量与 node 客户端一致。"""
import json
import os
import signal
import threading
import time

from psycopg_pool import ConnectionPool

E = os.environ
name = E.get("CLIENT_NAME", "py")
workers = int(E.get("WORKERS", "2"))
interval = int(E.get("INTERVAL_MS", "20")) / 1000
gid_base = int(E.get("GID_BASE", "5"))
conninfo = (f"host={E['PGHOST']} port={E.get('PGPORT', '5433')} user={E.get('PGUSER', 'supabase_admin')} "
            f"password={E['PGPASSWORD']} dbname={E.get('PGDATABASE', 'postgres')} connect_timeout={E.get('CONNECT_TIMEOUT', '15')} "
            f"options='-c statement_timeout=30000'")
pool = ConnectionPool(conninfo, min_size=2, max_size=10, open=True, timeout=30,
                      check=ConnectionPool.check_connection)
lock = threading.Lock()
stop = threading.Event()
st = {"last": None, "maxgap": 0.0, "maxattempt": 0.0, "ok": 0, "failed": 0}
gaps, fails, acked = [], [], {}


def worker(w):
    gid = gid_base + w
    n = 0
    acked[gid] = 0
    while not stop.is_set():
        t0 = time.time()
        err = None
        try:
            with pool.connection() as conn:   # 正常退出自动 commit
                conn.execute("insert into pt_load (seq, client, ts) values (%s,%s,now()) on conflict do nothing",
                             (gid * 10**9 + n, name))
                conn.execute("select pg_sleep(0.01)")
        except Exception as e:  # noqa: BLE001
            err = f"{type(e).__name__}: {e}"[:80].replace("\n", " ")
        t1 = time.time()
        with lock:
            if err is None:
                g = 0 if st["last"] is None else t1 - st["last"]
                st["maxgap"] = max(st["maxgap"], g)
                if g > 1:
                    gaps.append([round(st["last"], 3), round(t1, 3)])
                st["last"] = t1
                st["ok"] += 1
                n += 1
                acked[gid] = n
            else:
                st["failed"] += 1
                if len(fails) < 30:
                    fails.append({"t": round(t0, 3), "dur": round(t1 - t0, 3), "err": err})
            st["maxattempt"] = max(st["maxattempt"], t1 - t0)
        time.sleep(interval)


ths = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(workers)]
for t in ths:
    t.start()
signal.signal(signal.SIGTERM, lambda *_: stop.set())
signal.signal(signal.SIGINT, lambda *_: stop.set())
stop.wait()
deadline = time.time() + 15
for t in ths:
    t.join(max(0, deadline - time.time()))
st["maxgap"] = max(st["maxgap"], 0 if st["last"] is None else time.time() - st["last"])
print("SUMMARY " + json.dumps({"client": name, "ok": st["ok"], "failedAttempts": st["failed"],
                              "maxAckGapS": round(st["maxgap"], 2), "maxAttemptS": round(st["maxattempt"], 2),
                              "gaps": gaps, "fails": fails, "acked": acked}), flush=True)
os._exit(0)
