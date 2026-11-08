#!/usr/bin/env bash
# 把 gen-certs.sh 的产物存进平台密钥库(docs/secrets-spec.md:git 密文库 secrets.enc.env,值是密文),此后可删 OUT 目录。
# 键:PATRONI_CA_KEY(CA 私钥,只在 operator 侧)、PATRONI_BUNDLE_<机器名大写>(该机证书 + 口令包,base64)。
# 用法(在 one 仓库根):service-source/supabase/docker/patroni/tls/store-secrets.sh <OUT> [--dry-run]
# --dry-run 只列将写入的键。写入后的提交随 one 仓库的正常提交走(本脚本不 commit)。
set -euo pipefail
OUT=${1:?用法:store-secrets.sh OUT [--dry-run]}; DRY=${2:-}
put() { # put <键> <文件>
  if [ "$DRY" = --dry-run ]; then echo "would set $1 ($(wc -c < "$2") bytes)"; else base64 < "$2" | tr -d '\n' | .venv/bin/python -m one secrets set "$1"; fi
}
put PATRONI_CA_KEY "$OUT/ca.key"
for t in "$OUT"/machines/*.tar.gz; do n=$(basename "$t" .tar.gz); put "PATRONI_BUNDLE_$(echo "$n" | tr a-z A-Z)" "$t"; done
