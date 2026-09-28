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

## Step 2. Set up, in four commands.

The first command runs whatever is on `main` at the moment it is fetched, and
it fetches a second copy of `main` to use as the library. Nothing is pinned by
default. To pin a ref, put `SANDHOME_REF=<tag-or-sha>` in the environment. To
pin the bytes, set `SANDHOME_SHA256` (or `SANDHOME_SHA256_<NAME>` per toolchain,
`SANDHOME_SHA256_<ASSET>` per URL asset); see `bootstrap.sh --help` and
docs/decisions/pinning.md (pinning semantics). Neither is set by default, and this is the default.

```sh
SANDHOME_REF=<tag-or-sha> SANDHOME_SHA256=<digest> \
  curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/<ref>/bootstrap.sh | sh -s -- --toolset developer
```

From nothing but a network (unpinned default):

```sh
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/bootstrap.sh | sh -s -- --toolset developer
```

```sh
. "$HOME/.local/share/sandhome/env.sh"
```

```sh
sandhome doctor
```

`doctor` ends in `doctor_failures=N` and exits non-zero when N is not zero. It
checks the toolchains the setup ASKED FOR, not merely the ones it managed: the
requested list is recorded in `env.sh` as `SANDHOME_WANTED_TOOLCHAINS`, so a
`--toolset languages` run that could not install `zig`, `mold` or `rust` is
reported as six named failures rather than a green gate. Treat a non-zero exit
as the task not being ready.

```sh
sandhome toolchains
```

From a clone, the first command is instead:

```sh
sh bootstrap.sh --toolset developer
```

When the check at the end of this step exits 0, the sandbox is ready: do the
task.

The run detects the machine, plans the two roots, adopts each toolchain
that already answers and installs the ones that do not, builds the shims
this machine actually needs, writes `env.sh`, and prints a report read from
the machine. The third command exits 0 only when every invariant holds.
The fourth names what is here and how each tool reaches PATH.

**`exec_free_mb` is a decision, not trivia.** The exec root is where every
build artifact has to land, because the home often refuses `execve`. A few
hundred megabytes is a hello-world; a multi-target Rust or Go build is not. The
run picks the *roomiest* exec-capable path it finds and prints how much that
was. If it is small, or if a build later fails with ENOSPC or "not writable or
does not allow exec", re-run the first command with `--exec DIR` naming a roomy
exec-capable path. `sandhome space --probe` lists every candidate with its free
space.

Toolsets: `minimal` (jq), `cli` (plus ripgrep and fd), `developer` (plus
python and node, the default), `languages` and `agent` (both plus rust and
go). Add one with `--with rust`, drop one with `--without node`. Both flags
repeat and both take a comma list. Exit `0` done, `1` something asked for
could not be done, `2` could not run at all. Every flag, variable and
command is specified in `docs/reference.md`, which is generated from the
code, so it overrules any other page that disagrees with it.

### The skills, where the harness finds them.

A harness discovers skills from `~/.agents/skills/` (Pi also reads
`~/.pi/agent/skills/`). Without a clone, fetch each one by URL:

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

Confirm all three landed, then read them in this session. A new session picks
them up on start, and a harness with a resource reload (Pi: `/reload`) picks up
new or changed skills without one. A harness that scans skills at startup picks
them up in the next session; if yours supports a resource reload, use it rather
than restarting.

```sh
ls "$HOME/.agents/skills/sandhome/SKILL.md" "$HOME/.agents/skills/errandsh/SKILL.md" "$HOME/.agents/skills/sealed-sandbox/SKILL.md"
```

---

## Step 3. One table. The symptom decides the row.

More than one row can apply and then both are read.

| the symptom or the ask | read, in full |
| --- | --- |
| install or adopt another toolchain later, or list what is here and how it reaches PATH | `skills/sandhome/SKILL.md` |
| a tool installed and is not found, or a binary answers Permission denied | `skills/sandhome/SKILL.md` diagnose part, then `docs/guide.md` section 7 |
| a Go program compiles and then fails to run with a permission error | `docs/guide.md` section 4 |
| the current directory is on a noexec mount and build output will not run there | build under `$SANDHOME_EXEC` (see step 4); `sandhome doctor` names this state |
| a remote shell has no echo, no line editing, no signals | `skills/errandsh/SKILL.md` |
| an ssh login is refused, a program needs a passwd entry or a terminal, bind is denied, there is no pty | `skills/sealed-sandbox/SKILL.md` |
| a local dev server, `npm run dev`, or any process that listens | nothing can listen here; see `skills/sealed-sandbox/SKILL.md` no-listen row: dial out to a relay or emit static output |
| the exec root is full | `docs/guide.md` section 7, which carries the `gc` row |
| `doctor` reports `FAIL exec_space=low` or `=critical` | the exec root is draining and the next build will fail with `no space left on device`. `sandhome space` names the state and the numbers, `sandhome space --probe` lists roomier candidates, `sandhome gc` reclaims sandhome's own caches, and re-running the first command with `--exec DIR` moves everything |
| `doctor` reports `FAIL exec_link_<tool>=broken` | a link in the exec view is not executable, or points at itself; `sandhome repair <tool>` rebuilds it and downloads nothing. A tool that was adopted rather than installed is the usual cause, and `install` is the command that adopts, so it is not the one to reach for first |
| a tool is on PATH but a shell that inherited nothing cannot find it | it was adopted and could not be linked into the exec view; `sandhome repair <tool>` retries the link and `sandhome install --force <tool>` puts a copy there |
| `doctor` reports a `FAIL <VAR>=unset` for `GOBIN`, `GOCACHE`, `CARGO_INSTALL_ROOT` or `NPM_CONFIG_PREFIX` | that toolchain was adopted, so its fragment did not carry the exec-root paths; `sandhome install --force <tool>` writes a fragment that does |
| the exec root was cleared by a restart (tmpfs) and `sandhome` is gone | re-run step 2, then `sandhome repair` to rebuild the exec view and the launchers |
| the exact spelling of a flag, a variable or a command | `docs/reference.md` and nothing else; without a clone use `sandhome help` and `sandhome <cmd> --help` |
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
or bad interpreter. Tool output that must execute lives on `$SANDHOME_EXEC`:
`GOBIN`, `NPM_CONFIG_PREFIX`, `GOCACHE`, and `CARGO_INSTALL_ROOT` already point
there; for anything else build under `$SANDHOME_EXEC` or copy the artifact
there before running it. No wrapper or launcher lives in the work tree.

The environment file is the single source of truth, and sourcing it is a per-session cost, not a setup step. Every new shell, including every non-login tool shell, must load it again before `sandhome` or any toolchain is on PATH. In a shell that sources files, source it. Where sourcing is not possible, load it through eval, which survives `sh -c`:

```sh
eval "$(sandhome env)"
```

```sh
sh -c 'eval "$(sandhome env)"; sandhome doctor'
```

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
