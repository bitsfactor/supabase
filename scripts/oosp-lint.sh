#!/usr/bin/env bash
# 本地后端门禁；例：LINT_SCOPE=full scripts/oosp-lint.sh。
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
# 无关提交无需安装后端工具；--no-renames 同时检查改名前后的路径。
if [[ "${LINT_SCOPE:-}" != full && "$#" -eq 1 && "$1" == --staged ]] && \
    git diff --cached --no-renames --quiet -- docker/patroni scripts .deploy.patroni.yaml; then
  echo 'Patroni：本次提交未涉及后端，跳过'
  exit 0
fi
python_bin=${PYTHON:-python3}
superproject=$(git rev-parse --show-superproject-working-tree)
if [[ -z "${PYTHON:-}" ]]; then
  if [[ -x .venv/bin/python ]]; then
    python_bin="$PWD/.venv/bin/python"
  elif [[ -n "$superproject" && -x "$superproject/.venv/bin/python" ]]; then
    python_bin="$superproject/.venv/bin/python"
  fi
fi
if ! "$python_bin" -c 'import yaml, ruff' >/dev/null 2>&1; then
  echo '缺少 Python 检查依赖；安装说明见 docker/patroni/README.md' >&2
  exit 1
fi
exec "$python_bin" -B scripts/patroni-check.py "$@"
