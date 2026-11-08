#!/bin/bash
# pgsodium 根密钥来自密钥库(PT_PGSODIUM_ROOT_KEY,64 位十六进制),每个成员(新机器也一样)启动前都把它放到配置卷里:
# 物理复制不带这个卷,新机器只拷数据库而没有这把钥匙,已有的 pgsodium 密文就解不开。
#   - 卷里已有同一把:什么都不做;已有但不一样:拒绝(绝不覆盖);
#   - 没给 PT_PGSODIUM_ROOT_KEY:卷里已有 key 文件(原 supabase 的卷)就放行,否则拒绝启动。
set -euo pipefail
FILE=${PGSODIUM_KEY_FILE:-/etc/postgresql-custom/pgsodium_root.key}
KEY=${PT_PGSODIUM_ROOT_KEY:-}
if [ -z "$KEY" ]; then
  [ -s "$FILE" ] && exit 0
  echo "pgsodium-key: refusing to start: PT_PGSODIUM_ROOT_KEY is empty and $FILE does not exist (capture the key from the current primary into the secret store first)" >&2
  exit 79
fi
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
