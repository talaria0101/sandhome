# ROUTE.md

**One paste, any sandbox.** Nothing to clone, nothing to fill in, no prompt
to pick. You are reading this because somebody pasted its URL into a session
and asked you to set up first and work second.

**This file is self-contained.** Fetch the rest only once you know which row
you are on.

Everything below is fetched from, and run against, this base:

```text
https://raw.githubusercontent.com/talaria0101/sandhome/main
```

The human paste that points here reads like this:

```text
Setup your env as per https://raw.githubusercontent.com/talaria0101/sandhome/main/ROUTE.md and then <the task>.
```

When you receive that, it means: follow this file through setup, confirm
the check at the end of step 2 exits 0, then do the task without reporting
back on setup at all.

---

## Before you copy any command

The bootstrap names its own downloader when one is chosen, so you do not
have to. A machine with none of curl, wget or fetch says so in one sentence
and names the install command. A scratch directory is whatever this host
actually has:

```sh
printf 'scratch: %s\n' "${TMPDIR:-/tmp}"
```

If this host has no POSIX shell at all, stop and say so. The whole tree is
POSIX sh and there is no other spelling of it.

---

## Two rules before you do anything

**1. When the check exits 0, the sandbox is ready. Start the task.**

Do not end your turn to report that setup worked. Do not ask about setup.
If the check fails, report its exact lines and hold. A finished turn is a
session the operator has to restart.

**2. Read only what the row names.**

This file routes. It restates nothing, so it cannot fork from the document
it points at. The link is the authority. Pages written for maintainers
(`AGENTS.md`, `docs/architecture.md`, `docs/decisions/`) are not for this
session. If the task is to change this repository itself, stop here and read
`AGENTS.md` instead.

---

## Step 1. Look at the machine. Do not ask yet.

```sh
command -v sandhome
[ -r "$HOME/.local/share/sandhome/env.sh" ] && echo env.sh present || echo env.sh absent
```

```sh
if command -v sandhome >/dev/null 2>&1; then sandhome doctor; sandhome space --probe; fi
```

That answers most of it. The second block runs only when `sandhome` exists;
on a fresh sandbox it prints nothing and that is the answer: go to step 2.

| what you see | the state is |
| --- | --- |
| no `sandhome` on PATH and no `env.sh` under the data root | fresh sandbox, go to step 2 |
| the checkout is here (`bootstrap.sh` and `bin/sandhome` beside you) and the task changes this repository | maintainer session, read `AGENTS.md` and put this file away |
| `env.sh` exists and the exec bin is gone (tmpfs restart cleared it) | stale exec root, go to step 2 and re-run the setup; then find the symptom in step 3 |
| the check fails | find the symptom in step 3 and follow that row |

Do not infer a capability from a package list or a mount option. A mount
can be writable, show no refusal flag anywhere, and still refuse to run a
file. The probe above runs a real file for exactly this reason.

---

## Step 2. Set up, in three commands. Source nothing.

