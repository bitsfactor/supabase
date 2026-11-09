#!/bin/bash
# 可选管理 pgsodium 根密钥:未配置时不访问文件,沿用原卷;启用加密前必须先统一各机密钥。
# 显式配置 PT_PGSODIUM_ROOT_KEY(64 位十六进制)时写入空卷,已有同一把就放行,不同则拒绝覆盖。
set -euo pipefail
FILE=${PGSODIUM_KEY_FILE:-/etc/postgresql-custom/pgsodium_root.key}
KEY=${PT_PGSODIUM_ROOT_KEY:-}
[ -z "$KEY" ] && exit 0
[[ "$KEY" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "pgsodium-key: PT_PGSODIUM_ROOT_KEY is not 64 hex characters" >&2; exit 79; }
if [ -s "$FILE" ]; then
  [ "$(tr -d '[:space:]' < "$FILE")" = "$KEY" ] || { echo "pgsodium-key: $FILE holds a different key than the secret store: refusing to overwrite" >&2; exit 79; }
  exit 0
fi
umask 077
mkdir -p "$(dirname "$FILE")"
printf '%s' "$KEY" > "$FILE"
chmod 600 "$FILE"
[ -n "${PGSODIUM_SKIP_CHOWN:-}" ] || chown postgres:postgres "$FILE"
