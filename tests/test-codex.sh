#!/bin/sh
# Exercise the packaged launcher with a fake Codex CLI; never queue a live check.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
scripts="$here/../skills/clodBall/scripts"
launcher_source=${CLODBALL_CODEX:-"$scripts/clodball-codex"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
message_id=11111111-2222-3333-4444-555555555555

fail() {
  echo "FAIL: $*"
  exit 1
}

fixture() {
  thread=01234567-89ab-cdef-0123-456789abcdef
  case_dir="$tmp/$1"
  mkdir -p "$case_dir/bin" "$case_dir/skill/scripts" "$case_dir/state dir"
  [ -x "$launcher_source" ] || fail 'packaged launcher is missing or not executable'
  cp "$launcher_source" "$(dirname "$launcher_source")/clodball-watch" "$case_dir/skill/scripts/"
  launcher="$case_dir/skill/scripts/clodball-codex"
  handoff="$case_dir/shared \\backslash handoff.md"
  state_dir="$case_dir/state dir"
  printf '# Handoff\n\n## claude → cx: handled — 2000-01-01T00:00:00Z\n\nBall: cx\n' > "$handoff"
  cursor=$(wc -l < "$handoff" | tr -d '[:space:]')
  printf '%s\n' "$cursor" > "$state_dir/cursor.txt"
  export CODEX_TEST_CASE="$case_dir" CODEX_TEST_THREAD="$thread" CODEX_TEST_MESSAGE_ID="$message_id"
  cat > "$case_dir/bin/sleep" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >> "$CODEX_TEST_CASE/sleeps"
exit 2
SH
  cat > "$case_dir/bin/codex" <<'SH'
#!/bin/sh
printf 'call\n' >> "$CODEX_TEST_CASE/calls"
printf '%s\n' "$@" > "$CODEX_TEST_CASE/args"
printf 'Queued message %s for thread %s.\n' "$CODEX_TEST_MESSAGE_ID" "$CODEX_TEST_THREAD"
SH
  chmod +x "$case_dir/bin/sleep" "$case_dir/bin/codex"
}

run_launcher() {
  if PATH="$case_dir/bin:$PATH" "$launcher" "$thread" "$handoff" "$cursor" "$state_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"; then
    launch_status=0
  else
    launch_status=$?
  fi
}

ready() {
  printf '\n## claude → cx: review — 2000-01-01T00:00:01Z\n\nBall: cx\n' >> "$handoff"
}

success() {
  fixture success
  launcher=$launcher_source
  # The real watcher first sees only handled entries. Its first poll appends
  # a peer request through a fake sleep, so this also proves the default interval.
  export CODEX_TEST_HANDOFF="$handoff"
  cat > "$case_dir/bin/sleep" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >> "$CODEX_TEST_CASE/sleeps"
[ ! -e "$CODEX_TEST_CASE/expected-handoff" ] || exit 2
printf '\n## claude → cx: review — 2000-01-01T00:00:01Z\n\nAsk: inspect the artifact\nBall: cx\n' >> "$CODEX_TEST_HANDOFF"
cp "$CODEX_TEST_HANDOFF" "$CODEX_TEST_CASE/expected-handoff"
SH
  chmod +x "$case_dir/bin/sleep"
  run_launcher
  [ "$launch_status" -eq 0 ] || fail "valid handoff exited $launch_status: $(cat "$case_dir/stderr")"
  [ "$(cat "$state_dir/phase.txt")" = queued ] || fail 'valid check is not marked queued'
  [ "$(cat "$case_dir/calls")" = call ] || fail 'launcher did not queue exactly once'
  [ "$(cat "$case_dir/sleeps")" = 30 ] || fail 'watcher did not use its default interval exactly once'
  printf '%s\n' queue --thread "$thread" --message "\$clodBall check: new entry in $handoff" > "$case_dir/expected-args"
  cmp -s "$case_dir/expected-args" "$case_dir/args" || fail 'queued check has wrong arguments'
  cmp -s "$case_dir/expected-handoff" "$handoff" || fail 'launcher changed the handoff'
  [ "$(cat "$state_dir/cursor.txt")" = "$cursor" ] || fail 'launcher advanced the saved cursor'
  echo 'ok: real watcher uses the saved cursor and default interval, queues one exact check, and preserves handoff and cursor'
}

watcher_failure() {
  fixture watcher-failure
  rm "$handoff"
  run_launcher
  [ "$launch_status" -eq 2 ] || fail "failed watcher exited $launch_status instead of 2"
  [ "$(cat "$state_dir/phase.txt")" = watcher-failed ] || fail 'watcher failure did not update its phase'
  [ -s "$state_dir/wake.err" ] || fail 'watcher diagnostic was lost'
  [ ! -e "$case_dir/calls" ] || fail 'failed watcher still queued a check'
  echo 'ok: watcher failure keeps its diagnostic and exit status, reports failure, and queues nothing'
}

watcher_receipt() {
  fixture watcher-receipt
  cat > "$case_dir/skill/scripts/clodball-watch" <<'SH'
#!/bin/sh
printf 'clodball: new entry for cx in %s\nextra output\n' "$2"
SH
  run_launcher
  [ "$launch_status" -eq 2 ] || fail "malformed watcher receipt exited $launch_status instead of 2"
  [ "$(cat "$state_dir/phase.txt")" = invalid-wake-output ] || fail 'malformed watcher receipt is not reported'
  [ -s "$state_dir/wake.out" ] || fail 'malformed watcher receipt was lost'
  [ ! -e "$case_dir/calls" ] || fail 'malformed watcher receipt still queued a check'
  echo 'ok: extra watcher output is retained and refused before queuing'
}

queue_failure() {
  fixture queue-failure
  ready
  cat > "$case_dir/bin/codex" <<'SH'
#!/bin/sh
printf 'call\n' >> "$CODEX_TEST_CASE/calls"
echo 'queue transport failed' >&2
exit 7
SH
  run_launcher
  [ "$launch_status" -eq 7 ] || fail "failed Codex queue exited $launch_status instead of 7"
  [ "$(cat "$state_dir/phase.txt")" = queue-failed ] || fail 'Codex queue failure did not update its phase'
  [ "$(cat "$state_dir/queue.err")" = 'queue transport failed' ] || fail 'queue diagnostic was lost'
  [ "$(cat "$case_dir/calls")" = call ] || fail 'launcher retried the failed queue'
  echo 'ok: queue failure retains its diagnostic and exit status, reports failure, and does not retry'
}

queue_receipt() {
  for receipt_case in wrong-thread extra-output malformed-id empty missing-newline; do
    fixture "queue-receipt-$receipt_case"
    ready
    export CODEX_TEST_RECEIPT="$receipt_case"
    cat > "$case_dir/bin/codex" <<'SH'
#!/bin/sh
printf 'call\n' >> "$CODEX_TEST_CASE/calls"
case "$CODEX_TEST_RECEIPT" in
  wrong-thread) printf 'Queued message %s for thread %s.\n' "$CODEX_TEST_MESSAGE_ID" "$CODEX_TEST_MESSAGE_ID" ;;
  extra-output) printf 'Queued message %s for thread %s.\nextra output' "$CODEX_TEST_MESSAGE_ID" "$CODEX_TEST_THREAD" ;;
  malformed-id) printf 'Queued message not-an-id for thread %s.\n' "$CODEX_TEST_THREAD" ;;
  empty) ;;
  missing-newline) printf 'Queued message %s for thread %s.' "$CODEX_TEST_MESSAGE_ID" "$CODEX_TEST_THREAD" ;;
