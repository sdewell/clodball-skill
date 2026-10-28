#!/bin/sh
# Exercise the watcher through its CLI, with bounded waits and owned cleanup.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
watch=${CLODBALL_WATCH:-"$here/../skills/clodBall/scripts/clodball-watch"}
tmp=$(mktemp -d)
pid=
cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
f="$tmp/HANDOFF.md"

fixture() {
  printf '# Handoff — test\n\n## cx → claude: kickoff — 2026-01-01T00:00Z\n\nBall: claude\n' > "$f"
  cursor=$(wc -l < "$f" | tr -d ' ')
}

launch() {
  # Clear the previous receipt before the child can race with wake().
  : > "$tmp/out"
  (
    # The output regression holds the child before it opens the receipt file.
    if [ -n "${launch_gate:-}" ]; then
      read -r _release < "$launch_gate"
    fi
    exec "$watch" "$@" > "$tmp/out"
  ) &
  pid=$!
}

start() {
  launch "$1" "$f" 1 "$cursor"
}

quiet() {
  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "FAIL: watcher fired on $1"
    exit 1
  fi
}

wake() {
  tries=0
  while [ ! -s "$tmp/out" ] && [ "$tries" -lt 5 ]; do
    sleep 1
    tries=$((tries + 1))
  done
  if [ ! -s "$tmp/out" ]; then
    echo "FAIL: $1"
    exit 1
  fi
  wait "$pid"
  pid=
  expected="clodball: new entry for $2 in $f"
  if [ "$(cat "$tmp/out")" != "$expected" ] || [ "$(wc -l < "$tmp/out" | tr -d ' ')" != 1 ]; then
    echo "FAIL: unexpected watcher output"
    exit 1
  fi
}

refused() {
  if "$watch" "$@" 2>/dev/null; then
    echo 'FAIL: invalid arguments accepted'
    exit 1
  else
    result=$?
  fi
  if [ "$result" -ne 2 ]; then
    echo "FAIL: invalid arguments exited $result instead of 2"
    exit 1
  fi
}

baseline() {
  fixture
  refused nobody "$f" 1 "$cursor"
  refused claude "$tmp/missing" 1 "$cursor"
  refused claude "$f"
  refused claude "$f" 1 "$cursor" extra
  refused claude "$f" 1 -1
  refused claude "$f" 1 invalid
  refused claude "$f" 0 "$cursor"
  refused claude "$f" invalid "$cursor"
  start claude
  sleep 1
  printf '\n## cx → claude: progress — 2026-01-01T00:05Z\n\nAsk: none\nBall: cx\n' >> "$f"
  quiet 'peer progress with Ball: cx'
  printf '\n## cx → claude: review — 2026-01-01T00:10Z\n\nBall: claude\n' >> "$f"
  wake 'Ball: claude did not wake claude' claude
  cursor=$(wc -l < "$f" | tr -d ' ')
  start cx
  sleep 1
  printf '\n## claude → cx: closed — confirmed — 2026-01-01T00:15Z\n\nBall: none\n' >> "$f"
  wake 'Ball: none did not wake cx' cx
  echo 'ok: Ball handoffs and closure wake once; irrelevant progress stays quiet; bad agent/file refused'
}

asks() {
  fixture
  start claude
  sleep 1
  printf '\n## claude → cx: own progress — 2026-01-01T00:05Z\n\nAsk: Claude, this is my own entry\nBall: cx\n' >> "$f"
  printf '\n## cx → claude: peer progress — 2026-01-01T00:10Z\n\nAsk: none\nBall: cx\n' >> "$f"
  quiet 'own entry or peer Ask: none'
  printf '\n## cx → claude: progress note — 2026-01-01T00:12Z\n\nAsk: none — Cx will return the PR and packet summary for review\nBall: cx\n' >> "$f"
  quiet 'peer Ask: none followed by a note'
  printf '\n## cx → claude: inspect — 2026-01-01T00:15Z\n\nAsk: Claude, inspect the contract\nBall: cx\n' >> "$f"
  wake 'Ask addressed to Claude with Ball: cx was missed' claude
  cursor=$(wc -l < "$f" | tr -d ' ')
  start claude
  printf '\n## claude → cx: own acknowledgement — 2026-01-01T00:20Z\n\nAsk: none\nBall: claude\n' >> "$f"
  printf '\n## claude → cx: own close — 2026-01-01T00:25Z\n\nAsk: none\nBall: none\n' >> "$f"
  quiet 'own Ball: claude or Ball: none'
  printf '\n## cx → claude: inspect again — 2026-01-01T00:30Z\n\nAsk: Inspect the next contract\nBall: cx\n' >> "$f"
  wake 'Ask addressed by entry header was missed' claude
  echo 'ok: peer Ask addressed to Claude wakes with Ball: cx; own entries and Ask: none stay quiet'
}

