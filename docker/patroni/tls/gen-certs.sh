#!/usr/bin/env bash
# 生成私有 CA 与每台机器一张节点证书(同时当 etcd / Patroni 的服务端和客户端证书),输出可直接填进平台配置的 base64 行。
# 用法: MACHINES="us-ny1=IP[,IP2] us-mia=IP ..." tls/gen-certs.sh OUT      一台机器有多个地址就逗号分隔(都进证书);可重跑(沿用已有 CA)
set -euo pipefail
OUT=${1:?用法:gen-certs.sh OUT}; : "${MACHINES:?}"
DAYS=${LEAF_DAYS:-1825}
umask 077; mkdir -p "$OUT"; cd "$OUT"
if [ ! -f ca.key ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=one-patroni-ca\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.cnf
  openssl req -x509 -new -key ca.key -sha256 -days 3650 -config ca.cnf -out ca.crt; rm -f ca.cnf
fi
echo "# 服务级配置(所有机器相同)"; echo "TLS_CA_B64=$(base64 < ca.crt | tr -d '\n')"
for m in $MACHINES; do
  name=${m%%=*}; ips=${m#*=}; san=""; for a in ${ips//,/ }; do san="$san,IP:$a"; done
  [ -f "$name.crt" ] || {
    openssl ecparam -name prime256v1 -genkey -noout -out "$name.key"
    openssl req -new -key "$name.key" -subj "/CN=$name" -out "$name.csr"
    printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost%s\n' "$san" > "$name.ext"
    openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days "$DAYS" -extfile "$name.ext" -out "$name.crt" 2>/dev/null
    rm -f "$name.csr" "$name.ext"; }
  echo "# 每机配置: $name"; echo "TLS_CRT_B64=$(base64 < "$name.crt" | tr -d '\n')"; echo "TLS_KEY_B64=$(base64 < "$name.key" | tr -d '\n')"
done
