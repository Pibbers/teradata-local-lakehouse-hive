#!/usr/bin/env bash
# =============================================================
# reset_demo.sh
# Wipe all demo data and Teradata objects so run_demo.sh can
# be re-run against a clean state.
#
# What this drops:
#   Teradata  — all tables, foreign tables, auth objects
#               (in lakehouse_demo AND TD_SERVER_DB), the
#               DATALAKE, and the lakehouse_demo database
#   MinIO     — all buckets; recreates raw + iceberg empty
#   HMS/MySQL — drops and recreates the metastore schema so
#               all table and namespace registrations are gone
# =============================================================

set -euo pipefail
cd "$(dirname "$0")"

# ── Load .env ─────────────────────────────────────────────────
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

HOST_IP="${HOST_IP:-192.168.1.242}"
TD_HOST="${TD_HOST:-192.168.1.199}"
TD_USER="${TD_USER:-dbc}"
TD_PASSWORD="${TD_PASSWORD:-dbc}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
MINIO_API_PORT="${MINIO_API_PORT:-9000}"

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}  ✓  $*${RESET}"; }
skip() { echo -e "${YELLOW}  -  $*${RESET}"; }
info() { echo -e "${YELLOW}  →  $*${RESET}"; }
hr()   { echo -e "\n${BOLD}═══════════════════════════════════════${RESET}"; }

# ── BTEQ helper: run SQL, ignore object-not-found errors ──────
drop_td() {
  local desc="$1"
  local sql="$2"
  local bteq_output
  bteq_output=$(
    {
      printf ".SET WIDTH 200;\n"
      printf ".SET ERRORLEVEL 3807 SEVERITY 0;\n"
      printf ".SET ERRORLEVEL 5495 SEVERITY 0;\n"
      printf ".LOGON %s/%s,%s;\n" "$TD_HOST" "$TD_USER" "$TD_PASSWORD"
      printf "%s\n" "$sql"
      printf "\n.LOGOFF;\n.EXIT;\n"
    } | docker compose exec -T tpt bteq 2>&1
  ) || true

  if echo "$bteq_output" | grep -qi "does not exist\|Object not found\|not found\|3807\|5495"; then
    skip "$desc — not found, skipping"
  elif echo "$bteq_output" | grep -qi "Failure\|Error"; then
    echo -e "${RED}  ✗  $desc — unexpected error:${RESET}"
    echo "$bteq_output" | grep -i "Failure\|Error" | head -3
  else
    ok "$desc"
  fi
}

# ── 1. Teradata objects ───────────────────────────────────────
hr
echo -e "${BOLD}1/3  Drop Teradata objects${RESET}"

tpt_status=$(docker compose ps tpt --format "{{.Status}}" 2>/dev/null || echo "missing")
if ! echo "$tpt_status" | grep -qi "running\|up"; then
  info "Starting tpt container..."
  docker compose up -d tpt
  sleep 3
fi

# Drop tables and foreign tables first (they depend on auth objects)
drop_td "DROP TABLE sales_events_nos_out_verify"  "DROP TABLE lakehouse_demo.sales_events_nos_out_verify;"
drop_td "DROP TABLE sales_events_nos_out"         "DROP TABLE lakehouse_demo.sales_events_nos_out;"
drop_td "DROP TABLE sales_events_td"              "DROP TABLE lakehouse_demo.sales_events_td;"
drop_td "DROP TABLE sales_events_nos"             "DROP TABLE lakehouse_demo.sales_events_nos;"

# Drop the DATALAKE (OTF) — Teradata stores it in TD_SERVER_DB internally;
# no need to switch to lakehouse_demo first (avoids false skip when DB doesn't exist)
drop_td "DROP DATALAKE lakehouse_iceberg"         "DROP DATALAKE lakehouse_iceberg;"

# Drop auth objects in lakehouse_demo (NOS auth)
drop_td "DROP AUTHORIZATION minio_nos_auth"       "DROP AUTHORIZATION lakehouse_demo.minio_nos_auth;"
drop_td "DROP AUTHORIZATION minio_write_auth"     "DROP AUTHORIZATION lakehouse_demo.minio_write_auth;"

# Drop all demo DALAKEs regardless of name — must happen before auth drops
# Auth objects in TD_SERVER_DB cannot be dropped while any DATALAKE references them.
# Query DBC.Tables for TableKind='K' (DATALAKE) and drop each one found.
info "Dropping all demo DALAKEs in TD_SERVER_DB..."
datalake_names=$(
  {
    printf ".SET WIDTH 200;\n"
    printf ".SET ERRORLEVEL SEVERITY 0;\n"
    printf ".LOGON %s/%s,%s;\n" "$TD_HOST" "$TD_USER" "$TD_PASSWORD"
    printf "SELECT TableName FROM DBC.Tables WHERE DatabaseName = 'TD_SERVER_DB' AND TableKind = 'K';\n"
    printf ".LOGOFF;\n.EXIT;\n"
  } | docker compose exec -T tpt bteq 2>&1 \
    | awk '/^[[:space:]]+[A-Za-z]/ && !/TableName/ && !/-------/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' \
  || true
)
for dl in $datalake_names; do
  drop_td "DROP DATALAKE $dl" "DROP DATALAKE $dl;"
