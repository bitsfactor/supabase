#!/usr/bin/env bash
# 生成投票组(etcd)与 Patroni 的证书、口令,并按机器打包。私钥与口令只落在 OUT 目录(.gitignore 已排除),
# 永不提交;入平台密钥库用 tls/store-secrets.sh(见 docs/secrets-spec.md)。可重跑:OUT 里已有 CA / 口令则沿用,只补发缺的叶子证书。
#
# 用法:
#   ETCD_MEMBERS="ny1=IP[|附加名,...] mia=IP ..."  DB_MEMBERS="ny1=IP[|附加名,...] ..."  tls/gen-certs.sh OUT
# 每台机器一个目录 OUT/machines/<名>/ :
#   tls/ca.crt                         信任根(所有容器用)
#   tls/etcd.crt, etcd.key             该机 etcd 的服务端 + 成员间 + 客户端证书(仅 ETCD_MEMBERS 里的机器)
#   tls/etcd-client.crt, etcd-client.key  Patroni 连 etcd 的客户端证书(无 CN,见 leaf 注释)
#   tls/patroni.crt, patroni.key, patroni.pem   Patroni REST 服务端证书,同时当客户端证书(成员间互调、库入口体检);.pem = 证书 + 私钥(HAProxy 要这个格式)
#   machine.env                        该机的部署参数(生产 compose 的 env_file;含口令,600)
# OUT/ca.key 永远不进任何机器的包。
set -euo pipefail
OUT=${1:?用法:gen-certs.sh OUT}
: "${ETCD_MEMBERS:?}" "${DB_MEMBERS:?}"
LEAF_DAYS=${LEAF_DAYS:-1825}
command -v openssl >/dev/null || { echo "需要 openssl" >&2; exit 1; }
umask 077
mkdir -p "$OUT/machines"
cd "$OUT"

