#!/usr/bin/env bash
set -u

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$WORK_DIR/chromego-filter-then-push-github.sh"
RUN_AT="${RUN_AT:-04:00}"
SCHEDULE_TZ="${SCHEDULE_TZ:-Asia/Shanghai}"
TEST_JOBS="${TEST_JOBS:-4}"
PROXY_TEST_TIMEOUT="${PROXY_TEST_TIMEOUT:-1}"

timestamp() {
  TZ="$SCHEDULE_TZ" date '+%Y-%m-%d %H:%M:%S %Z'
}

log() {
  printf '[%s] [chromego-daemon] %s\n' "$(timestamp)" "$*"
}

next_run_epoch() {
  local now target
  now="$(date +%s)"
  target="$(TZ="$SCHEDULE_TZ" date -d "today ${RUN_AT}" +%s 2>/dev/null || true)"
  if [ -z "$target" ]; then
    log "invalid RUN_AT or SCHEDULE_TZ value: RUN_AT=$RUN_AT SCHEDULE_TZ=$SCHEDULE_TZ"
    target="$(TZ="$SCHEDULE_TZ" date -d 'tomorrow 04:00' +%s)"
  fi
  if [ "$target" -le "$now" ]; then
    target="$(TZ="$SCHEDULE_TZ" date -d "tomorrow ${RUN_AT}" +%s)"
  fi
  printf '%s' "$target"
}

sleep_until() {
  local target now remaining chunk
  target="$1"
  while :; do
    now="$(date +%s)"
    remaining=$((target - now))
    [ "$remaining" -le 0 ] && return 0
    chunk="$remaining"
    [ "$chunk" -gt 3600 ] && chunk=3600
    sleep "$chunk"
  done
}

run_once() {
  if [ ! -x "$SCRIPT" ]; then
    log "script is not executable: $SCRIPT"
    return 127
  fi

  log "starting $SCRIPT"
  (
    cd "$WORK_DIR" || exit 127
    TZ="$SCHEDULE_TZ" TEST_JOBS="$TEST_JOBS" PROXY_TEST_TIMEOUT="$PROXY_TEST_TIMEOUT" "$SCRIPT"
  )
}

log "started; daily run time=${RUN_AT}, schedule timezone=${SCHEDULE_TZ}, TEST_JOBS=${TEST_JOBS}, PROXY_TEST_TIMEOUT=${PROXY_TEST_TIMEOUT}"
while :; do
  target="$(next_run_epoch)"
  log "next run: $(TZ="$SCHEDULE_TZ" date -d "@$target" '+%Y-%m-%d %H:%M:%S %Z')"
  sleep_until "$target"
  run_once
  rc=$?
  log "run finished with exit code $rc"
done
