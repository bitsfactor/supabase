#!/bin/sh
# 库入口容器:渲染配置并运行 HAProxy(1 号进程)。换配置 = 重建容器(或 haproxy -sf 平滑重载)。
set -e
python3 /opt/ha/haproxy-render.py > /tmp/haproxy.cfg
exec haproxy -W -db -f /tmp/haproxy.cfg
