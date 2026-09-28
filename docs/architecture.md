# Architecture

How the pieces fit, and why they are shaped this way. For how to *use* it, read
`skills/sandhome/SKILL.md`. For every flag and variable, read
`docs/reference.md`, which is generated from the code.

## 1. The two roots

`SANDHOME_HOME` holds data. `SANDHOME_EXEC` holds executables. The split exists
because of one measured asymmetry:

> A mount can be writable and refuse `execve`, while allowing
> `mmap(PROT_EXEC)`. A shared library read from that mount loads; a binary in it
> does not run. `mount` does not have to say `noexec` - the refusal can come
> from a policy invisible in `/proc/mounts`.

So `sh_exec_probe` writes a `#!/bin/sh` file, chmods it, and **runs it**. Every
decision about a root comes from that, never from parsing mount options.

When the home runs binaries, the two roots collapse and nothing is copied. When
it does not, each toolchain installs into the home and an exec view is mirrored
onto the exec root.

### The mirror's three rules

`sh_promote_tree` in `lib/space.sh` decides per entry, and each rule is a
measured fix rather than a preference:

| entry | what the view gets | why |
| --- | --- | --- |
| a regular executable | **copied** | it must `execve`, and a symlink into a noexec mount is refused |
| a symlink whose target is **inside** the tree | **remapped** onto the view | `bin/npm -> ../lib/node_modules/npm/bin/npm-cli.js` reads `../lib/cli.js` relative to itself; copied to `bin/npm` it looked for `bin/../lib/cli.js` and died |
| a symlink whose target is **outside** the tree | **repointed at the target's absolute path** | the view cannot mirror what it does not contain, and a relative link resolves against a different directory there |
| a symlink whose target is **missing** | **reproduced naming that same missing path** | `cp` dereferences, so the copy fails; the old fallback linked the entry to itself |
| everything else, including `.so` | **symlinked back** to the home | `mmap(PROT_EXEC)` is allowed where `execve` is not, and copying a 191MB `libLLVM.so` onto a 250MB root does not fit |

### Exec-only caches

A build cache is not data. `go run` and `go test` compile into `GOCACHE` and
then `execve` what they built, so `GOCACHE` and `GOTMPDIR` go on
`SANDHOME_EXEC` while `GOPATH` and the module cache stay in the home. Measured:
a cache on a noexec home makes every `go run` fail with
`fork/exec ... permission denied` after a compile that succeeded.

### Choosing the exec root

Candidates are tried in order: `$SANDHOME_EXEC`, the home, `/dev/shm`, `/tmp`,
`/run/user/<uid>`, `$HOME/.cache/sandhome/exec`. The first that is writable
*and runs a file* wins, and among those the first with at least
`SANDHOME_MIN_EXEC_MB` (128) free is preferred. Free space decides, because a
working 244MB `/dev/shm` fills up and a large one that cannot run a file is
worth nothing.

`SANDHOME_EXEC` set explicitly is honoured, and a named root that cannot run a
binary is **refused by name**, never silently replaced.

## 2. The layers

```
bootstrap.sh          the installer. Self-fetching when piped.
bin/sandhome          the command. Copied to $SANDHOME_EXEC/bin by a bootstrap.
  lib/common.sh       logging, shell-only helpers, the one file appender
  lib/detect.sh       what machine is this, read off the machine
  lib/space.sh        the two roots, the probes, the mirror, gc
  lib/fetch.sh        one download path, one digest path, one unpack path
  lib/env.sh          the environment, written once and read everywhere
  lib/toolchain.sh    the contract every tools/<name>.sh obeys
  lib/shim.sh         the two LD_PRELOAD interposers
  lib/report.sh       the report, read from probes
  lib/profile.sh      the login fragment (fetched never, aliased never)
  tools/<name>.sh     one module per toolchain
  shims/*.c           fakepty, fakepwd
  shell/errandsh      a line discipline for a session with no kernel pty
  shell/faketty       run one command under the userspace pty
```

**One fact has one home.** The environment is written once, to
`$SANDHOME_HOME/env.sh`, and every caller sources that file; `sandhome env`
prints the same bytes, so `eval "$(sandhome env)"` and the file cannot drift.
Each toolchain owns one fragment under `$SANDHOME_HOME/env.d/`, and `env.sh`
sources them all, so a second module cannot clobber the first.

**Every function is namespaced by its module**, because POSIX `sh` has no
namespaces and two modules defining `install` would shadow each other silently.

## 3. The toolchain lifecycle

1. Resolve the requirement closure with an iterative algorithm, not recursion,
   and refuse a cycle **by name**.
2. Load any existing environment fragment, then **adopt** if `tc_<name>_probe`
   answers, **install** otherwise. Adoption is the common case: a sandbox that
   already carries a toolchain should not download a second copy.
3. Promote: build the exec view and link every `TC_<name>_BINS` entry into
   `$SANDHOME_EXEC/bin`. This runs on **both** paths, because an adopted
   toolchain has no home tree to mirror and the link is all it needs.
4. Call `tc_<name>_env`, load the environment again.
5. **Probe once more.** A toolchain that installed "without an error" and does
   not answer is the exact claim this tree exists to refuse, and the split root
   is where it hides. The post-promote probe runs for an adoption too, because
   an adoption fails differently: a module that probes by its own home path is
   true on a collapsed home and false the moment the roots split.

## 4. POSIX sh, and the dependency set

`dash -n` and `bash --posix -n` on every file, in `tests/syntax.sh`. No `local`,
no arrays, no `[[`, no `$'...'`, no `a && b || c`.