The first command runs whatever is on `main` at the moment it is fetched, and
it fetches a second copy of `main` to use as the library. Nothing is pinned by
default. To pin a ref, export `SANDHOME_REF=<tag-or-sha>` before the pipe, or set
it on the `sh` side of the pipe as above: a `VAR=value curl` assignment applies
to `curl` only and the piped `sh` never sees it, so nothing is pinned (issue
#64). To
pin the bytes, set `SANDHOME_SHA256` (or `SANDHOME_SHA256_<NAME>` per toolchain,
`SANDHOME_SHA256_<ASSET>` per URL asset); see `bootstrap.sh --help` and
docs/decisions/pinning.md (pinning semantics). Neither is set by default, and this is the default.

```sh
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/<ref>/bootstrap.sh \
  | SANDHOME_REF=<tag-or-sha> SANDHOME_SHA256=<digest> sh -s -- --toolset developer
```

From nothing but a network (unpinned default):

```sh
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/bootstrap.sh | sh -s -- --toolset developer
```

That is the whole setup. The bootstrap installs a **global hook** into every
`PATH` directory that is writable and runs binaries, so the next command starts
a fresh shell and `sandhome` is simply there. You do not
source `env.sh`, and you do not put anything in front of each command.

```sh
sandhome doctor
```

`doctor` ends in `doctor_failures=N` and exits non-zero when N is not zero. It
checks the toolchains the setup ASKED FOR, not merely the ones it managed: the
requested list is recorded in `env.sh` as `SANDHOME_WANTED_TOOLCHAINS`, so a
`--toolset languages` run that could not install `zig`, `mold` or `rust` is
reported as six named failures rather than a green gate. Treat a non-zero exit
as the task not being ready. `sandhome status` (and `status --json`) answers
the same readiness in one line -- roots, view, toolchains present, next
command -- and is what a harness calls first.

```sh
sandhome toolchains
```

From a clone, the first command is instead:

```sh
sh bootstrap.sh --toolset developer
```

If `sandhome` is not found after that, the host has no writable exec-capable
directory on `PATH` (the bootstrap says so in one sentence and prints
`global=none` in its report). Then the stable way in is the entry point beside
the home, which needs no `PATH` and no login shell, and which you source in the
shell you are using:

```sh
. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh"
```

When the check at the end of this step exits 0, the sandbox is ready: do the
task.

The run detects the machine, plans the two roots, adopts each toolchain
that already answers and installs the ones that do not, builds the shims
this machine actually needs, writes `env.sh`, installs the global hook, and
prints a report read from the machine. `doctor` exits 0 only when every
invariant holds. `toolchains` names what is here and how each tool reaches
PATH.

**`exec_free_mb` is a decision, not trivia.** The exec root is where every
build artifact has to land, because the home often refuses `execve`. A few
hundred megabytes is a hello-world; a multi-target Rust or Go build is not. The
run picks the *roomiest* exec-capable path it finds and prints how much that
was. If it is small, or if a build later fails with ENOSPC or "not writable or
does not allow exec", re-run the first command with `--exec DIR` naming a roomy
exec-capable path. `sandhome space --probe` lists every candidate with its free
space.

Toolsets: `minimal` (jq), `cli` (plus ripgrep and fd), `developer` (plus
python and node, the default); `languages` is the full compiler set
(`developer` plus `rust go zig deno bun mold clang cmake meson ninja pkgconf
perl`, and clang alone is a >1GB download); `project` is `developer` plus
`go rust clang cmake meson ninja mold pkgconf perl`; `agent` is `developer`
plus the runtimes and CLIs an agent uses at work (`deno bun yq gh shellcheck
shfmt qemuuser mold ninja pkgconf perl`) and carries no compiler chain
(work-tree detection can still fold one in; `--no-detect` turns it off). Add one
with `--with rust`, drop one with `--without node`. Both flags
repeat and both take a comma list. Ask for exactly a list, with no preset and
no auto-detection, with `--only rust` (space or comma separated: `--only jq
ripgrep`); it is the same request as `--toolset none --with rust`. An explicit
request never auto-detects project markers; `--detect` opts back in. Exit
`0` done, `1` something asked for
could not be done, `2` could not run at all. Every flag, variable and
command is specified in `docs/reference.md`, which is generated from the
code, so it overrules any other page that disagrees with it.

### The skills, where the harness finds them.

**The setup already installed them.** The command above copies all three into
`$HOME/.agents/skills/` and, when Pi state exists, `$HOME/.pi/agent/skills/` -
the two places a harness scans. So there is nothing to fetch here, and one
command confirms it:

```sh
sandhome skills
```

It prints one line per skill per location with where the bytes came from (this
tree's copy, a link into a clone's checkout, or a file that differs from it),
ends in `skills_installed=N`, and exits non-zero when none is installed. A
harness with a resource reload (Pi: `/reload`) picks up new or changed skills
without a restart; a harness that scans skills at startup picks them up in the
next session. Read the three in this session.

Only if the setup was run with `--no-skills`, or you want a clone's skills
linked by name rather than copied so later pulls update them, do it by hand.
Without a clone, fetch each one by URL:

```sh
mkdir -p "$HOME/.agents/skills/sandhome" "$HOME/.agents/skills/errandsh" "$HOME/.agents/skills/sealed-sandbox"
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/skills/sandhome/SKILL.md -o "$HOME/.agents/skills/sandhome/SKILL.md"
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/skills/errandsh/SKILL.md -o "$HOME/.agents/skills/errandsh/SKILL.md"
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/skills/sealed-sandbox/SKILL.md -o "$HOME/.agents/skills/sealed-sandbox/SKILL.md"
```

From a clone, link each skill by name instead of copying, so later pulls update them:

```sh
for s in sandhome errandsh sealed-sandbox; do ln -s "$PWD/skills/$s" "$HOME/.agents/skills/$s"; done
```

---

## Step 3. One table. The symptom decides the row.

More than one row can apply and then both are read.

| the symptom or the ask | read, in full |
| --- | --- |
| install or adopt another toolchain later, or list what is here and how it reaches PATH | `skills/sandhome/SKILL.md` |
| a tool installed and is not found, or a binary answers Permission denied | `skills/sandhome/SKILL.md` diagnose part, then `docs/guide.md` section 7 |
| a Go program compiles and then fails to run with a permission error | `docs/guide.md` section 4 |
| the current directory is on a noexec mount and build output will not run there | build under `$(sandhome exec-dir)` (see step 4); `sandhome doctor` names this state |
| a remote shell has no echo, no line editing, no signals | `skills/errandsh/SKILL.md` |
| an ssh login is refused, a program needs a passwd entry or a terminal, bind is denied, there is no pty | `skills/sealed-sandbox/SKILL.md` |
| a local dev server, `npm run dev`, or any process that listens | nothing can listen here; see `skills/sealed-sandbox/SKILL.md` no-listen row: dial out to a relay or emit static output |
| the exec root is full | `docs/guide.md` section 7, which carries the `gc` row. `gc 0` (or `gc --now`) reclaims same-day caches; views are never reclaimed, `repair` rebuilds them |
| `doctor` reports `FAIL exec_space=low` or `=critical` | the exec root is draining and the next build will fail with `no space left on device`. `sandhome space` names the state and the numbers, `sandhome space --probe` lists roomier candidates, `sandhome gc` reclaims sandhome's own caches, and re-running the first command with `--exec DIR` moves everything |
| `doctor` reports `FAIL exec_link_<tool>=broken` | a link in the exec view is not executable, or points at itself; `sandhome repair <tool>` rebuilds it and downloads nothing. A tool that was adopted rather than installed is the usual cause, and `install` is the command that adopts, so it is not the one to reach for first |
| a tool is on PATH but a shell that inherited nothing cannot find it | it was adopted and could not be linked into the exec view; `sandhome repair <tool>` retries the link and `sandhome install --force <tool>` puts a copy there |
| a non-interactive login shell (`bash -lc`, `sh -l -c`) answers `cannot map this copy back to its payload` for node, jq, cargo or another launcher copy, while `sandhome doctor` is green | that shell resolved the exec bin before the environment was loaded. The profile fragment now loads `env.sh` for every login shell, so re-run the setup once to rewrite it; `. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh"` is the immediate way in, and the same shell is fine once the fragment is in place |
| a headless browser, Playwright, Puppeteer, webpack, vite, jest or any other worker dies with `spawn /memfd:sandhome (deleted) ENOENT` | the runtime ran from an anonymous memfd, so `process.execPath` is a path that no longer exists. node, deno and bun are real copies in the view now; `sandhome doctor` fails with `toolchain_node_spawn` when it is not, and `sandhome report` names the per-toolchain view. `sandhome install --force node` rebuilds it, and `SANDHOME_VIEW_MODE=copy` is the whole-tree answer |
| `sandhome global --status` shows `state=stale`, or a fresh shell does not find `sandhome` | a recorded hook directory no longer answers a fresh shell; `sandhome global` repairs every recorded directory. When the report says `global=none` the host had no usable directory, and the entry point beside the home is the way in: `. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh"` |
| `doctor` reports a `FAIL <VAR>=unset` for `GOBIN`, `GOCACHE`, `CARGO_INSTALL_ROOT` or `NPM_CONFIG_PREFIX` | that toolchain was adopted, so its fragment did not carry the exec-root paths; `sandhome install --force <tool>` writes a fragment that does |
| the exec root was cleared by a restart (tmpfs) and `sandhome` is gone | run `sandhome resume`: it re-plans the roots, rebuilds every recorded view without fetching, then runs `doctor` and exits with its code. Only when `env.sh` itself is gone, re-run step 2 instead |
| `env -i $SANDHOME_EXEC/bin/sandhome doctor` answers `cannot find the sandhome library` | the bake and the `.sandhome-home` pointer both point at a checkout or a home that is gone. The installed copy keeps its own copy of the library in `$SANDHOME_EXEC/.sandhome-lib`, so re-run the setup (or `sandhome repair`) once to write it; after that the command works with no HOME, no PATH and no environment |
| the detected exec root is too small to hold the toolset, or the setup names `--exec` with no roomier candidate to point at | `sandhome space --probe` lists every candidate with free space; `sandhome space` names the ceiling (`max_exec_free_mb`, `exec_ceiling`). The plan picks the roomiest working candidate, and the choice is then stable; `--exec DIR` moves it deliberately. A small ceiling restricts the *view*, not the toolchain: payloads live on the home, so installs that fit proceed and ones that cannot name their measured need against the measured free space. `gc` reclaims caches only, not views (`docs/guide.md` sections 1 and 7) |
| the session died with a scratch-quota kill (tmpSize, shmSize, fileMax, diskTmp) while `doctor` was green | quota kills bypass the df-based space gate: `doctor`, `space` and `report` read `df`, and no quota signal is readable from inside, so nothing warns first. `docs/guide.md` section 7 names what counts against scratch and what `gc` reclaims |
| a CLI installed after the setup (`npm install -g`, `uv tool install`, `go install`, `cargo install`) is not found by a shell that sourced nothing | run the installer through the hook, which is what a fresh shell does when it names the tool: the dispatcher runs the installer as a child and links every new executable into the hook on return, so the next fresh shell finds it with no manual step. A CLI installed from a sourced shell (where the exec bin shadows the hook) or copied in by other means still needs one `sandhome global`. `sandhome exec --shell 'npm install -g <pkg>'` always works, because that is the one form that applies the environment |
| the exact spelling of a flag, a variable or a command | `docs/reference.md` and nothing else; without a clone use `sandhome help` and `sandhome <cmd> --help` (per-command help, and `sandhome help <cmd>`) |
| change this repository: a lib file, a toolchain, a shim, the line discipline | `AGENTS.md`, which is the maintainer router |

A row you cannot match is not a row that does not exist. Say what the
symptom was, name the closest two rows, and read both. Do not invent a
procedure because the table did not name one.

---

## Step 4. Whatever the row said, these hold

A toolchain already on PATH is adopted, not downloaded. The report says
which. Adoption is the common case on a long lived base.

The shims are built by default and loaded only when asked. The bootstrap builds
what this machine needs; nothing is active until `SANDHOME_SHIMS` is set to 1
for one shell. The default stays off for a measured reason: the terminal
interposer makes every terminal aware program colourise a pipe, which breaks
clean output from tools like jq and git.

Build output must land where it can run. The working tree is often the noexec
home itself, so `go build -o hello`, `cargo build`, `cc -o`, `make`, downloaded
runtimes, and `npm i -g` output placed on the home fail with Permission denied
or bad interpreter. Tool output that must execute lives on the exec root (`go
build`'s default output, cargo's `target/`, a downloaded runtime): `GOBIN`,
`NPM_CONFIG_PREFIX`, `GOCACHE`, `CARGO_INSTALL_ROOT`, and `CARGO_TARGET_DIR`
(a per-project dir under the exec root when unset) already point there;
for anything else build there or copy the artifact before running it. **The
global hook does not export `SANDHOME_EXEC` into the shell** -- the hook applies
`env.sh` to the process of the tool it dispatches, and a child cannot change its
parent -- so in the fresh shell this file produces, name the root with a
command, not a variable: `cd "$(sandhome exec-dir)"` for a build tree, or run
the whole line through `sandhome exec --shell 'make -j4 && ./run'`, which applies
the entire environment including `SANDHOME_EXEC` and `TMPDIR`. No wrapper or
launcher lives in the work tree.

The environment file is the single source of truth, and the bootstrap installs
a **global hook** so no shell has to read it by hand: every directory already
on this shell's `PATH` that is writable and runs binaries gets a dispatcher
which loads `env.sh` and execs the real tool, so any one of them is enough.
On a host whose home refuses `execve` the hook directory is a symlink into the
exec root, which runs, so the noexec mount is not a wall. `sandhome report`
prints `global=on:<dir>` when a recorded directory answers a fresh `env -i`
shell, `global=stale:<dir>` when one was recorded and no longer does,
`global=inside-exec-root:<dir>` when the hook was written into a directory
this tree uses as indirection (an exec-root view bin or the exec `bin`,
which `doctor` fails; repair with `sandhome global --remove`, then
`sandhome global`), and
`global=none` when the host had no writable candidate; `sandhome global
--status` names every directory and its state, and `sandhome global` repairs
them. `sandhome global --remove` puts each entry back the way install found it.

Sourcing is therefore the **fallback**, not the setup step. The two forms below
are for a host that printed `global=none`, and for a shell that wants the
environment before it runs a command. In a shell that sources files, source the
entry point. Where sourcing is not possible, load it through eval, which
survives `sh -c`, but the eval needs `sandhome` already on PATH and fails
silently with rc=0 when it is not: the entry point is the cold-shell path, the
eval is the warm-shell shortcut.

```sh
eval "$(sandhome env)"
```

```sh
sh -c 'eval "$(sandhome env)"; sandhome doctor'
```

**A shell with no PATH at all sources the entry point by its durable path.** The
`eval` forms above need `sandhome` already on PATH, and a host that printed
`global=none` has no PATH entry for it. The bootstrap leaves a snippet beside
the durable home for exactly that case:

```sh
. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh"
sandhome doctor
```

It is sourced, not executed, because the home is often noexec and a file there
cannot run; sourcing needs no exec permission. It sets `SANDHOME_HOME` and
`SANDHOME_EXEC`, defines `sandhome` with three fallbacks (the baked exec bin,
then `$SANDHOME_EXEC/bin/sandhome`, then PATH) so a snippet read before
`sandhome resume` rewrites it still finds a moved view, and sources `env.sh`,
so one line from `sh -c`, a harness tool call, or any process that inherited
nothing reaches both the command and the toolchains. The snippet lives on the
home, so a tmpfs restart does not clear it; `sandhome resume` rewrites it when
it moves the exec view. `sandhome report` names whether this shell is a login
shell, whether the exec bin is on PATH now, and the entry path it baked.

```sh
sandhome exec --shell 'make -j4 && ./run'
```

takes argv by default and a shell string when asked: one argument that is not
a program already runs through the shell, and `--shell` names that form
explicitly. A path with a slash is always argv. It applies the same
environment a sourced shell gets, `TMPDIR` and `XDG_RUNTIME_DIR` included, so
`sandhome exec python3 script.py` needs no `export TMPDIR=$SANDHOME_EXEC/tmp`
in front of it.

A toolchain that installed without an error and still does not answer is
reported as a failure. Run the `install` subcommand for that name again:
it rebuilds the exec view and probes the tool afterwards, on the adopt
path as well as the install path.

---

## Step 5. Before acting on required reading, print the receipt

Whichever row you took names files to read in full. For each one report
its line count and the heading of its last section. Without a clone the docs
live under the durable repo (`$SANDHOME_HOME/repo/docs/`) after setup, and the
same content is available from `sandhome help`:

```sh
wc -l "$SANDHOME_HOME/repo/docs/guide.md" && grep '^#' "$SANDHOME_HOME/repo/docs/guide.md" | tail -1
```

A line count alone is available from a listing. The last heading is not.
Reaching it means reaching the end of the file, which is the part a skim
drops. A receipt for a file you did not read is a fabricated measurement,
which is worse than saying you skipped it.

---

## What this file is not

Not a substitute for the file it routes you to. Reading this row is not
reading that document.

Not a procedure. It ends the moment setup checks out or the symptom finds
its row.

Not permission to change this repository. Rows that touch the tree stop
for the maintainer router first.

Not a list of everything this repository can do. The generated reference
is the full map of commands, and a session whose symptom matches no row
should say so rather than improvise.
