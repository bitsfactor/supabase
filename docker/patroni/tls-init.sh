#!/bin/sh
# 把环境里的证书(base64)写成 /tls 下的文件,供 etcd / Patroni / 库入口共用(节点证书同时当服务端和客户端证书)。
set -eu
umask 077
: "${TLS_CA_B64:?}" "${TLS_CRT_B64:?}" "${TLS_KEY_B64:?}"
echo "$TLS_CA_B64" | base64 -d > /tls/ca.crt
echo "$TLS_CRT_B64" | base64 -d > /tls/node.crt
echo "$TLS_KEY_B64" | base64 -d > /tls/node.key
cat /tls/node.crt /tls/node.key > /tls/node.pem
chmod 644 /tls/ca.crt /tls/node.crt; chmod 600 /tls/node.key /tls/node.pem
echo "tls ready: $(ls /tls | tr '\n' ' ')"
