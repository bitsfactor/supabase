#!/usr/bin/env python3
"""从 docker logs --timestamps 的输出里挑关键行,打印相对 T0 的秒数。用法:events.py <T0 虚拟机时间戳> [关键词...] < 日志"""
import datetime
import re
import sys

t0 = float(sys.argv[1])
keys = sys.argv[2:] or ["promoted self", "demoted self", "demote", "Lock owner", "following a different leader", "rewind",
                        "failsafe", "Could not take out TTL lock", "starting as", "became", "reinitial", "No sync", "synchronous"]
for line in sys.stdin:
    m = re.match(r"(\d{4}-\d\d-\d\dT[\d:.]+)Z\s+(.*)", line)
    if not m or not any(k in m.group(2) for k in keys):
        continue
    ts = datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc).timestamp()
    if ts - t0 >= -3:
        print("%+7.1fs  %s" % (ts - t0, m.group(2)[:170]))
