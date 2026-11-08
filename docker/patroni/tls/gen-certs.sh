#!/usr/bin/env bash
# 生成私有 CA 与每台机器一张节点证书(同时当 etcd / Patroni 的服务端和客户端证书),输出可直接填进平台配置的 base64 行。
# CA 私钥**不落盘**:全程在一次性临时目录里工作(退出即删);要沿用已有 CA,经环境变量 PT_CA_KEY_B64 / PT_CA_CRT_B64 传入
# (由 scripts/patroni_certs.py 从加密密钥库取);新生成的 CA 私钥只在标准输出的 `CA_KEY_B64=` 行里给调用方存进密钥库。
# 用法: MACHINES="us-ny1=IP[,IP2] us-mia=IP ..." tls/gen-certs.sh        一台机器有多个地址就逗号分隔(都进证书)
set -euo pipefail
: "${MACHINES:?}"
DAYS=${LEAF_DAYS:-1825}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT; umask 077; cd "$WORK"
if [ -n "${PT_CA_KEY_B64:-}" ] && [ -n "${PT_CA_CRT_B64:-}" ]; then
  echo "$PT_CA_KEY_B64" | base64 -d > ca.key; echo "$PT_CA_CRT_B64" | base64 -d > ca.crt; NEW_CA=0
else
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=one-patroni-ca\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.cnf
  openssl req -x509 -new -key ca.key -sha256 -days 3650 -config ca.cnf -out ca.crt; NEW_CA=1
fi
[ "$NEW_CA" = 1 ] && echo "CA_KEY_B64=$(base64 < ca.key | tr -d '\n')"
echo "# 服务级配置(所有机器相同)"; echo "TLS_CA_B64=$(base64 < ca.crt | tr -d '\n')"
for m in $MACHINES; do
  name=${m%%=*}; ips=${m#*=}; san=""; for a in ${ips//,/ }; do san="$san,IP:$a"; done
  openssl ecparam -name prime256v1 -genkey -noout -out "$name.key"
  # 节点证书不带 CN:etcd 开认证后,带 CN 的客户端证书走 HTTP 网关会被拒(Patroni 的 etcd3 客户端走的就是网关),身份靠 SAN 里的地址
  openssl req -new -key "$name.key" -subj "/O=one-patroni" -out "$name.csr"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost%s\n' "$san" > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days "$DAYS" -extfile "$name.ext" -out "$name.crt" 2>/dev/null
  echo "# 每机配置: $name"; echo "TLS_CRT_B64=$(base64 < "$name.crt" | tr -d '\n')"; echo "TLS_KEY_B64=$(base64 < "$name.key" | tr -d '\n')"
done
