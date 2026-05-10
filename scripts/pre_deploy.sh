#!/usr/bin/env bash
# Run on the target node BEFORE `docker compose up`. Three jobs:
#   1. Symlink docker/.env -> ../.env so upstream compose (which runs
#      from the docker/ subdirectory) sees the env file ssl-service
#      wrote at the install_dir root (/opt/supabase/.env).
#   2. Make sure docker/volumes/... is writable (upstream commits stub
#      files; on a fresh clone they're root-owned by git checkout).
#   3. Sanity-check a few must-have envs before compose runs.
#
# Idempotent. Safe to re-run.

set -euo pipefail

# ssl-service writes .env at install_dir but does NOT export its
# contents into the hook's environment, so we source it ourselves
# (same pattern as service-source/chatbot/scripts/pre_deploy.sh).
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# 1. .env link — upstream compose's project dir is docker/, so it
#    looks for docker/.env by default. Point it at our ../.env.
ln -sfn ../.env docker/.env

# 2. docker/volumes/... permissions — git checkout on a fresh clone
#    leaves these owned by whichever user ran `git`; container UIDs
#    inside Postgres / Storage / Functions need rwx on subdirs.
chmod -R u+rwX docker/volumes 2>/dev/null || true

# 3. Required-env sanity check. The platform's required_env validator
#    catches most of this; the duplicate here is defense-in-depth so a
#    misconfigured deploy fails BEFORE compose starts pulling images
#    and wasting a couple minutes.
missing=()
for v in POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY \
         SUPABASE_PUBLIC_URL API_EXTERNAL_URL DASHBOARD_PASSWORD \
         SECRET_KEY_BASE VAULT_ENC_KEY PG_META_CRYPTO_KEY; do
  if [[ -z "${!v:-}" ]]; then
    missing+=("$v")
  fi
done
if (( ${#missing[@]} > 0 )); then
  echo "pre_deploy: required env missing: ${missing[*]}" >&2
  exit 1
fi

echo "pre_deploy: ok (docker/.env -> ../.env linked, env sanity passed)"