# ---- CA ----
if [ ! -f ca.key ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 3650 -subj "/CN=one-patroni-ca" -out ca.crt \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null \
    || { # LibreSSL 没有 -addext:走配置文件
      printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=one-patroni-ca\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.cnf
      openssl req -x509 -new -key ca.key -sha256 -days 3650 -config ca.cnf -out ca.crt; rm -f ca.cnf; }
fi

# ---- 口令(随机,已有则沿用)----
[ -f passwords.env ] || {
  {
    echo "ETCD_ROOT_PASSWORD=$(openssl rand -hex 16)"
    echo "ETCD_PATRONI_PASSWORD=$(openssl rand -hex 16)"
    echo "PT_REST_PASSWORD=$(openssl rand -hex 16)"
    echo "PT_REPL_PASSWORD=$(openssl rand -hex 16)"
  } > passwords.env
}
# 早先生成的 passwords.env 没有复制口令:补一条(只补不改)
grep -q '^PT_REPL_PASSWORD=' passwords.env || echo "PT_REPL_PASSWORD=$(openssl rand -hex 16)" >> passwords.env

# leaf <目标目录> <文件名前缀> <CN> <IP> <附加名,逗号分隔>
leaf() {
  local dir=$1 prefix=$2 cn=$3 ip=$4 names=$5 san="IP:$4,IP:127.0.0.1,DNS:localhost" n
  for n in ${names//,/ }; do san="$san,DNS:$n"; done
  mkdir -p "$dir"
  [ -f "$dir/$prefix.crt" ] && openssl verify -CAfile ca.crt "$dir/$prefix.crt" >/dev/null 2>&1 && return 0
  openssl ecparam -name prime256v1 -genkey -noout -out "$dir/$prefix.key"
  # CN 为 "-" = 没有 CN 的客户端证书:etcd 开了认证后,经 HTTP 网关(Patroni 走这条)的请求若证书带 CN 会被拒
  # ("CommonName of client sending a request against gateway will be ignored"),身份靠口令,证书只做 TLS 双向校验。
  local subj="/CN=$cn"; [ "$cn" = "-" ] && subj="/O=one-patroni"
  openssl req -new -key "$dir/$prefix.key" -subj "$subj" -out "$dir/$prefix.csr"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=%s\n' "$san" > "$dir/$prefix.ext"
  openssl x509 -req -in "$dir/$prefix.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days "$LEAF_DAYS" -extfile "$dir/$prefix.ext" -out "$dir/$prefix.crt" 2>/dev/null
  rm -f "$dir/$prefix.csr" "$dir/$prefix.ext"
}

etcd_cluster="" etcd_hosts=""
for m in $ETCD_MEMBERS; do
  name=${m%%=*}; rest=${m#*=}; ip=${rest%%|*}; extra=""; [[ $rest == *"|"* ]] && extra=${rest#*|}
  etcd_cluster="$etcd_cluster,etcd-$name=https://$ip:2380"; etcd_hosts="$etcd_hosts,$ip:2379"
done
etcd_cluster=${etcd_cluster#,}; etcd_hosts=${etcd_hosts#,}
ha_nodes=""
for m in $DB_MEMBERS; do name=${m%%=*}; rest=${m#*=}; ip=${rest%%|*}; ha_nodes="$ha_nodes,$name=$ip:${PG_HOST_PORT:-5433}:${REST_PORT:-8008}"; done
ha_nodes=${ha_nodes#,}

names=$( (for m in $ETCD_MEMBERS $DB_MEMBERS; do echo "${m%%=*}"; done) | sort -u )
for name in $names; do
  d="machines/$name"; mkdir -p "$d/tls"; cp ca.crt "$d/tls/ca.crt"
  echo "MACHINE=$name" > "$d/machine.env"
  pw() { grep "^$1=" passwords.env >> "$d/machine.env"; }   # 每台只带自己要用的口令
  for m in $ETCD_MEMBERS; do
    [ "${m%%=*}" = "$name" ] || continue
    rest=${m#*=}; ip=${rest%%|*}; extra=""; [[ $rest == *"|"* ]] && extra=${rest#*|}
    leaf "$d/tls" etcd "etcd-$name" "$ip" "$extra"
    pw ETCD_ROOT_PASSWORD
    { echo "ETCD_NAME=etcd-$name"; echo "ETCD_IP=$ip"; echo "ETCD_INITIAL_CLUSTER=$etcd_cluster"; } >> "$d/machine.env"
  done
  for m in $DB_MEMBERS; do
    [ "${m%%=*}" = "$name" ] || continue
    rest=${m#*=}; ip=${rest%%|*}; extra=""; [[ $rest == *"|"* ]] && extra=${rest#*|}
    leaf "$d/tls" patroni "patroni-$name" "$ip" "$extra"
    leaf "$d/tls" etcd-client "-" "$ip" ""        # Patroni → etcd 的客户端证书(无 CN)
    cat "$d/tls/patroni.crt" "$d/tls/patroni.key" > "$d/tls/patroni.pem"
    pw ETCD_PATRONI_PASSWORD; pw PT_REST_PASSWORD; pw PT_REPL_PASSWORD
    { echo "PT_NAME=$name"; echo "PT_HOST=$ip"; echo "PT_ETCD_HOSTS=$etcd_hosts"; echo "HA_NODES=$ha_nodes"; } >> "$d/machine.env"
  done
  chmod 600 "$d"/tls/*.key "$d"/tls/*.pem "$d/machine.env" 2>/dev/null || true
  chmod 644 "$d"/tls/*.crt
  COPYFILE_DISABLE=1 tar -C "$d" -czf "machines/$name.tar.gz" tls machine.env   # macOS 的 tar 会塞 ._ 元数据文件,关掉
done
echo "OK:$(echo $names | tr ' ' ',')  → $OUT/machines/<名>.tar.gz(CA 私钥 $OUT/ca.key 不在任何包里)"
