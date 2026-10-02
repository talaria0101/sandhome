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
> run `sh bootstrap.sh --toolset developer`, then `sandhome doctor` - when it
> exits 0, the sandbox is ready; get on with my task and only come back to me
> if doctor fails.

When you receive that instruction, it means: do the setup commands, confirm
doctor exits 0, and then proceed with the task without reporting back on setup
at all. The rest of this skill exists for the case where doctor does not exit 0.

## Set up, in three commands

```sh
sh bootstrap.sh --toolset developer        # from a clone
#   or, with nothing but a network:
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/bootstrap.sh \
  | sh -s -- --toolset developer

sandhome doctor                            # exits 0 when sound
sandhome toolchains                        # what is here, and how it reaches PATH
```

`sandhome status` is the same readiness on one line (roots, view, toolchains,
next command), for a harness that wants to check before it works.

The bootstrap installs a **global hook** into every `PATH` directory that is
writable and runs binaries, so
the next `sandhome doctor` is a fresh shell that needs nothing sourced and no
`env.sh` in front of it. That is the whole fix for the per-command incantation:
setup is once, and a command is a command. A tool the hook does not name -- a
host `python3`, say -- is run with `sandhome exec python3 script.py`, which
applies the same environment a sourced shell gets, `TMPDIR` included, so no
`export TMPDIR=` is needed either. If the host has no writable,
exec-capable `PATH` directory the report says `global=none`; then source the
entry point once per shell:
`. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh"`.

A process with no inherited environment starts from the installed copy,
which carries its library with it: `env -i /tmp/bin/sandhome doctor` works
with no `HOME` and no `PATH`, and `env -i /tmp/bin/sandhome exec CMD...`
runs anything with the right environment. After a tmpfs restart wiped the
exec root, `sandhome resume` rebuilds every recorded view without fetching
and exits with doctor's code.

Toolsets: `minimal` (jq), `cli` (+ ripgrep, fd), `developer` (+ python, node;
the default); `languages` is the full compiler set (`developer` plus
`rust go zig deno bun mold clang cmake meson ninja pkgconf perl`; clang alone is
a >1GB download); `project` is `developer` plus `go rust clang cmake
meson ninja mold pkgconf perl`; `agent` is `developer` plus the runtimes and
CLIs an agent uses at work (`deno bun yq gh shellcheck shfmt qemuuser mold ninja
pkgconf perl`) and carries no compiler chain (work-tree detection can still
fold one in; `--no-detect` turns it off). Add one with
`--with rust`, drop one with `--without node`; both flags repeat and both take a
comma list. `--only rust` (space or comma separated) asks for exactly that list
with no preset and no auto-detection; it is `--toolset none --with rust`, and an
explicit request never auto-detects unless `--detect` says so.

