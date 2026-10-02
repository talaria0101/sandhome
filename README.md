# sandhome

A portable home for agents that run inside a sealed sandbox: one bootstrap, one
environment, POSIX `sh` throughout.

## Paste this to any agent, then give it your task

> Setup your env as per
> https://raw.githubusercontent.com/talaria0101/sandhome/main/ROUTE.md
> and then <the task>.

That one instruction is the whole contract: [`ROUTE.md`](ROUTE.md) sets up
the sandbox, confirms `sandhome doctor` exits 0, and routes any failure to
the one page that answers it. So the agent stops setting up and starts
working without asking you anything.

**An agent setting up a sandbox should read [`ROUTE.md`](ROUTE.md) and
nothing else.** Harnesses that discover skills from a `skills/` directory
use [`skills/sandhome/SKILL.md`](skills/sandhome/SKILL.md) instead, which
carries the same fast path. An agent working on this repository should read
[`AGENTS.md`](AGENTS.md), which routes to the rest.

## Start working

```sh
sh bootstrap.sh --toolset developer        # from a clone
#   or, with nothing but a network:
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/bootstrap.sh \
  | sh -s -- --toolset developer

sandhome doctor                            # exits 0 when every invariant holds
```

The bootstrap installs a **global hook** into every `PATH` directory that is
writable and runs binaries, so a fresh shell knows `sandhome` and the toolchains
with nothing sourced in front of a command. If the host has no writable,
exec-capable `PATH` directory, the
report says `global=none`; then source the entry point beside the home, once per
shell: `. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh"`.

Toolsets: `minimal` (jq), `cli` (+ ripgrep, fd), `developer` (+ python, node,
the default); `languages` is the full compiler set (`developer` plus
`rust go zig deno bun mold clang cmake meson ninja pkgconf perl`; clang alone is
a >1GB download); `project` is `developer` plus `go rust clang cmake meson ninja
mold pkgconf perl`; `agent` is `developer` plus the runtimes and CLIs an agent
uses at work (`deno bun yq gh shellcheck shfmt qemuuser mold ninja pkgconf perl`)
and carries no compiler chain; work-tree detection can still fold one in for a
C/C++ or Rust checkout, and `--no-detect` turns that off. `--with rust` adds one,
`--without node` drops one; both flags repeat. `--only rust` asks for exactly
that list with no preset and no auto-detection (it is `--toolset none --with
rust`); an explicit request never auto-detects, and `--detect` opts back in.
Exit `0` done, `1` something
could not be done, `2` could not run at all.

Every flag, variable and command: [`docs/reference.md`](docs/reference.md),
which is **generated from the code** and checked by `sh tests/docs.sh`.

## The problem it exists for

**A writable mount can still refuse `execve`.** A sandbox can point `HOME` at a
large disk that reads and writes fine and denies execution, while `/tmp` allows
it and is small. `mount` does not have to say `noexec`; the refusal can come
from a policy invisible in `/proc/mounts`, so the only reliable answer is to
write a file and run it.

Measured on the sandbox this was built in, where `$HOME` is `/state/home`:

```
$ sandhome space --probe
candidate=/state/home/.local/share/sandhome exists=yes writable=yes exec=no mount=rw,relatime free_mb=52220
candidate=/dev/shm exists=yes writable=yes exec=yes mount=rw,nosuid,nodev free_mb=244 chosen=yes
candidate=/tmp exists=yes writable=yes exec=yes mount=rw,relatime free_mb=52220
```

`/state/home` is where the data wants to live and cannot run a binary. `sandhome`
splits the two roots: executables are copied onto the exec root, shared objects
are symlinked, because `mmap(PROT_EXEC)` is allowed where `execve` is not and
copying a 191MB `libLLVM.so` onto a 250MB root would not fit. The reasoning, and
the four cases the mirror has to get right, are in
[`docs/architecture.md`](docs/architecture.md).

## What is in the box