rearm() {
  fixture
  cp "$f" "$tmp/read-snapshot"
  cursor=$(wc -l < "$tmp/read-snapshot" | tr -d ' ')
  printf '\n## cx → claude: between read and rearm — 2026-01-01T00:05Z\n\nAsk: none\nBall: claude\n' >> "$f"
  start claude
  wake 'peer entry between last read and rearm was missed' claude
  fixture
  printf '\n## cx → claude: partially read entry — 2026-01-01T00:10Z\n\n' >> "$f"
  cp "$f" "$tmp/read-snapshot"
  cursor=$(wc -l < "$tmp/read-snapshot" | tr -d ' ')
  printf 'Ask: Claude, inspect after the header\nBall: cx\n' >> "$f"
  start claude
  wake 'Ask appended after a previously read entry header was missed' claude
  echo 'ok: peer entry appended after the handled snapshot wakes on rearm'
}

headings() {
  fixture
  start claude
  printf '\n## claude → cx: own review — 2026-01-01T00:05Z\n\n## Findings\n\nAsk: Claude, inspect my own note\nBall: none\n' >> "$f"
  quiet 'own entry with a body heading'
  printf '\n## cx → claude: peer review — 2026-01-01T00:10Z\n\n## Findings\n\nAsk: Claude, inspect the findings\nBall: cx\n' >> "$f"
  wake 'peer Ask after a body heading was missed' claude
  echo 'ok: body headings preserve peer Ask detection and own-entry suppression'
}

defaults() {
  # Three arguments: the interval is omitted and defaults inside the script,
  # so a cadence change needs no caller edit and survives a compacted session.
  fixture
  printf '\n## cx → claude: review — 2026-01-01T00:05Z\n\nBall: claude\n' >> "$f"
  launch claude "$f" "$cursor"
  wake 'three-argument form did not wake claude on its first scan' claude
  fixture
  refused claude "$f" -1
  refused claude "$f" invalid
  # Four arguments stay valid: a running caller that passes an interval is unchanged.
  printf '\n## cx → claude: review — 2026-01-01T00:10Z\n\nBall: claude\n' >> "$f"
  start claude
  wake 'four-argument form stopped waking claude' claude
  echo 'ok: omitted interval defaults; explicit interval still accepted; bad cursor refused'
}

output() {
  fixture
  printf '\n## cx → claude: review — 2026-01-01T00:05Z\n\nBall: claude\n' >> "$f"
  start claude
  wake 'initial watcher did not produce its receipt' claude

  # Keep the next child from truncating out until we inspect the launch result.
  # Without parent-side preparation, wake could mistake the old receipt for
  # this child, then fail when the child truncates it between the two checks.
  launch_gate="$tmp/launch-gate"
  mkfifo "$launch_gate"
  launch claude "$f" "$cursor"
  stale=0
  if [ -s "$tmp/out" ]; then
    stale=1
  fi
  printf 'go\n' > "$launch_gate"
  unset launch_gate
  if [ "$stale" -ne 0 ]; then
    echo 'FAIL: previous watcher output remained visible during the next launch'
    exit 1
  fi
  wake 'next watcher did not replace the previous receipt' claude
  echo 'ok: consecutive launches clear old output before the next child starts'
}

wrapper() {
  # bin/clodball-watch is the compatibility path saved project wrappers call;
  # it forwards every argument and the exit status to the packaged script.
  fixture
  bin="$here/../bin/clodball-watch"
  if "$bin" nobody "$f" "$cursor" 2>/dev/null; then
    echo 'FAIL: wrapper accepted invalid arguments'
    exit 1
  else
    result=$?
  fi
  if [ "$result" -ne 2 ]; then
    echo "FAIL: wrapper exited $result instead of forwarding 2"
    exit 1
  fi
  printf '\n## cx → claude: review — 2026-01-01T00:05Z\n\nBall: claude\n' >> "$f"
  : > "$tmp/out"
  "$bin" claude "$f" "$cursor" > "$tmp/out" &
  pid=$!
  wake 'bin/clodball-watch did not forward to the packaged watcher' claude
  echo 'ok: bin/clodball-watch forwards arguments and exit status to skills/clodBall/scripts/clodball-watch'
}

case "${1:-all}" in
  baseline) baseline ;;
  asks) asks ;;
  rearm) rearm ;;
  headings) headings ;;
  defaults) defaults ;;
  output) output ;;
  wrapper) wrapper ;;
  all) baseline; asks; rearm; headings; defaults; output; wrapper ;;
  *) echo "FAIL: unknown test: $1"; exit 1 ;;
esac
