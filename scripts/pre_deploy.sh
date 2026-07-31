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

# 4. Replication role (DR). NODE_ROLE defaults to `primary` — a normal Supabase
#    node, byte-for-byte the same deploy as before this block existed. A
#    `replica` is a read-only physical streaming standby; it is bootstrapped
#    EXPLICITLY (pg_basebackup -R from the primary, see
#    docs/dr-failover-runbook.md), NEVER auto-created here — a misconfigured
#    NODE_ROLE must never wipe data. So this block only VALIDATES (read-only):
#    it refuses to deploy a replica over a PGDATA that isn't already a standby.
NODE_ROLE="${NODE_ROLE:-primary}"
if [[ "$NODE_ROLE" == "replica" ]]; then
  if [[ -z "${REPLICA_PRIMARY_HOST:-}" ]]; then
    echo "pre_deploy: NODE_ROLE=replica but REPLICA_PRIMARY_HOST is unset" >&2
    exit 1
  fi
  if [[ ! -f docker/volumes/db/data/standby.signal ]]; then
    echo "pre_deploy: NODE_ROLE=replica but PGDATA is not a standby (no standby.signal)." >&2
    echo "pre_deploy: bootstrap the replica first — pg_basebackup -R from ${REPLICA_PRIMARY_HOST}; see docs/dr-failover-runbook.md." >&2
    exit 1
  fi
  echo "pre_deploy: NODE_ROLE=replica — streaming standby of ${REPLICA_PRIMARY_HOST} (slot ${REPLICATION_SLOT:-unset})"
else
  echo "pre_deploy: NODE_ROLE=primary"
fi

echo "pre_deploy: ok (docker/.env -> ../.env linked, env sanity passed)"