The library may not use `awk`, `sed`, `grep`, `tr`, `find`, `install` or
`dirname`. Measured across minimal images: Photon carries neither `awk` nor
`tr`, openSUSE carries neither `awk` nor `find`, Void and Rocky 8 carry no
`find`. A bootstrap whose job is installing the missing tools cannot require
them first. `uname` and `id` are the exceptions POSIX guarantees.

**No recursion.** POSIX `sh` has no locals, so a function's variables are
globals and a recursive call overwrites its caller's. `sh_promote_tree` was
recursive: the nested call for one subdirectory overwrote the parent's source,
destination and basename, and the second sibling directory was mirrored under
the first. Measured on the Go tree: 32 files failed to copy and `go` never
landed in the view at all, while every message blamed the file. Every walk here
is a queue.

**`read` at EOF.** `read` returns non-zero on a last line with no newline and
still sets the variable. Testing its status threw the answer away, which broke
Go's version lookup; `sh_first_line` and `sh_first_word` use `read ... || :`,
and `sh_read_file` carries that last line out of the loop.

**Command substitution strips a trailing newline**, so `NL=$(printf '\n')` is
the empty string and a `case` arm built on it can never match. The JSON escaper
matches control characters with a bracket expression instead.

## 5. The toolchain contract

One module per toolchain at `tools/<name>.sh`. The full contract is in
`docs/decisions/toolchain-contract.md`; the rules that exist because the
alternative was measured are:

1. **Install into `$(sh_toolchain_root <name>)`.** A module that picks its own
   location cannot be promoted, reported or collected.
2. **Declare every executable that must be on `PATH`** in `TC_<name>_BINS`. An
   undeclared binary is absent from every shell.
3. **Never test a binary by its home path.** The home may refuse `exec`. Let the
   framework's post-promote probe decide, by running the tool.
4. **Put exec-only caches on `SANDHOME_EXEC`.** Go is the example above.
5. **Declare `tc_<name>_adopted`** if the tool may be adopted. Without it an
   adopted toolchain is linked from wherever it happens to be on `PATH`, which
   is a guess.
6. **Refuse with a reason.** A missing asset, an unsupported kernel/arch pair or
   a failed digest is a warning plus a non-zero return, never a silent skip that
   later reads as a transport failure.

## 6. The shims, and why they are opt-in

`fakepty` is a **userspace pty**. It keeps a list of the session's own
`readlink()` descriptor identities (`SANDHOME_FAKEPTY_ID`, set by `shell/faketty`
from `/proc/$$/fd`) and answers `isatty`, `tcgetattr`, `ioctl(TIOCGWINSZ)` and
`open("/dev/tty")` as a terminal for THOSE, and for nothing else. A pipe a
program opens later is a new object; it is not in the list and stays a pipe, so
`jq -n 1 | cat` does not put ANSI codes into `cat`. Without the variable the
older fds 0-2 behaviour is kept, and that is what made the shim unsafe to turn
on: it reported every fd 1, including a pipeline's. `fakepwd` answers
`getpwnam`/`getpwuid` from a synthetic passwd database for a cage with no
`/etc/passwd`. Neither can reach a **statically linked** binary, because a
static binary carries its own libc and there is nothing to interpose into.

That limit is about interposition, not about terminals. A full-screen program
is a matter of what it is linked against: `less`, `nano`, `top` and python
curses are dynamically linked and run full-screen here, where the kernel offers
no pty at all. So the honest statement of the limit is that `sandhome pty`
cannot reach a statically linked binary, and not that a full-screen program is
the one thing it cannot do.

They are loaded only when `SANDHOME_SHIMS` is set to something other than `0`.
When they are, `env.sh` computes the same descriptor identities for the login
shell, so the session is scoped from the first command. `shell/faketty` is the
single-command path: it exports the shim and the identity and `exec`s, which is
why a subshell the command starts still has a terminal.

## 7. Digests

`sh_fetch_verified` fetches, digests, compares, refuses, and reports **which
tool took the digest and where the expected value came from**:

```
sha256 b1c22172...870f (taken with sha256sum; no digest to compare against)
sha256 matches the value from SANDHOME_SHA256 (pinned by the caller) (taken with sha256sum)
... does not match the expected sha256 (got b1c... with sha256sum, wanted 0000...)
```

A digest fetched from the same release as the bytes proves **transport, not
authorship**: whoever could replace one could replace the other. It catches a
mirror that truncates a download, which is the common failure.
`SANDHOME_SHA256` is the stronger check, and `SANDHOME_REQUIRE_DIGEST=1` turns
a missing digest tool into a refusal rather than a warning.

Two toolchains fetch from a source that publishes a digest beside the archive:
Go from `dl/?mode=json`, found by matching the archive's own `filename` because
**there is no `.sha256` sidecar** (that URL is an HTML redirect page and yields
`<!DOCTYPE` as a digest), and Node from `SHASUMS256.txt`. Both parsers are
formatting-independent and are tested offline through a `SANDHOME_*_URL`
override, because a parser that only works against one rendering of a document
silently returns nothing and the download then goes unchecked.

## 8. What runs at shell start

The profile fragment: nothing that can fail. It fetches nothing, defines no
alias and no prompt, returns early for a non-interactive shell (`$-` containing
`i`), de-duplicates `PATH` and drops empty elements, gives history a home that
survives the session, and in WSL moves an interactive shell off a mounted
Windows drive. One switch, `SANDHOME_NO_PROFILE=1`, turns all of it off.
