"""核对:每个客户端确认过的写入是否都在,各节点数据是否一致。
用法:verify.py <汇总文件(每行一个 SUMMARY json)> <节点IP,...> 例:verify.py /tmp/s.jsonl 10.77.0.21,10.77.0.85"""
import hashlib
import json
import os
import sys

import psycopg

summ = [json.loads(l.split("SUMMARY ", 1)[1]) for l in open(sys.argv[1]) if "SUMMARY " in l]
acked = {}
for s in summ:
    for gid, n in s["acked"].items():
        acked[int(gid)] = n
res = {}
for ip in sys.argv[2].split(","):
    try:
        with psycopg.connect(host=ip, port=5432, user="supabase_admin", password=os.environ["PGPASSWORD"],
                             dbname="postgres", connect_timeout=5) as c:
            seqs = [r[0] for r in c.execute("select seq from pt_load order by seq").fetchall()]
    except Exception as e:  # noqa: BLE001
        res[ip] = {"error": str(e)[:80]}
        continue
    have = set(seqs)
    lost = sum(1 for gid, n in acked.items() for i in range(n) if gid * 10**9 + i not in have)
    res[ip] = {"rows": len(seqs), "md5": hashlib.md5(",".join(map(str, seqs)).encode()).hexdigest()[:12],
               "acked_total": sum(acked.values()), "acked_lost": lost}
print(json.dumps(res, indent=1))
