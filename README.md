# clodBall

> **Purpose:** what clodBall is, how to install it, and how to use it. **Use:** read first; update when the install or the invocation changes.

clodBall is a handoff routine for two coding agents, Claude Code and
Codex, working one project together. It is one append-only file per
project, one skill both agents read, and one small watcher script that
wakes an agent when the other hands it the ball. The ball is the `Ball:`
line every entry carries. Nothing here is a lock, a queue, or an
authority: a peer's entry is a peer's judgment, and the user's word
still arrives through the user.

## Install

The skill is the directory [skills/clodBall](skills/clodBall): a
`SKILL.md` and the watcher at `scripts/clodball-watch`. Put that
directory, or a symlink to it, where your agents discover skills:

- Claude Code: `~/.claude/skills/clodBall`
- Codex: `~/.agents/skills/clodBall`

One symlink into this checkout serves both hosts when they share a
skills directory. The skill calls the watcher relative to its own
directory, so it works wherever it is installed. `bin/clodball-watch`
in this repo forwards to the same script for callers that use that path.

The handoff file is never committed. Add `.review/HANDOFF.md` to the
repo's `.gitignore`, or `**/.review/HANDOFF.md` to your global git
ignore file. The skill proves the ignore with `git check-ignore` before
it writes.

`VERSION` holds the release version; each release is also a tag `v<VERSION>`.

## Use

- Claude, in the project's session: `/clodBall` runs one check and
  arms the watcher in the background; `/clodBall stop` stops it.
  That is the whole invocation. `/loop 3m /clodBall` is the fallback
  when the watcher cannot run, and it costs a model turn per tick.
- Codex: `$clodBall` starts its checker, `$clodBall check` runs
  one check, `$clodBall stop` stops it.
- The watcher by hand:

```sh
skills/clodBall/scripts/clodball-watch claude /path/to/repo/.review/HANDOFF.md "$last_read_line"
```

First read a scratch snapshot of the handoff file. Set `last_read_line`
to that snapshot's complete line count, then pass it to the watcher after
handling the snapshot. Do not count the live file when re-arming: an entry
may have arrived since the read. The poll interval defaults to 30 seconds
inside the script; an explicit interval before the cursor is still
accepted, but new launches omit it so a cadence change lands in one
place. The skill gives the full procedure.

The watcher prints one line and exits for an unread peer `Ball: claude`,
`Ball: none`, or Ask addressed to Claude, even with `Ball: cx`.
Own entries and `Ask: none` progress with the ball elsewhere stay quiet,
including `Ask: none — <note>`: a note after `none` is still none.
Exit 2 means invalid arguments or an unreadable file.

## Check

```sh
shellcheck -s sh skills/clodBall/scripts/clodball-watch bin/clodball-watch tests/test-watch.sh
sh tests/test-watch.sh
```

The tests exercise the script directly: quiet progress and own entries,
ball transfers and closure, an Ask with the ball elsewhere, an entry
that arrives between the saved read and re-arming, the omitted
interval alongside the older four-argument form, and the `bin/`
forwarding path. A controlled startup check prevents a previous receipt
from satisfying the next launch's wait.

## Where the rest lives

The skill text, with the entry format, the kickoff, the check, and the
close, is [skills/clodBall/SKILL.md](skills/clodBall/SKILL.md). It is
the whole protocol; this README is only the install page.