esac
SH
    run_launcher
    [ "$launch_status" -eq 2 ] || fail "$receipt_case queue receipt exited $launch_status instead of 2"
    [ "$(cat "$state_dir/phase.txt")" = queue-outcome-uncertain ] || fail "$receipt_case queue receipt is not marked uncertain"
    [ -f "$state_dir/queue.out" ] || fail "$receipt_case queue receipt was lost"
    [ "$(cat "$case_dir/calls")" = call ] || fail "$receipt_case queue receipt caused a retry"
  done
  echo 'ok: unexpected queue confirmations remain uncertain and are retained without retries'
}

state_reuse() {
  fixture state-reuse
  ready
  run_launcher
  [ "$launch_status" -eq 0 ] || fail 'initial launch did not queue a check'
  [ -s "$state_dir/queue.out" ] || fail 'initial launch left no queue receipt'
  rm "$handoff"
  run_launcher
  [ "$launch_status" -eq 2 ] || fail 'second launch did not report watcher failure'
  [ "$(cat "$state_dir/phase.txt")" = watcher-failed ] || fail 'second launch retained an old phase'
  [ ! -s "$state_dir/queue.out" ] || fail 'failed new launch retained an old queue confirmation'
  [ ! -s "$state_dir/queue.err" ] || fail 'failed new launch retained an old queue diagnostic'
  [ ! -e "$state_dir/expected-queue.txt" ] || fail 'failed new launch retained an old expected confirmation'
  [ "$(cat "$case_dir/calls")" = call ] || fail 'second launch queued another check'
  echo 'ok: a reused state directory clears old queue evidence before the next watcher starts'
}

