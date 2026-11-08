#!/usr/bin/env bash
# 可重复安装，只替换本仓提交前钩子，保留其它钩子。
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git config --get core.hooksPath || true)" ]]; then
  echo '检测到自定义 core.hooksPath；为避免覆盖共享钩子目录，拒绝安装。' >&2
  exit 1
fi
hooks_dir=$(git rev-parse --git-path hooks)
mkdir -p "$hooks_dir"
chmod +x scripts/pre-commit scripts/oosp-lint.sh
ln -snf "$PWD/scripts/pre-commit" "$hooks_dir/pre-commit"
echo "已安装本仓提交前钩子（含 Patroni 后端门禁）"
