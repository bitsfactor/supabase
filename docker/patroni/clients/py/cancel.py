"""取消探针(psycopg 3):MODE=cancel(3 秒后 conn.cancel())| cancel_safe | stmt(服务端 statement_timeout=2s)。"""
import os
import threading
import time

import psycopg

E = os.environ
mode, rid = E["MODE"], int(E["ROW_ID"])
opts = "-c statement_timeout=2000" if mode == "stmt" else "-c statement_timeout=30000"
conn = psycopg.connect(host=E["PGHOST"], port=5432, user="supabase_admin", password=E["PGPASSWORD"], dbname="postgres",
                       connect_timeout=15, options=opts)
if mode == "cancel":
    threading.Timer(3, conn.cancel).start()
elif mode == "cancel_safe":
    threading.Timer(3, conn.cancel_safe).start()
t0 = time.time()
try:
    with conn.transaction():
        conn.execute("insert into pt_cancel values (%s, %s)", (rid, "py-" + mode))
    print("RESULT py-%s: 成功返回(%dms)" % (mode, 1000 * (time.time() - t0)), flush=True)
except Exception as e:  # noqa: BLE001
    print("RESULT py-%s: 报错 %s %s(%dms)" % (mode, type(e).__name__, str(e)[:60].replace("\n", " "), 1000 * (time.time() - t0)), flush=True)
os._exit(0)
