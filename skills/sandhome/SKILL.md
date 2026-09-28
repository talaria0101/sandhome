---
name: sandhome
description: Set up and repair a portable agent sandbox with sandhome - detect which roots can execute, install or adopt toolchains (jq, ripgrep, fd, python, node, rust, go, zig, clang, deno, bun, mold), download an archive larger than the per-file size limit by sharding it, write the environment, and diagnose a tool that installed but will not run. Use when a fresh sandbox needs tooling, when HOME is on a noexec mount, when a binary is Permission denied, when go run fails after a successful build, when a download dies with File size limit exceeded, or when an agent needs a toolchain in under a minute.
---

# sandhome

Turns a bare userland into a working one. The single fact to hold onto is that
**a writable mount can still refuse `execve`**, so data and executables may need
different roots.

`docs/reference.md` is the complete reference - every command, every flag, every
environment variable, with the output each one produces - and it is GENERATED
from the code, so it cannot name a flag that does not exist. After a network-only
setup the docs also live under `$SANDHOME_HOME/repo/docs/`; without any docs on
disk use `sandhome help`, which prints the same contract. `docs/guide.md`
carries every failure mode. What follows is the fast path, and it is enough.

## The one-line instruction a human can paste

Everything in this skill compresses to one instruction, which is what a human
will actually type before giving you a task:

> Set up my sandbox: fetch
> https://raw.githubusercontent.com/talaria0101/sandhome/main/bootstrap.sh ,
> run `sh bootstrap.sh --toolset developer`, then
> `. "$HOME/.local/share/sandhome/env.sh"`, then `sandhome doctor` - when it
> exits 0, the sandbox is ready; get on with my task and only come back to me
> if doctor fails.

When you receive that instruction, it means: do the four setup commands,
confirm doctor exits 0, and then proceed with the task without reporting back
on setup at all. The rest of this skill exists for the case where doctor does
not exit 0.

## Set up, in four commands

```sh
sh bootstrap.sh --toolset developer        # from a clone
#   or, with nothing but a network:
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/bootstrap.sh \
  | sh -s -- --toolset developer

. "$HOME/.local/share/sandhome/env.sh"     # in this shell
sandhome doctor                            # exits 0 when sound
sandhome toolchains                        # what is here, and how it reaches PATH
```

Toolsets: `minimal` (jq), `cli` (+ ripgrep, fd), `developer` (+ python, node;
the default), `languages` and `agent` (both + rust, go). Add one with
`--with rust`, drop one with `--without node`; both flags repeat and both take a
comma list.

Exit codes: `0` done, `1` something could not be done, `2` could not run. Use
`--dry-run` first when unsure.

## What a run does, in order

Detects the machine, plans the two roots, **adopts** each toolchain that already
answers and **installs** the ones that do not, builds the shims this machine
actually needs, writes `$SANDHOME_HOME/env.sh`, copies `sandhome` onto the exec
root, installs the profile fragment, and prints a report read from the machine.

Adoption matters: a toolchain already on `PATH` is not downloaded again, and the
report distinguishes it (`installed=` vs `adopted=`).

## Install or adopt later

```sh
sandhome toolchains           # name, status, version, and how it reaches PATH
sandhome install rust go      # adopt or install, then write the env
```

`install` ends in a **probe**: the tool is run, not assumed. A toolchain that
installed without an error and does not answer is reported as a failure.

## Diagnose a tool that will not run

1. `sandhome space --probe`  -  which root runs a binary, and which is `exec=no`?
2. `sandhome repair <name>`  -  rebuilds the exec view. Downloads nothing, so it
   cannot make a working install worse; `install` is the command that adopts and
   downloads, and on an adopted toolchain that is what broke the view in the
   first place.
3. `sandhome doctor`  -  one line per invariant, ending in `doctor_failures=N`.

| symptom | fix |
| --- | --- |
| `Permission denied` on a binary | the exec view was not built; `sandhome repair <name>` |
| `Too many levels of symbolic links` on a binary | the view links a tool to itself; `sandhome repair <name>` rewrites the link |
| `collect2: posix_spawnp: Permission denied` linking rust | the sysroot linker is on the noexec home and cannot be exec'd; no `-fuse-ld` value fixes it. `sandhome install --force rust` puts the toolchain on the exec root || `fork/exec ...: permission denied` after a successful `go build` | the build cache was on a noexec root; `sandhome install go` puts `GOCACHE` and `GOBIN` on the exec root, for an adopted go too |
| `npm i -g` CLI missing or `bad interpreter` | prefix was on the noexec home; `sandhome install node` moves it to the exec root |
| ANSI codes inside `jq` or `git` output | `fakepty` is on; `SANDHOME_SHIMS=0` |
| a tool is absent from a fresh shell | `$SANDHOME_HOME/env.sh` was not read |
| a tool is absent even after `env.sh` was read | it was adopted and could not be linked into the exec view; `sandhome repair <name>` retries the link, and `sandhome install --force <name>` places a copy in the view when the adopted binary cannot be linked at all |
| `doctor` says `FAIL exec_space=low` or `=critical` | the exec root is draining and a build will fail with `no space left on device`. `sandhome space` names the state, `sandhome space --probe` lists roomier candidates, `sandhome gc` reclaims sandhome's own caches, and re-running setup with `--exec DIR` moves everything to a roomy path |

## Add a toolchain

Create `tools/<name>.sh` following the contract in `docs/architecture.md` section 5.
The module
installs into `$(sh_toolchain_root <name>)`, declares every executable that must
be on `PATH` in `TC_<name>_BINS`, and **never tests a binary by its home path**:
the home may refuse `exec`. The full rules and why each exists are in
`docs/architecture.md` section 5 and `docs/guide.md` section 4.

## Check a change

```sh
sandhome test                    # the whole suite
sandhome selftest                # the checks that need no network
sh tests/space.sh                # the two-root plan and the mirror
```

`passed`, `skipped` and `failed` are three different claims and only `failed`
turns the suite red.