| path | what it is |
| --- | --- |
| [`ROUTE.md`](ROUTE.md) | **the consumer entry point**: one paste that sets up, checks, and routes. A human pastes its raw URL and the task, and nothing else. |
| [`AGENTS.md`](AGENTS.md) | orientation for an agent working on this repository |
| [`skills/sandhome/SKILL.md`](skills/sandhome/SKILL.md) | **the entry point for an agent setting up a sandbox** |
| [`skills/errandsh/SKILL.md`](skills/errandsh/SKILL.md) | a line discipline for a session with no pty, with full-screen programs via a userspace pty |
| [`skills/sealed-sandbox/SKILL.md`](skills/sealed-sandbox/SKILL.md) | operating inside a cage: no bind, no pty, no passwd |
| `bootstrap.sh` | the installer. Self-fetching when piped. |
| `bin/sandhome` | the command. A bootstrap copies it to `$SANDHOME_EXEC/bin`. |
| `lib/` | the POSIX-sh library: `common`, `detect`, `space`, `fetch`, `env`, `toolchain`, `shim`, `report`, `profile`. |
| `tools/` | one module per toolchain. `sandhome toolchains --json` is the live list; at the time of writing: `bun clang cmake deno emscripten fd gh go jq meson mold ninja node perl pkgconf python qemuuser ripgrep rust shellcheck shfmt yq zig`. `tests/docs.sh` fails when a module exists and this sentence does not name it. |
| `shims/` | seven `LD_PRELOAD` interposers, each built only when its detector says the machine needs it: `fakepty` (a userspace pty), `fakepwd` (a synthetic passwd database), `antiptrace`, and the headless enumeration shims `fakedrm`, `fakeinput`, `fakexenv`, `fakedisplay`. All of them: [`docs/guide.md` section 5](docs/guide.md). |
| `shell/errandsh` | a POSIX-sh line discipline for a pty-less SSH session, with `shell/faketty` as the userspace-pty wrapper. |
| [`docs/reference.md`](docs/reference.md) | **generated**: every command, flag and variable, extracted from the code. |
| [`docs/architecture.md`](docs/architecture.md) | how the pieces fit and why they are shaped this way. |
| [`docs/guide.md`](docs/guide.md) | the long form: every option, every failure mode. |
| [`docs/decisions/`](docs/decisions/) | settled shapes and the measurement behind each. |

Everything is POSIX `sh`. The library depends on the shell and almost nothing
else: not `awk`, not `sed`, not `grep`, not `tr`, not `find`, not `install`. A
bootstrap whose job is to install the missing tools cannot require them first.

## Two things that bite

- **A toolchain already on `PATH` is adopted, not downloaded.** The report says
  which: `installed=` and `adopted=`.
- **The `LD_PRELOAD` shims are opt-in and must stay opt-in.** `fakepty` makes
  every terminal-aware program colourise a *pipe*, which breaks `jq -r` and
  `git`. `SANDHOME_SHIMS=1` turns them on for one shell. The measurement is in
  [`docs/architecture.md`](docs/architecture.md) section 6.
- **A language runtime cannot run from memory.** `node`, `deno` and `bun` are
  real copies in the exec view, because `process.execPath` is read by every
  worker and download helper the runtime spawns, and an anonymous memfd path
  (`/memfd:sandhome (deleted)`) is gone by the time they read it. `doctor`
  checks it and reports `toolchain_node_spawn`. A *compiler* is the opposite
  case and stays a 20KB launcher. See
  [`docs/architecture.md`](docs/architecture.md) section 1.

## Tests

```sh
sh tests/run.sh     # the whole suite
sh tests/docs.sh    # the docs name only flags and paths that exist
```

The runner prints `passed`, `skipped` and `failed` separately, because "could
not run" is a different claim from "passed" and only the second turns the suite
red. `tests/docs.sh` is what keeps the documentation honest: a flag named in a
document that the code does not accept, a path that does not exist, a
subcommand that is not dispatched, or a generated reference that has drifted,
all fail.

## Licence

0BSD. See [`LICENSE`](LICENSE).