invalid_thread() {
  fixture invalid-thread
  ready
  thread=not-a-thread-uuid
  run_launcher
  [ "$launch_status" -eq 2 ] || fail 'invalid thread was not refused with exit 2'
  [ "$(cat "$state_dir/phase.txt")" = invalid-arguments ] || fail 'invalid thread is not marked invalid arguments'
  [ ! -e "$case_dir/calls" ] || fail 'invalid thread reached Codex queue'
  [ -s "$case_dir/stderr" ] || fail 'invalid thread produced no diagnostic'
  echo 'ok: an invalid thread is refused before starting a watcher or queue'
}

uppercase_thread() {
  fixture uppercase-thread
  ready
  lowercase_thread=$thread
  thread=01234567-89AB-CDEF-0123-456789ABCDEF
  run_launcher
  [ "$launch_status" -eq 0 ] || fail 'a canonical confirmation for an uppercase thread was refused'
  [ "$(cat "$state_dir/phase.txt")" = queued ] || fail 'uppercase thread was not marked queued'
  printf '%s\n' queue --thread "$lowercase_thread" --message "\$clodBall check: new entry in $handoff" > "$case_dir/expected-args"
  cmp -s "$case_dir/expected-args" "$case_dir/args" || fail 'uppercase thread was not normalized before queueing'
  [ "$(cat "$case_dir/calls")" = call ] || fail 'uppercase thread caused a queue retry'
  echo 'ok: uppercase thread UUIDs use canonical lowercase for the queue and its confirmation'
}

unexpected_poll() {
  fixture unexpected-poll
  run_launcher
  [ "$launch_status" -eq 2 ] || fail 'unexpected polling was not stopped'
  [ "$(cat "$state_dir/phase.txt")" = watcher-failed ] || fail 'unexpected polling did not report watcher failure'
  [ "$(cat "$case_dir/sleeps")" = 30 ] || fail 'unexpected polling did not stop on its first sleep'
  [ ! -e "$case_dir/calls" ] || fail 'unexpected polling still queued a check'
  echo 'ok: unexpected polling fails immediately in the fixture instead of sleeping indefinitely'
}

invalid_rearm() {
  for invalid_argument in thread cursor; do
    fixture "invalid-rearm-$invalid_argument"
    ready
    run_launcher
    [ "$launch_status" -eq 0 ] || fail 'initial launch did not queue a check'
    case "$invalid_argument" in
      thread) thread=not-a-thread-uuid ;;
      cursor) cursor=not-a-cursor ;;
    esac
    run_launcher
    [ "$launch_status" -eq 2 ] || fail "invalid $invalid_argument re-arm was not refused"
    [ "$(cat "$state_dir/phase.txt")" = invalid-arguments ] || fail "invalid $invalid_argument re-arm retained an old phase"
    [ ! -s "$state_dir/wake.out" ] || fail "invalid $invalid_argument re-arm retained an old wake receipt"
    [ ! -s "$state_dir/queue.out" ] || fail "invalid $invalid_argument re-arm retained an old queue receipt"
    [ ! -e "$state_dir/expected-queue.txt" ] || fail "invalid $invalid_argument re-arm retained an old expected confirmation"
    [ "$(cat "$case_dir/calls")" = call ] || fail "invalid $invalid_argument re-arm queued a check"
  done
  echo 'ok: invalid re-arms clear prior receipts and report invalid arguments without another queue'
}

case "${1:-all}" in
  success) success ;;
  watcher-failure) watcher_failure ;;
  watcher-receipt) watcher_receipt ;;
  queue-failure) queue_failure ;;
  queue-receipt) queue_receipt ;;
  state-reuse) state_reuse ;;
  invalid-thread) invalid_thread ;;
  uppercase-thread) uppercase_thread ;;
  unexpected-poll) unexpected_poll ;;
  invalid-rearm) invalid_rearm ;;
  all) success; watcher_failure; watcher_receipt; queue_failure; queue_receipt; state_reuse; invalid_thread; uppercase_thread; unexpected_poll; invalid_rearm ;;
  *) fail "unknown test: $1" ;;
esac
