#!/usr/bin/env bash
# =============================================================
# run_demo.sh
# End-to-end setup for the Teradata Local Lakehouse demo.
#
# Steps:
#   1. Docker service health checks
#   2. Network connectivity checks
#   3. Start TPT container (if not running)
#   4. Generate raw Parquet files → MinIO (NOS path)
#   5. Create Iceberg table in Hive Metastore (OTF path)
#   6. Run all Teradata SQL scripts via BTEQ in TPT container
#
# Prerequisites:
#   pip install -r requirements.txt
#   docker compose up -d       (minio + hive-metastore healthy)
#   .env configured with TD_HOST, TD_USER, TD_PASSWORD
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
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; RESET="\033[0m"
ok()   { echo -e "${GREEN}  ✓  $*${RESET}"; }
fail() { echo -e "${RED}  ✗  $*${RESET}"; exit 1; }
info() { echo -e "${YELLOW}  →  $*${RESET}"; }
hr()   { echo -e "\n${BOLD}═══════════════════════════════════════${RESET}"; }

bteq_failure_hint() {
  local file="$1"
  case "$(basename "$file")" in
    04_nos_writeback.sql)
      echo "If the failure occurs here, verify the MinIO host:port embedded in sql/teradata/04_nos_writeback.sql matches HOST_IP and MINIO_API_PORT in .env."
      ;;
    02_nos_foreign_table.sql|05_otf_setup.sql)
      echo "Verify the MinIO host:port embedded in $file matches HOST_IP and MINIO_API_PORT in .env."
      ;;
    *)
      echo ""
      ;;
  esac
}

# ── BTEQ runner ───────────────────────────────────────────────
# Writes the SQL file to /tmp inside the TPT container (always
# writable), then runs BTEQ with .RUN FILE.  This avoids stdin
# piping issues where BTEQ misparses semicolons inside SQL comments.
# BTEQ exit codes: 0=ok, 4=warnings (treated as ok), 8+=error.
run_bteq() {
  local desc="$1"
  local file="$2"
  local tmpfile="/tmp/bteq_$(basename "$file")"

  info "BTEQ: $desc"

  docker compose exec -T tpt bash -c "cat > $tmpfile" < "$file"

  {
    printf ".SET WIDTH 200;\n"
    printf ".SET FORMAT ON;\n"
    printf ".LOGON %s/%s,%s;\n" "$TD_HOST" "$TD_USER" "$TD_PASSWORD"
    printf ".RUN FILE %s\n" "$tmpfile"
    printf ".LOGOFF;\n"
    printf ".EXIT;\n"
  } | docker compose exec -T tpt bteq
  local rc=$?

  docker compose exec -T tpt rm -f "$tmpfile"

  if [[ $rc -le 4 ]]; then
    ok "$desc"
  else
    local hint
    hint="$(bteq_failure_hint "$file")"
    if [[ -n "$hint" ]]; then
      fail "$desc — BTEQ exited with code $rc. $hint"
    fi
    fail "$desc — BTEQ exited with code $rc"
  fi
}

# ── 1. Docker services ────────────────────────────────────────
hr
echo -e "${BOLD}1/6  Docker service health${RESET}"

docker compose ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null \
  || fail "docker compose not available — run 'docker compose up -d' first"

for svc in minio hive-metastore; do
  status=$(docker compose ps "$svc" --format "{{.Status}}" 2>/dev/null || echo "missing")
  if echo "$status" | grep -qi "healthy\|running"; then
    ok "$svc — $status"
  else
    fail "$svc is not healthy (status: $status). Run: docker compose up -d $svc"
  fi
done

# ── 2. Connectivity checks ────────────────────────────────────
hr
echo -e "${BOLD}2/6  Connectivity checks${RESET}"

nc -zw3 "$HOST_IP" "$MINIO_API_PORT" 2>/dev/null \
  && ok "MinIO API  $HOST_IP:$MINIO_API_PORT" \
  || fail "Cannot reach MinIO at $HOST_IP:$MINIO_API_PORT"

curl -sf "http://$HOST_IP:$MINIO_API_PORT/minio/health/live" \
  && ok "MinIO health check" \
  || fail "MinIO health endpoint did not respond"

nc -zw3 "$HOST_IP" 9083 2>/dev/null \
  && ok "Hive Metastore  $HOST_IP:9083" \
  || fail "Cannot reach Hive Metastore at $HOST_IP:9083"

nc -zw3 "$TD_HOST" 1025 2>/dev/null \
  && ok "Teradata  $TD_HOST:1025" \
  || fail "Cannot reach Teradata at $TD_HOST:1025 — check TD_HOST in .env"

# ── 3. Start TPT container ────────────────────────────────────
hr
echo -e "${BOLD}3/6  TPT container${RESET}"

tpt_status=$(docker compose ps tpt --format "{{.Status}}" 2>/dev/null || echo "missing")
if echo "$tpt_status" | grep -qi "running\|up"; then
  ok "tpt container already running"
else
  info "Starting tpt container..."
  docker compose up -d tpt
  sleep 3
  ok "tpt container started"
fi

# ── 4. Generate raw Parquet data ──────────────────────────────
hr
echo -e "${BOLD}4/6  Generate raw sample data → MinIO (NOS path)${RESET}"

python3 scripts/generate_data.py \
  || fail "generate_data.py failed"

ok "7 Parquet files uploaded to s3://raw/sales_events/"

# ── 5. Create Iceberg table in Hive Metastore ─────────────────
hr
echo -e "${BOLD}5/6  Create Iceberg table in Hive Metastore (OTF path)${RESET}"

python3 scripts/create_iceberg.py \
  || fail "create_iceberg.py failed"

ok "Iceberg table demo.sales_events created in HMS"

# ── 6. Teradata SQL via BTEQ in TPT container ─────────────────
hr
echo -e "${BOLD}6/6  Teradata SQL scripts via BTEQ${RESET}"

run_bteq "00 — create lakehouse_demo database"    sql/teradata/00_setup_database.sql
run_bteq "01 — NOS authorization (MinIO)"          sql/teradata/01_nos_authorization.sql
run_bteq "02 — NOS foreign table"                  sql/teradata/02_nos_foreign_table.sql
run_bteq "03 — NOS read + load to native table"    sql/teradata/03_nos_read_validation.sql
run_bteq "04 — NOS write-back to object store"     sql/teradata/04_nos_writeback.sql
run_bteq "05 — OTF DATALAKE setup"                 sql/teradata/05_otf_setup.sql
run_bteq "06 — OTF read + time travel validation"  sql/teradata/06_otf_read_validation.sql

# ── Done ──────────────────────────────────────────────────────
hr
echo -e "${BOLD}Demo complete.${RESET}\n"
echo "MinIO Console : http://$HOST_IP:$MINIO_CONSOLE_PORT"
echo "  raw/sales_events/2024/...                  (NOS — 7 Parquet files)"
echo "  raw/sales_events_north_export/             (NOS write-back)"
echo "  iceberg/warehouse/demo/sales_events/       (Iceberg table)"
echo ""
echo "Teradata objects created in: $TD_HOST"
echo "  lakehouse_demo.sales_events_nos            (NOS foreign table)"
echo "  lakehouse_demo.sales_events_td             (native table loaded from NOS + OTF)"
echo "  lakehouse_iceberg.demo.sales_events        (OTF DATALAKE — 3-part ref)"
echo ""
echo "To reset and re-run: ./reset_demo.sh"
