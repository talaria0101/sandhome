---
name: errandsh
description: Drive an interactive shell over a pty-less SSH session with errandsh - echo, line editing, history, tab completion, Ctrl-R and full-screen programs through a userspace pty, where there is no /dev/ptmx. Use when a remote shell has no echo or line editing, when ssh -t degrades to a dumb pipe, or when a full-screen program (nano, less, top) must run without a kernel pty.
---

# errandsh

`errandsh` is a line discipline for a session that has no pty. A sealed cage has
no `/dev/ptmx` and no devpts, so a remote shell arrives with no echo, no line
editing and no signals. `errandsh` provides those in POSIX `sh`.

## Run it

```sh
sandhome shell                 # interactive
sandhome shell -c 'make test'  # exec channel, no line discipline
sandhome pty top               # one command under the userspace pty
sh shell/errandsh              # from the checkout
```

`sandhome shell` runs the copy on the exec root when a bootstrap placed one
there, and the checkout's copy otherwise, so it works from any shell that has
read `$SANDHOME_HOME/env.sh`.

As a remote login shell, set it on the server side and connect with plain
`ssh`. The transport is whatever the operator already has: this repository
carries the line discipline, not a client, and a transport where both peers
dial out is the one that works in a cage that cannot `bind(2)`.

## Environment

| variable | meaning | default |
| --- | --- | --- |
| `ERRANDSH_NAME` | the name in the prompt | the hostname up to its first dot, cut to 24 characters |
| `ERRANDSH_HISTORY` | the history file | `$HOME/.errandsh-history` |
| `ERRANDSH_SHELL` | the shell commands run in | `/bin/sh` |
| `ERRANDSH_MAXHIST` | history lines kept in the session | 500 |
| `ERRANDSH_PTY` | `0` stops full-screen programs being auto-run in the foreground | `1` |
| `ERRANDSH_PTY_PROGRAMS` | the programs auto-run in the foreground | `vi vim nvim nano emacs emacsclient pico less more pg top htop btop watch screen tmux mc joe micro mutt` |
| `NO_COLOR` | set to anything to drop colour | unset |

## What it does and does not do

It gives echo, a prompt carrying the last exit code, history with Up/Down,
Left/Right/Home/End/Delete, `Ctrl-A E B F K U W`, `Ctrl-R` reverse search, tab
completion, and bracketed paste.

It also runs full-screen programs (`nano`, `less`, `top`, `htop`, `vi`, ...).
The cage has no `/dev/ptmx`, so there is no kernel pty to allocate;
`shims/fakepty.c` is a userspace pty, preloaded by `shell/faketty`, and a
program on the list is run in the foreground on the session's descriptors. `pty
CMD` forces it for anything else, `ERRANDSH_PTY=0` turns the automatic part off,
and because the interposer is exported and `exec`'d a subshell the program
starts keeps the terminal.

The one thing it cannot reach is a STATICALLY LINKED full-screen program:
`LD_PRELOAD` has nothing to interpose into. While a command runs the session is
not reading keys, so `Ctrl-C` is delivered by the operator's own client and
type-ahead is read after the command finishes.

## Test it

```sh
bash tests/errandsh-posix.sh
```

The test drives it over pipes, not a pty, under every shell the host has, and
asserts the recalled text and the cursor-walk escape, because a cursor movement
on a short line looks like no movement at all. It also drives a full-screen
fixture through the userspace pty (`isatty`, a termios, a window size, the
alternate screen and a keypress) and asserts an inner pipe stays a pipe. It
prints `N shell(s) passed, 0 failed` and exits non-zero on any clause that did
not hold. `sh tests/run.sh` includes it.

## The related shims

When a program other than an interactive shell needs to believe a pipe is a
terminal, `fakepty.so` is the `LD_PRELOAD` interposer:

```sh
sandhome shims                              # build what this machine needs
SANDHOME_SHIMS=1 . "$SANDHOME_HOME/env.sh"  # load them, for this shell
```

**It is off by default and must stay off**, because it makes every
terminal-aware program colourise a pipe, and that breaks `jq -r`, `git` and
`ls --color=auto`. Neither shim can reach a static binary. The same contract is
in `sandhome help`; the long form is `docs/architecture.md` section 6 with
`skills/sealed-sandbox/SKILL.md`.
