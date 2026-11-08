#!/bin/sh
# 库入口容器:先用「没有后端」的配置起 HAProxy(1 号进程);confd 盯着 etcd 里 Patroni 的成员表,渲染配置并 USR2 平滑重载。
# 新机器部署后注册进 etcd,几秒内所有入口自动认识它。投票机和非投票机都用同一套节点证书去连 etcd。
set -eu
: "${ENTRY_PORT:=5000}" "${PT_SCOPE:=supabase-main}" "${PT_ETCD_HOSTS:?}" "${ENTRY_BACKUP:=}"
export ENTRY_PORT ENTRY_BACKUP
# 起步配置:模板去掉成员段(confd 第一次渲染成功前入口没有后端,连接会被拒绝而不是乱转)
sed -e '/# BEGIN-SERVERS/,/# END-SERVERS/d' -e "s/{{getenv \"ENTRY_PORT\"}}/$ENTRY_PORT/" \
    -e '/{{if getenv "ENTRY_BACKUP"}}/,/{{end}}/d' /etc/confd/templates/haproxy.tmpl > /tmp/haproxy.cfg
if [ -n "$ENTRY_BACKUP" ]; then
  awk -v line="    server legacy $ENTRY_BACKUP backup" '{print} /default-server/{print line}' /tmp/haproxy.cfg > /tmp/haproxy.cfg.new && mv /tmp/haproxy.cfg.new /tmp/haproxy.cfg
fi
NODES=""
for h in $(echo "$PT_ETCD_HOSTS" | tr ',' ' '); do NODES="$NODES -node $h"; done
# haproxy 变成 1 号进程之后(exec)confd 才开始,避免它的 USR2 打到还是 shell 的 1 号进程
( sleep 2; while :; do
    confd -backend etcdv3 -watch -confdir /etc/confd -prefix "/one/$PT_SCOPE" $NODES -scheme https \
      -client-cert /tls/node.crt -client-key /tls/node.key -client-ca-keys /tls/ca.crt -log-level warn || true
    sleep 2
  done ) &
exec haproxy -W -db -f /tmp/haproxy.cfg
