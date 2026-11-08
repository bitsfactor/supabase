#!/usr/bin/env bash
# 投票组首次建好后跑一次(任一成员的容器上):建 root 与 patroni 两个用户、patroni 角色只许读写 /one/ 前缀,然后开启认证。
# 可重跑(已存在则跳过,认证已开则带 root 口令)。口令从环境读:ETCD_ROOT_PASSWORD、ETCD_PATRONI_PASSWORD。
# 口令绝不上任何进程的命令行:root 凭据经 0600 临时环境文件交给 etcdctl(ETCDCTL_USER),新用户口令经标准输入(--interactive=false)。
# 用法:ETCD_ROOT_PASSWORD=… ETCD_PATRONI_PASSWORD=… tls/etcd-auth.sh <etcd 容器名>
set -euo pipefail
C=${1:?用法:etcd-auth.sh <etcd 容器名>}
: "${ETCD_ROOT_PASSWORD:?}" "${ETCD_PATRONI_PASSWORD:?}"
ENVF=$(mktemp); chmod 600 "$ENVF"; trap 'rm -f "$ENVF"' EXIT
printf 'ETCDCTL_USER=root:%s\n' "$ETCD_ROOT_PASSWORD" > "$ENVF"
EP=(--endpoints=https://127.0.0.1:2379 --cacert=/tls/ca.crt --cert=/tls/etcd.crt --key=/tls/etcd.key)
plain() { docker exec -i "$C" etcdctl "${EP[@]}" "$@"; }
rootctl() { docker exec -i --env-file "$ENVF" "$C" etcdctl "${EP[@]}" "$@"; }
# 认证已开时,只带证书的请求会被拒(etcd 把证书 CN 当用户名)→ 改带 root 凭据
if plain user list >/dev/null 2>&1; then ctl() { plain "$@"; }; else ctl() { rootctl "$@"; }; fi
ctl user get root >/dev/null 2>&1 || printf '%s\n' "$ETCD_ROOT_PASSWORD" | ctl user add root --interactive=false >/dev/null
ctl user grant-role root root >/dev/null 2>&1 || true
ctl role get patroni >/dev/null 2>&1 || ctl role add patroni >/dev/null
ctl role grant-permission patroni --prefix=true readwrite /one/ >/dev/null
ctl user get patroni >/dev/null 2>&1 || printf '%s\n' "$ETCD_PATRONI_PASSWORD" | ctl user add patroni --interactive=false >/dev/null
ctl user grant-role patroni patroni >/dev/null 2>&1 || true
ctl auth enable >/dev/null 2>&1 || true
rootctl user list | tr "\n" " "; echo "(认证已开:不带口令的请求被拒 = $(plain user list >/dev/null 2>&1 && echo 否 || echo 是))"
