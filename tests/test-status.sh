#!/bin/sh
# Exercise clodball-status with a fake ps and fixture files; it must change nothing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
status_script=${CLODBALL_STATUS:-"$here/../skills/clodBall/scripts/clodball-status"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM
TZ=UTC
export TZ

fail() {
  echo "FAIL: $*"
  exit 1
}

# Builds $case_dir/world (handoff, state dir, home) and a fake ps and codex on PATH.
fixture() {
  case_dir="$tmp/$1"
  mkdir -p "$case_dir/bin" "$case_dir/world/home" "$case_dir/world/state dir"
  handoff="$case_dir/world/shared handoff.md"
  other="$case_dir/world/other.md"
  state_dir="$case_dir/world/state dir"
  home="$case_dir/world/home"
  marker="$case_dir/codex-marker"
  : > "$case_dir/ps.out"
  printf '# Handoff\n' > "$handoff"
  cat > "$case_dir/bin/ps" <<'SH'
#!/bin/sh
cat "$STATUS_TEST_CASE/ps.out"
SH
  cat > "$case_dir/bin/codex" <<'SH'
#!/bin/sh
echo called > "$STATUS_TEST_MARKER"
SH
  chmod +x "$case_dir/bin/ps" "$case_dir/bin/codex"
  STATUS_TEST_CASE=$case_dir
  STATUS_TEST_MARKER=$marker
  export STATUS_TEST_CASE STATUS_TEST_MARKER
}

run_status() {
  if PATH="$case_dir/bin:$PATH" HOME="$home" "$status_script" "$@" > "$case_dir/out" 2> "$case_dir/err"; then
    run_code=0
  else
    run_code=$?
  fi
}

has() {
  grep -Fxq -- "$1" "$case_dir/out" || fail "missing line: $1
$(cat "$case_dir/out")"
}

lacks() {
  if grep -Fq -- "$1" "$case_dir/out"; then
    fail "unexpected text: $1
$(cat "$case_dir/out")"
  fi
}

live() {
  fixture live
  {
    printf '  101 /bin/sh /x/scripts/clodball-watch claude %s 30 12\n' "$handoff"
    printf '  102 /bin/zsh -c source /x/snap.sh && eval '"'"'/x/scripts/clodball-watch claude %s 30 99'"'"'\n' "$handoff"
    printf '  103 sleep 30\n'
  } >> "$case_dir/ps.out"
  run_status "$handoff"
  [ "$run_code" -eq 0 ] || fail "live run exited $run_code"
  has 'Watcher claude: running pid 101 cursor 12'
  has 'Watcher cx: none running'
  lacks 'Duplicate:'
  lacks '102'
  echo 'ok: a running watcher is reported once; a shell wrapper that merely mentions it is not a watcher'
}

duplicate() {
  fixture duplicate
  {
    printf '  201 /x/scripts/clodball-watch cx %s 5\n' "$handoff"
    printf '  202 sh /x/scripts/clodball-watch cx %s 30 7\n' "$handoff"
    printf '  203 /x/scripts/clodball-watch cx %s 30 7\n' "$other"
    printf '  204 /x/scripts/clodball-watch cx %s.bak 30 7\n' "$handoff"
  } >> "$case_dir/ps.out"
  run_status "$handoff"
  has 'Watcher cx: running pid 201 cursor 5'
  has 'Watcher cx: running pid 202 cursor 7'
  has 'Duplicate: 2 watchers for cx on this handoff (not stopped)'
  lacks 'pid 203'
  lacks 'pid 204'
  echo 'ok: duplicate watchers on this handoff are listed and counted; other paths are ignored'
}

stale() {
  fixture stale
  printf 'watching\n' > "$state_dir/phase.txt"
  run_status "$handoff" "$state_dir"
  has "Launcher state $state_dir:"
  has '  live launcher: no'
  has '  receipt: none'
  has '  note: recorded phase is stale; no launcher process is running'
  echo 'ok: a watching phase with no launcher process is marked stale'
}

ps_failed() {
  fixture ps-failed
  printf '#!/bin/sh\nexit 1\n' > "$case_dir/bin/ps"
  printf 'watching\n' > "$state_dir/phase.txt"
  run_status "$handoff" "$state_dir"
  [ "$run_code" -eq 0 ] || fail "ps-failed run exited $run_code"
  has 'Watcher claude: unknown (process list unavailable)'
  has 'Watcher cx: unknown (process list unavailable)'
  has '  live launcher: unknown (process list unavailable)'
  lacks 'none running'
  lacks 'stale'
  echo 'ok: a failed process listing reports unknown and draws no stale or exited conclusion'
}

live_launcher() {
  fixture live-launcher
  printf 'watching\n' > "$state_dir/phase.txt"
  printf '  301 /bin/sh /x/scripts/clodball-codex 01234567-89ab-cdef-0123-456789abcdef %s 4 %s\n' "$handoff" "$state_dir" >> "$case_dir/ps.out"
  run_status "$handoff" "$state_dir"
  has '  live launcher: yes pid 301'
  lacks 'note:'
  [ "$(grep -c '^Launcher state ' "$case_dir/out")" -eq 1 ] || fail 'state directory listed twice'
  echo 'ok: a live launcher is found and its state directory is listed once'
}

queued() {
  fixture queued
  printf 'queued\n' > "$state_dir/phase.txt"
  printf 'Queued message 11111111-2222-3333-4444-555555555555 for thread t.\n' > "$state_dir/queue.out"
  touch -t 202603011200.00 "$state_dir/phase.txt"
  {
    printf '## claude → cx: first — 2026-03-01T11:00:00Z\n\nBall: cx\n\n'
    printf '## cx → claude: early — 2026-03-01T11:30:00Z\n\nBall: claude\n\n'
    printf '## cx → claude: later — 2026-03-01T12:30:00Z\n\nBall: claude\n'
  } >> "$handoff"
  run_status "$handoff" "$state_dir"
  has '  recorded phase: queued at 2026-03-01T12:00:00Z'
  has '  receipt: Queued message 11111111-2222-3333-4444-555555555555 for thread t.'
  has '  note: queued and launcher exited (normal); queued is not read'
  has '  cx entry after queue: 2026-03-01T12:30:00Z'
  lacks 'delivered'
  # Variant: no cx entry at or after the phase time.
  touch -t 202603011300.00 "$state_dir/phase.txt"
  run_status "$handoff" "$state_dir"
  has '  cx entry after queue: not found'
  echo 'ok: queued is reported as a normal exit with the first later cx entry, or not found'
}

uncertain() {
  fixture uncertain
  printf 'queue-outcome-uncertain\n' > "$state_dir/phase.txt"
  run_status "$handoff" "$state_dir"
  has '  note: queue outcome uncertain; inspect queue.out before retrying'
  echo 'ok: an uncertain queue outcome points at queue.out'
}

missing_evidence() {
  fixture missing
  rm "$handoff"
  run_status "$handoff"
  [ "$run_code" -eq 0 ] || fail "missing handoff exited $run_code instead of 0"
  has "Handoff: $handoff"
  has '  readable: no'
  has 'Watcher claude: none running'
  has 'Watcher cx: none running'
  has 'Skill files: claude missing, codex missing (files only; host discovery unknown)'
  has 'Requests: unknown'
  has 'Kickoff: unknown'
  lacks 'Requests: none'
  mkdir -p "$home/.claude/skills/clodBall"
  : > "$home/.claude/skills/clodBall/SKILL.md"
  run_status "$handoff"
  has 'Skill files: claude found, codex missing (files only; host discovery unknown)'
  echo 'ok: a missing handoff and no other evidence still produce a full report with exit 0'
}

requests() {
  fixture requests
  {
    printf '## claude → cx: old — 2026-03-01T08:00:00Z\n\nBall: cx\nAsk: stale thing\n\n'
    printf '## claude → cx: kickoff — 2026-03-01T09:00:00Z\n\nAsk: none\nBall: none\n\n'
    printf '## cx → claude: kickoff — confirmed — 2026-03-01T09:05:00Z\n\nAsk: none\nBall: none\n\n'
    printf '## cx → claude: review one — 2026-03-01T10:00:00Z\n\nAsk: none\nBall: claude\n\n'
    printf '## claude → cx: answer one — 2026-03-01T10:10:00Z\n\nAsk: none\nBall: none\nRe: 2026-03-01T10:00:00Z\n\n'
    printf '## cx → claude: review two — 2026-03-01T11:00:00Z\n\nAsk: please look again\nBall: cx\n\n'
    printf '## claude → cx: unrelated — 2026-03-01T11:10:00Z\n\nAsk: none\nBall: none\n\n'
    printf '## cx → claude: review three — 2026-03-01T12:00:00Z\n\n## Findings\n\nAsk: Claude, inspect the findings\nBall: claude\n\n'
    printf '## cx → claude: unstamped\n\nBall: claude\n\n'
    printf '## claude → cx: plain — 2026-03-01T13:00:00Z\n\nAsk: none\nBall: none\n'
  } >> "$handoff"
  run_status "$handoff"
  has 'Kickoff: 2026-03-01T09:00:00Z'
  has 'Request for claude: 2026-03-01T12:00:00Z review three — cited in claude'"'"'s Re: no; later claude entry: yes'
  has 'Request for claude:  unstamped — cited in claude'"'"'s Re: no; later claude entry: yes'
  has 'Request for claude: 2026-03-01T10:00:00Z review one — cited in claude'"'"'s Re: yes; later claude entry: yes'
  has 'Request for claude: 2026-03-01T11:00:00Z review two — cited in claude'"'"'s Re: no; later claude entry: yes'
  has 'Last entry claude: plain 2026-03-01T13:00:00Z'
  has 'Last entry cx: unstamped '
  lacks 'stale thing'
  lacks 'Request for cx:'
  lacks 'Requests: none'
  for word in resolved answered unread; do lacks "$word"; done
  echo 'ok: requests since the real kickoff report citation and later-entry facts; "kickoff — confirmed" is not the kickoff'
}

read_only() {
  fixture read-only
  printf 'queued\n' > "$state_dir/phase.txt"
  printf 'Queued message x.\n' > "$state_dir/queue.out"
  printf '## cx → claude: a — 2026-03-01T10:00:00Z\n\nBall: claude\n' >> "$handoff"
  printf '  101 /x/scripts/clodball-watch claude %s 30 12\n' "$handoff" >> "$case_dir/ps.out"
  snapshot() {
    ls -lR "$case_dir/world"
    find "$case_dir/world" -type f -exec cksum {} + | sort
  }
  snapshot > "$case_dir/before"
  run_status "$handoff" "$state_dir"
  snapshot > "$case_dir/after"
  [ "$run_code" -eq 0 ] || fail "read-only run exited $run_code"
  cmp -s "$case_dir/before" "$case_dir/after" || fail 'the run changed the handoff directory, the state directory, or home'
  [ ! -e "$marker" ] || fail 'the run called codex'
  echo 'ok: the run changes no file and never calls codex'
}

bad_args() {
  fixture bad-args
  run_status
  [ "$run_code" -eq 2 ] || fail "no arguments exited $run_code instead of 2"
  [ -s "$case_dir/err" ] || fail 'no arguments gave no diagnostic'
  run_status relative/handoff.md
  [ "$run_code" -eq 2 ] || fail "relative path exited $run_code instead of 2"
  [ -s "$case_dir/err" ] || fail 'relative path gave no diagnostic'
  echo 'ok: no arguments or a relative path exit 2 with a diagnostic'
}

case "${1:-all}" in
  live) live ;;
  duplicate) duplicate ;;
  stale) stale ;;
  live-launcher) live_launcher ;;
  ps-failed) ps_failed ;;
  queued) queued ;;
  uncertain) uncertain ;;
  missing) missing_evidence ;;
  requests) requests ;;
  read-only) read_only ;;
  bad-args) bad_args ;;
  all) live; duplicate; stale; live_launcher; ps_failed; queued; uncertain; missing_evidence; requests; read_only; bad_args ;;
  *) fail "unknown test: $1" ;;
esac