Exit codes: `0` done, `1` something could not be done, `2` could not run. Use
`--dry-run` first when unsure: it is a `bootstrap.sh` flag. `sandhome install`
refuses it (and any unknown flag) before doing any work.

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
sandhome toolchains --json    # the same as an array (name, desc, bins, status, version, origin, view)
sandhome install rust go      # adopt or install, then write the env
```

`install` ends in a **probe**: the tool is run, not assumed. A toolchain that
installed without an error and does not answer is reported as a failure.

`sandhome skills` reports what the setup installed for a harness: one line per
skill per location (`~/.agents/skills`, and `~/.pi/agent/skills` where Pi state
exists) with its state and where the bytes came from, ending in
`skills_installed=N` and exiting non-zero when none is installed. A harness with
a resource reload (Pi: `/reload`) picks them up without a restart.

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
| a CLI installed after the setup is missing from a shell that sourced nothing | run the installer through the hook (`npm i -g`, `go install`, `uv tool install`): the dispatcher links what it wrote into the hook when the installer returns (#142). A CLI copied in by other means still needs `sandhome global`, which re-reads the prefix from disk. A login shell finds it at once |
| an `-fsanitize=address` binary prints nothing and exits 1 (`LeakSanitizer has encountered a fatal error`) | LSan stops threads with `ptrace`, which this cage denies; `env.sh` sets `ASAN_OPTIONS=detect_leaks=0` and `LSAN_OPTIONS=detect_leaks=0` for every ptrace answer except a measured `yes`, so ASan and UBSan keep working. A caller who sets either keeps theirs; `SANDHOME_ASAN=off` restores leak checking. Use clang: `zig cc` ships no sanitizer runtimes (#144) |
| a headless browser is `Permission denied`/`EACCES`, or devtools cannot bind | the cache defaulted to the noexec `$HOME/.cache`; `env.sh` points `PUPPETEER_CACHE_DIR` and `PLAYWRIGHT_BROWSERS_PATH` at `$SANDHOME_EXEC`. Launch with `--no-sandbox` and puppeteer's `pipe: true` (#143) |
| a downloaded executable dies with `Permission denied`/`bad interpreter` although the download succeeded | it landed under the standard cache root (`worker-build`'s emsdk node/emcc and wasm-bindgen CLI, a uv-installed console script). `env.sh` points `XDG_CACHE_HOME` at the exec root; `sandhome doctor` reports `cache_dir_exec` while it does not. `sandhome install --force <name>` re-provisions if the cache already holds a bad copy (#158) |
| `$SANDHOME_EXEC` is empty in the shell the setup gave you, so `mkdir -p "$SANDHOME_EXEC/build"` creates `/build` | the global hook applies `env.sh` to the dispatched tool and cannot export it to your shell. Name the root with the command: `cd "$(sandhome exec-dir)"`, which never prints empty (it reads the recorded file when the variable is unset), or run the line through `sandhome exec --shell '...'`, which applies the whole environment (#156) |
| `cargo build` links on the noexec work tree and `./target/debug/x` dies with `Permission denied` | `env.sh` defaults `CARGO_TARGET_DIR` to a per-project dir under the exec root when unset, so the naive build lands where it can run; a caller who set it keeps it. For anything else build under `$(sandhome exec-dir)` or run the line through `sandhome exec --shell '...'` (#156) |
| `node <dir-of-node>/npm` dies with `SyntaxError: Invalid or unexpected token` while `npm` works | the view's `npm-cli.js` was replaced by a shell wrapper. `tc_node_env` restores the real JavaScript on install and repair, and `doctor` reports `node_npm_js`; `sandhome repair node` fixes an already-clobbered view (#157) |
| an adopted `rustup target add` prints `Read-only file system` and exits 0, so a build later fails on a missing std | the adopted `RUSTUP_HOME` is on the noexec/read-only home and nothing can be added to any toolchain. `sandhome install rust` now points `RUSTUP_HOME` at a writable root on the exec root with the toolchains linked in; `doctor` reports `rustup_writable` (#159) |
| a third-party SDK installer aborts with `Cannot change ownership` / `tar` exit 2 / `installation failed` after a good download | its `tar -xf` has no `--no-same-owner` and the archive carries a foreign uid. The download is fine; the unpack is not. `env.sh` now exports `TAR_OPTIONS=--no-same-owner` as a guarded default so those installers unpack as the caller with no patching (a caller who set `TAR_OPTIONS` keeps it); `doctor` reports `tar_no_same_owner` while the live shell lacks it. This tree's `sh_tar` in `lib/fetch.sh` stays the unpack path for its own fetches (#162) |
| a tool dies with `File size limit exceeded` while **writing** one huge file (a multi-GB `.wat`, a core dump, an `tar -x` of a huge tree) | `RLIMIT_FSIZE` caps a single `write(2)`, not the download; `shard` applies to fetching only. Stream it and bound the consumer (`wasm-dis ... \| head -c 400000000 > out`), point the tool at a directory (`wasm-dis -d dir/`), or split its output. Two 600 MB writes are fine; one 1.2 GB write is not (#164) |
| `cargo build --target <T>` dies with `linker 'emcc' not found` | adding a rust target is necessary but not sufficient: `wasm32-unknown-emscripten`'s linker is a separate Emscripten toolchain with its own `EM_CONFIG`. Run `sandhome install emscripten`: it provisions emcc on the exec view, writes `EM_CONFIG` with view paths, and sets `CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=emcc`; `rustup target add` alone names no linker. `doctor` prints `emscripten_linker` while it is missing (#163) |
| ANSI codes inside `jq` or `git` output | `fakepty` is on; `SANDHOME_SHIMS=0` |
| `cargo`/`rustc` says `Permission denied (os error 13)` from a fresh shell but works in a sourced one | rustup's proxies resolve through the noexec home; `sandhome repair rust` points the view at the real toolchain binaries |
| a browser or bundler dies with `spawn /memfd:sandhome (deleted) ENOENT` | the runtime ran from memory; `sandhome install --force node` puts a real copy in the view, and `doctor` reports `toolchain_node_spawn` while it is not |
| a login shell (`bash -lc`) dies with `cannot map this copy back to its payload` | it resolved the exec bin before the environment was loaded; the profile fragment loads `env.sh` for every login shell now, so re-run the setup once |
| a tool is absent from a fresh shell | the global hook was not installed (`global=none`), a recorded directory no longer answers (`sandhome global --status` shows `state=stale`), or the hook was written into the tree's own indirection (`global=inside-exec-root`, an exec view bin); run `sandhome global` to install or repair it (`--remove` first for the last one), or source the entry point |
| a tool is absent even after `env.sh` was read | it was adopted and could not be linked into the exec view; `sandhome repair <name>` retries the link, and `sandhome install --force <name>` places a copy in the view when the adopted binary cannot be linked at all |
| `doctor` says `FAIL exec_space=low` or `=critical` | the exec root is draining and a build will fail with `no space left on device`. `sandhome space` names the state, `sandhome space --probe` lists roomier candidates, `sandhome gc` reclaims sandhome's own caches, and re-running setup with `--exec DIR` moves everything to a roomy path |
| `doctor` says `toolchain_deno_spawn=no` | deno could not re-execute itself; the probe and the remedy are real, so run `sandhome install --force deno` and read the message it prints. A view that is a real copy always passes (#151) |

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