done

# Drop all auth objects in TD_SERVER_DB (OTF/DATALAKE auth — must live there)
info "Dropping all auth objects in TD_SERVER_DB..."
auth_names=$(
  {
    printf ".SET WIDTH 200;\n"
    printf ".LOGON %s/%s,%s;\n" "$TD_HOST" "$TD_USER" "$TD_PASSWORD"
    printf "SELECT AuthorizationName FROM DBC.Authorizations WHERE DatabaseName = 'TD_SERVER_DB';\n"
    printf ".LOGOFF;\n.EXIT;\n"
  } | docker compose exec -T tpt bteq 2>&1 \
    | awk '/^[[:space:]]+[A-Za-z]/ && !/Authorization/ && !/-------/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' \
  || true
)
for auth in $auth_names; do
  drop_td "DROP AUTHORIZATION $auth (TD_SERVER_DB)" "DATABASE TD_SERVER_DB; DROP AUTHORIZATION $auth;"
done

# Drop the user database last
drop_td "DROP DATABASE lakehouse_demo"            "DROP DATABASE lakehouse_demo;"

# ── 2. MinIO — wipe all buckets, recreate standard ones ───────
hr
echo -e "${BOLD}2/3  Reset MinIO object store${RESET}"

COMPOSE_PROJECT=$(docker compose config --format json 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','teradata-local-lakehouse-hive'))" \
  2>/dev/null || basename "$(pwd)")

DEMO_NET="${COMPOSE_PROJECT}_demo-net"

mc_cmd() {
  docker run --rm \
    --network "$DEMO_NET" \
    --entrypoint sh \
    minio/mc:latest \
    -c "mc alias set local http://minio-server:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD --quiet && $1"
}

# Remove every bucket that exists, then recreate the two standard ones
info "Listing existing MinIO buckets..."
existing_buckets=$(mc_cmd "mc ls local/ --json 2>/dev/null" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            obj = json.loads(line)
            print(obj.get('key','').rstrip('/'))
        except Exception:
            pass
" 2>/dev/null || echo "")

for bucket in $existing_buckets; do
  [[ -z "$bucket" ]] && continue
  info "Removing bucket: $bucket"
  mc_cmd "mc rb --force local/$bucket 2>/dev/null || true" \
    && ok "Removed: $bucket" || skip "Could not remove: $bucket"
done

info "Creating bucket: raw"
mc_cmd "mc mb local/raw && mc anonymous set download local/raw" \
  && ok "Created: raw" || skip "raw already exists"

info "Creating bucket: iceberg"
mc_cmd "mc mb local/iceberg && mc anonymous set download local/iceberg" \
  && ok "Created: iceberg" || skip "iceberg already exists"

# ── 3. HMS — reset Hive Metastore via MySQL ───────────────────
hr
echo -e "${BOLD}3/3  Reset Hive Metastore${RESET}"

mysql_status=$(docker compose ps mysql --format "{{.Status}}" 2>/dev/null || echo "missing")
if echo "$mysql_status" | grep -qi "running\|up"; then
  info "Dropping and recreating HMS metastore schema in MySQL..."
  docker compose exec -T mysql mysql \
    -uroot -p"${MYSQL_ROOT_PASSWORD:-rootpassword}" \
    -e "DROP DATABASE IF EXISTS metastore; CREATE DATABASE metastore CHARACTER SET latin1;" \
    2>/dev/null && ok "HMS metastore schema recreated" || skip "MySQL reset skipped"

  info "Restarting hive-metastore to re-initialise schema..."
  docker compose restart hive-metastore 2>/dev/null \
    && ok "hive-metastore restarted" || skip "Could not restart hive-metastore"

  info "Waiting for hive-metastore to be healthy..."
  for i in $(seq 1 30); do
    if docker compose exec -T hive-metastore bash -c 'echo >/dev/tcp/localhost/9083' 2>/dev/null; then
      ok "hive-metastore is ready"
      break
    fi
    sleep 3
  done
else
  skip "MySQL not running — HMS reset skipped"
fi

# ── Done ──────────────────────────────────────────────────────
hr
echo -e "${BOLD}Reset complete.${RESET}"
echo "Run ./run_demo.sh to rebuild from scratch."
