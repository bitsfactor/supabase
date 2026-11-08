#!/usr/bin/env bash
# 投票组首次建好后跑一次(任一成员的容器上):建 root 与 patroni 两个用户、patroni 角色只许读写 /one/ 前缀,然后开启认证。
# 可重跑(已存在则跳过,认证已开则带 root 口令)。口令从环境读:ETCD_ROOT_PASSWORD、ETCD_PATRONI_PASSWORD。
# 用法:ETCD_ROOT_PASSWORD=… ETCD_PATRONI_PASSWORD=… tls/etcd-auth.sh <etcd 容器名>
set -euo pipefail
C=${1:?用法:etcd-auth.sh <etcd 容器名>}
: "${ETCD_ROOT_PASSWORD:?}" "${ETCD_PATRONI_PASSWORD:?}"
ctl() { docker exec -i "$C" etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/tls/ca.crt --cert=/tls/etcd.crt --key=/tls/etcd.key "$@"; }
# 认证已开时,只带证书的请求会被拒(etcd 把证书 CN 当用户名)→ 改带 root 口令
if ctl user list >/dev/null 2>&1; then A=(); else A=(--user "root:$ETCD_ROOT_PASSWORD"); fi
ctl ${A[@]+"${A[@]}"} user get root >/dev/null 2>&1 || ctl ${A[@]+"${A[@]}"} user add root --new-user-password="$ETCD_ROOT_PASSWORD" >/dev/null
ctl ${A[@]+"${A[@]}"} user grant-role root root >/dev/null 2>&1 || true
ctl ${A[@]+"${A[@]}"} role get patroni >/dev/null 2>&1 || ctl ${A[@]+"${A[@]}"} role add patroni >/dev/null
ctl ${A[@]+"${A[@]}"} role grant-permission patroni --prefix=true readwrite /one/ >/dev/null
ctl ${A[@]+"${A[@]}"} user get patroni >/dev/null 2>&1 || ctl ${A[@]+"${A[@]}"} user add patroni --new-user-password="$ETCD_PATRONI_PASSWORD" >/dev/null
ctl ${A[@]+"${A[@]}"} user grant-role patroni patroni >/dev/null 2>&1 || true
ctl ${A[@]+"${A[@]}"} auth enable >/dev/null 2>&1 || true
ctl --user "root:$ETCD_ROOT_PASSWORD" user list | tr "\n" " "; echo "(认证已开:不带口令的请求被拒 = $(ctl user list >/dev/null 2>&1 && echo 否 || echo 是))"
