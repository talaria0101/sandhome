# The sandhome guide

This is the page to read before working in a sandbox this repository set up, and
the page to read before adding a toolchain to it.

## 1. The two roots

`sandhome` keeps two directories apart on purpose:

- **`SANDHOME_HOME`**  -  the persistent data root. Default
  `$XDG_DATA_HOME/sandhome`, else `$HOME/.local/share/sandhome`. It may be a
  mount that refuses `execve`; every read and write still works there.
- **`SANDHOME_EXEC`**  -  the root that runs binaries. Default: the home root when
  it runs binaries, otherwise the first candidate that both is writable and
  *actually runs a file*, preferring one with at least `SANDHOME_MIN_EXEC_MB`
  (128) megabytes free. Candidates are tried in the order
  `$SANDHOME_EXEC`, the home, `/dev/shm`, `/tmp`, `/run/user/<uid>`,
  `$HOME/.cache/sandhome/exec`. There is no `/var/tmp`: it was in an older list
  only because the probe report created it, and `/var` is precisely the
  directory a sealed cage tends not to have.

  **Free space decides between working candidates, and it is the decision that
  matters.** On this sandbox `/dev/shm` works and has 244MB while `/tmp` works
  and has 52GB; the first plan picks `/tmp`, and installing `go` onto the other
  one fails for want of room. `SANDHOME_MIN_EXEC_MB` raises the bar; when no
  candidate clears it the first that works is used and a warning says so.

  **The choice is then stable.** The root recorded in `$SANDHOME_HOME/env.sh`
  is reused while it still runs a file, so a later install does not migrate the
  exec root out from under the views, caches, launchers and PATH entry that
  already live on it (issue #41). A recorded root that is gone or refuses exec
  falls back to the roomiest working candidate, and `--exec` (or
  `SANDHOME_EXEC`) overrides both.
  **A root that is draining is announced, not discovered.** The exec root holds
  `GOCACHE`, `GOBIN`, `CARGO_TARGET_DIR`, `NPM_CONFIG_PREFIX` and every build
  artifact, so it is the first thing a real project fills, and the failure is
  quiet. Measured here, with a 245MB exec root at 36MB free:

  ```
  $ sandhome doctor ; echo $?
  ok   exec_runs=yes
  doctor_failures=0                 # before
  $ go build -o "$SANDHOME_EXEC/x" .
  go build: copying .../a.out to ...: no space left on device
  $ echo $?
  0                                 # and the exit code was 0
  ```

  Three failures in one: nothing warned while the root drained, the build
  reported success having produced nothing, and the only check that fired on a
  completely full root said `exec_runs=no`, which is true and is a sentence
  about `execve` rather than about space. So the root now carries a state and
  the gate fails on it:

  | state | when | what you see |
  | --- | --- | --- |
  | `ok` | room to spare | nothing |
  | `low` | under `SANDHOME_LOW_EXEC_MB` (100) on a small root, or under `SANDHOME_LOW_EXEC_PCT` (10) free on a large one | a `low` line from `sandhome space`, `exec_space=low` in the report, a `[!]` on the next install, and `doctor` exits non-zero |
  | `critical` | under `SANDHOME_CRIT_MB` (32), or under 5% free of a large root | the same, naming the number and the remedy |
  | `full` | nothing left | the same, plus `gc` and `--exec` by name |

  A small root is judged on megabytes and a large one needs **both** a share and
  an absolute floor, because either alone is wrong. A pure share rule is nonsense
  at scale: the 419GB disk this was written on sat at 6.6% free with 393GB still
  on it, a share-only rule called that `low`, and `doctor` failed a freshly built
  home with 27GB free. A pure absolute rule is nonsense at the small end, which is
  why a root under `SANDHOME_PCT_MEANINGFUL_MB` (1GB) is judged on megabytes
  alone. So on a large root `low` means *both* under 10% free and under
  `SANDHOME_LOW_EXEC_MB`, which is the shape a genuinely draining root has: 40MB
  of 4TB is 0.001% free and cannot build anything.

  Every message names a command rather than only describing the state, because
  the value of hearing about it early is that there is still time to act.

When the home runs binaries the two collapse and nothing is copied. When it does
not, a toolchain installs into the home and an **exec view** is mirrored onto the
exec root. The rule for each entry:

- a **regular executable** is copied, because it must `execve`;
- a **symlinked executable whose target is inside the same tree** is mirrored as a
  symlink to the target's own place in the view, so relative paths beside it keep
  working;
- everything else (`.so`, `.rlib`, data) is symlinked back to the home.

This works because `mmap(PROT_EXEC)` is allowed on a noexec mount even when
`execve` is not  -  so a shared library loads from the home while the binary that
needs it runs from the exec root.

> **A symlink to a script on a noexec mount still does not run.** The kernel
> checks the script's own inode, so `bin/npm -> ../lib/.../npm-cli.js` pointed at
> the home fails with `bad interpreter: Permission denied`. That is why a
> symlinked executable is mirrored *into* the view rather than left pointing at
> the home; `npm` is the measurement behind the rule.

`SANDHOME_EXEC` set explicitly is honoured, and a named root that cannot run a
binary is refused **by name** rather than silently replaced.

Read the plan with:

```sh
sandhome space          # the chosen roots and their free space
sandhome space --probe  # every candidate, with writable/exec/mount/free
```

## 2. Bootstrap

```sh
sh bootstrap.sh [options]
```

| option | meaning |
| --- | --- |
| `--toolset NAME` | `minimal`, `cli`, `developer`, `languages`, `agent`. What each carries is in the table below |
| `--with LIST` / `--without LIST` | add or drop toolchains by name |
| `--list-toolchains` | print the known names |
| `--home DIR` / `--exec DIR` | override the roots. An option beats the environment variable of the same name. |
| `--no-shims` / `--require-shims` | do not build, or refuse without, the shims |
| `--no-shell` | do not install `errandsh` |
| `--no-profile` / `--no-path-line` | leave the login files alone |
| `--dry-run` / `--json` | preview, or one JSON report |
| `--doh-url URL` | DNS-over-HTTPS resolver for a confirmed no-resolver cage (see `SANDHOME_DOH_URL` in the reference). Off unless set. |

The five toolsets, and the difference between them is the compilers:

| toolset | carries |
| --- | --- |
| `minimal` | `jq` |
| `cli` | `jq ripgrep fd` |
| `developer` | `jq ripgrep fd python node` |
| `languages` | `developer` plus `rust go zig deno bun mold` |
| `agent` | the same as `languages` |

`clang` is the one toolchain in no toolset, and is asked for by name:
`sandhome install clang` or `bootstrap.sh --with clang`. Its download is above
1GB and its exec view wants a roomy root, so a toolset that every sandbox
would pay for it is the wrong shape.

The run: detects the machine, plans the roots, adopts or installs each toolchain,
builds the shims this machine actually needs, writes `$SANDHOME_HOME/env.sh`,
installs `$SANDHOME_HOME/profile.sh` and the one line a login file reads, and
prints a report **read from the machine**  -  never from what was requested.

Exit codes: `0` done, `1` something asked for could not be installed, `2` could
not run at all.

### From a pipe

`bootstrap.sh` run with `$0` as the interpreter has no `lib/` beside it, so it
fetches the branch named by `SANDHOME_REF` (default `main`) from
`SANDHOME_REPO` (default `talaria0101/sandhome`), unpacks it to a temp dir, and
re-execs itself there.
`SANDHOME_NO_REFETCH=1` turns that off.

## 3. The environment

`$SANDHOME_HOME/env.sh` is the single source of truth. It exports the roots, puts
the exec bin directory on `PATH`, and sources one fragment per toolchain from
`$SANDHOME_HOME/env.d/`. It also exports `SANDHOME_REPO_DIR`, which is how the
copy of `sandhome` the bootstrap placed in `$SANDHOME_EXEC/bin` finds its
library. That copy is a **copy, not a symlink**, because the checkout is
frequently on a root that refuses `execve`: a symlink into it answers
`command -v sandhome` and then fails with `Permission denied`.

```sh
. "$SANDHOME_HOME/env.sh"          # in a shell
eval "$(sandhome env)"             # without sourcing the file
sandhome env                       # to read it
```

The installed profile fragment de-duplicates `PATH`, gives history a home that
survives the session, and moves an interactive shell out of a mounted Windows
drive in WSL. It is `SANDHOME_NO_PROFILE=1`-off in one switch, fetches nothing,
and defines no alias or prompt. It runs only for an interactive shell (`$-`
contains `i`), so a tool that sends a command to a login shell does not have its
environment changed underneath it.

## 4. Adding a toolchain

Drop `tools/<name>.sh`. It declares:

```sh
TC_<name>_DESC='one line for sandhome toolchains'
TC_<name>_BINS='bin/tool'          # relative executables to expose
TC_<name>_REQUIRES='other'         # optional; ensured first

tc_<name>_probe()   { ...; }       # 0 when a working copy is already here
tc_<name>_install() { ...; }       # install into $(sh_toolchain_root <name>)
tc_<name>_env()     { ...; }       # write the env fragment (optional)
tc_<name>_version() { ...; }       # print a version (optional)
```

The framework, `lib/toolchain.sh`:

1. ensures `TC_<name>_REQUIRES` first, refusing a cycle by name;
2. loads any existing environment fragment, then **adopts** when
   `tc_<name>_probe` succeeds, **installs** otherwise;
3. promotes `TC_<name>_BINS` and builds the exec view;
4. calls `tc_<name>_env`, loads the environment, and **probes again**;
5. fails loudly when a toolchain installed "without an error" and still does not
   run from the exec view.

Three rules keep a module portable:

- Install into `sh_toolchain_root <name>` and promote only what must execute.
- **Never test a binary by its home path**  -  it may not run there. Declare it in
  `TC_<name>_BINS`, or expose it through the fragment and let the framework's
  post-promote probe decide.
- **Put exec-only caches on `SANDHOME_EXEC`.** Go is the example: `go run` and
  `go test` build an executable into `GOCACHE` and then `execve` it, so a cache on
  a noexec home fails with `fork/exec ... permission denied` after a successful
  compile. Downloads and module caches are data and stay in the home.

For a version or digest that is fetched, give the URL a `SANDHOME_*` override
(`SANDHOME_GO_VERSION_URL`, `SANDHOME_GO_DL_JSON_URL`, `SANDHOME_NODE_INDEX_URL`).
That lets the parser be tested against a local file, which is how both of the
version parsers here are covered offline. See
[`decisions/toolchain-contract.md`](decisions/toolchain-contract.md).

### Downloads larger than the file-size limit

A sandbox can pin a per-file cap (`ulimit -f`, RLIMIT_FSIZE) that no process can
raise  -  measured here at exactly 1,000,000,000 bytes, where `curl` died with
`File size limit exceeded` on a 1.9GB asset. A single file above the cap is
unreachable by construction, and resuming appends to a file already at the cap.
`sandhome` never makes one: when `Content-Length` exceeds the cap, `sh_fetch_stream`
fetches numbered ranges  -  each under the cap  -  and `sh_stream_untar` unpacks a
`.tar.*` from the concatenated stream. The digest is taken over the stream, so
verification is unchanged. `SANDHOME_FETCH_CHUNK_MB` sets the range size
(default 256, capped at three quarters of the limit). A `.zip` above the limit is
refused by name, because a zip's directory sits at the end and cannot be read as
a stream. `sandhome install clang` is the worked example: the x86_64 LLVM tarball
is about 1.9GB.

`--with clang` is the one toolchain not in a toolset, because its view is large
(hundreds of MB) and it wants a roomy exec root; `zig`, `deno`, `bun` and `mold`
are in the `languages` and `agent` toolsets.

### Cross compilers and linkers

`zig cc` is a complete C/C++ compiler and cross compiler, and it is also a
linker: `zig cc hello.c -o hello`, `zig cc -target aarch64-linux-musl hello.c`.
`mold` is a fast ELF linker: `gcc -fuse-ld=mold hello.c` and `g++ -fuse-ld=mold`.
The mold archive ships both `mold` and `ld.mold`, and the latter is what
`-fuse-ld=mold` looks for; clang accepts `-fuse-ld=mold` too, or
`--ld-path=$(command -v mold)`. For a rust cross target, `sandhome install rust
--target <triple>` writes a `zig cc -target <triple>` linker wrapper and exports
`CARGO_TARGET_<TRIPLE>_LINKER`.

## 5. The shims

Two `LD_PRELOAD` interposers, built only when the machine needs them:

- **`fakepty`**  -  a USERSPACE pty. It makes the session's descriptors look
  like a terminal (isatty, termios, window size, `/dev/tty`) where there is no
  `/dev/ptmx`, so readline, echo and full-screen programs work over a pipe.
- **`fakepwd`**  -  answers `getpwnam`/`getpwuid` from a synthetic database, for a
  cage with no `/etc/passwd`. It reads `$SANDHOME_PASSWD`; `env.sh` exports it.

Both are built into `$SANDHOME_HOME/shims/`. `env.sh` puts them in `LD_PRELOAD`
only when `SANDHOME_SHIMS` is set to something other than `0`. `fakepty` is no
longer a blanket `isatty()==1`: `env.sh` also exports `SANDHOME_FAKEPTY_ID`, the
readlink identity of the session's own descriptors, and only THOSE are faked. A
pipe opened later is a new object and stays a pipe, so `jq -n 1 | cat` does not
put ANSI codes into `cat`. Without the variable the older fds 0-2 behaviour is
kept.

`shell/faketty` is the caller-facing half: it sets that id, the window size and
`LD_PRELOAD`, then `exec`s, so a subshell the command starts inherits the
terminal. `sandhome pty CMD` and errandsh's foreground mode both go through it.

```sh
SANDHOME_SHIMS=1 . "$SANDHOME_HOME/env.sh"   # on, for this shell
SANDHOME_SHIMS=0 . "$SANDHOME_HOME/env.sh"   # off, for this shell
sandhome pty top                             # a terminal for one command
```

> **Neither can reach a statically linked binary.** A static binary carries its
> own libc, so there is nothing to interpose into. Build the ssh server, or any
> other program the shims must reach, dynamically.

`SANDHOME_PASSWD_USERS=agent,deploy` adds those login names to the synthetic
database  -  an ssh server refuses an unknown account with `Permission denied
(publickey)`, which reads as a key problem and is not one.

## 6. errandsh

`sandhome shell` runs `shell/errandsh`, a POSIX-sh line discipline that gives a
pty-less session echo, line editing, history, completion, bracketed paste and
real signal handling at the prompt. `sandhome shell -c 'cmd'` is an exec channel
with no discipline. Its test is `tests/errandsh-posix.sh`, which drives it over
pipes under every shell the host has.

**Full-screen programs work, without a kernel pty.** A cage has no `/dev/ptmx`,
so `faketty(1)` and `fakepty(1)`  -  which both call `openpty(3)`  -  cannot run
(the measured error is `out of pty devices`). `shims/fakepty.c` is a USERSPACE
pty instead, and `shell/faketty` is the wrapper that exports it and execs:

```sh
sandhome pty nano file      # any command gets a terminal
sandhome pty top
faketty less file           # the wrapper directly
```

In errandsh a full-screen program is detected by name and run in the foreground
on the session's own descriptors, so it reads the operator's keys directly; the
line discipline steps aside for that one command and returns afterwards. `pty
CMD` forces the path for anything not on the list, and `ERRANDSH_PTY=0` turns
the automatic part off. Because the interposer is exported and exec'd, a
subshell the program spawns keeps the terminal.

The one thing it cannot reach is a STATICALLY LINKED program: LD_PRELOAD has
nothing to interpose into. The list of programs, and `SANDHOME_FAKEPTY_SIZE`
(`COLSxROWS`, default `COLUMNSxLINES`, then 80x24), are described in
`docs/reference.md`.

## 7. Troubleshooting

| symptom | first thing to read |
| --- | --- |
| a tool "installed" and is not found | `sandhome space --probe`; the toolchain may have landed on a root that does not run it |
| a tool is on PATH but a shell that inherited nothing cannot find it | it was adopted, not installed, and its binary could not be linked into the exec view; `sandhome repair <name>` retries the link, and `sandhome install --force <name>` puts a copy there when the adopted binary cannot be linked at all |
| `Permission denied` running a binary | the home is noexec and the exec view was not built  -  run `sandhome repair <name>`, which rebuilds the view and downloads nothing. `install` is the command that adopts and downloads, and on an adopted toolchain it is what broke the view, so routing the diagnosis through it reproduced the defect 8 times out of 8 (#49) |
| `Too many levels of symbolic links` on a binary | the view links a tool to itself; `sandhome repair <name>` rewrites the link |
| `fork/exec ... permission denied` after a successful `go build` | the Go build cache landed on a noexec root; re-run the install so `GOCACHE` is written to `SANDHOME_EXEC` |
| `go install` binary neither runs nor is on PATH | `GOBIN` now points at `$SANDHOME_EXEC/go-bin` and is on PATH; re-run `sandhome install go`, then `go install`. Build output in a noexec work tree still will not run: build under `$SANDHOME_EXEC` |
| `npm i -g` CLI not found or `bad interpreter` | the prefix now lives on `$SANDHOME_EXEC/npm-global` with `bin` on PATH; re-run `sandhome install node`. Project-local `.bin` on a noexec checkout has the same cause: run the project from `$SANDHOME_EXEC` |
| `collect2: posix_spawnp: Permission denied` linking rust | the sysroot linker is on the noexec home, so it cannot be exec'd at all. A `-fuse-ld=` flag does not fix it: rustc appends its own `-fuse-ld=lld` and `-B<sysroot>` after any `-C link-arg`, so the last one wins. `sandhome install --force rust` puts the toolchain on the exec root, where a plain `rustc -O hello.rs -o out` links and runs with no `RUSTFLAGS` |
| the working tree itself is noexec | `sandhome doctor` prints a note naming `$SANDHOME_EXEC`; build and run output there, not in the checkout |
| a per-project `.venv` half-works: `python -m` runs, every console script says `bad interpreter: Permission denied` | the venv is on a noexec checkout, and each console script's shebang is an absolute path into it. `uv venv` has already made the symlink, which is why python itself works. Put the venv on the exec root: `uv venv "$SANDHOME_EXEC/venvs/NAME" && uv pip install --python "$SANDHOME_EXEC/venvs/NAME/bin/python" PKG` (#42) |
| `npm install` exits 0 and `./node_modules/.bin/CLI` says `bad interpreter: Permission denied` | same cause: the shebang is `/usr/bin/env node` resolved through a noexec tree. `node node_modules/CLI/index.js` always works, because node reads the file rather than exec'ing it (#42) |
| no echo / no line editing over ssh | the shims are not loaded; `SANDHOME_SHIMS=1` and restart the shell |
| an ssh login is refused with `publickey` | the login name is absent from the synthetic passwd; set `SANDHOME_PASSWD_USERS` |
| a full-screen program runs in batch mode | it is statically linked (nothing to interpose into), or `faketty` is not built. `sandhome pty CMD` forces the userspace pty; `sandhome shims build` builds it |
| `File size limit exceeded` on a download | `ulimit -f` pins a per-file cap; sandhome shards any download whose `Content-Length` exceeds it and unpacks a `.tar.*` from the stream. `SANDHOME_FETCH_CHUNK_MB` tunes the range size. A `.zip` above the cap is refused by name |
| `mold` is on PATH but `-fuse-ld=mold` cannot find it | the mold archive ships both `mold` and `ld.mold`; both land on the exec bin. Check `command -v ld.mold`. Clang accepts `--ld-path=$(command -v mold)` as well |
| `doctor` says `FAIL exec_space=low` or `=critical` | the exec root is draining. `sandhome space` names the state and the numbers, `sandhome space --probe` lists roomier candidates, `sandhome gc` reclaims sandhome's own caches, and re-running the setup with `--exec DIR` moves everything to a roomy path. See section 1 for the thresholds |
| the exec root filled | `sandhome gc`; staging, exec caches (`cache/`, `tmp/`, `go-bin/` entries older than DAYS), and home tmp older than DAYS are removed, toolchain data stays. `GOCACHE`, `GOBIN`, `NPM_CONFIG_PREFIX`, `CARGO_INSTALL_ROOT`, `CARGO_TARGET_DIR`, and `target/` all land on the exec root: heavy and multi-target builds need a roomy `--exec DIR`. If no candidate fits, the install names the constraint before writing anything |
| the exec root was cleared by a restart | the tmpfs exec view is gone while `env.sh` persists; re-run the setup, then `sandhome install <name>` to rebuild the view |

## 8. The report

`sandhome report` prints one `key=value` per line, and `--json` one object. It is
read from probes: `pty`, `passwd`, `home_exec`, per-toolchain versions, and
`failures`. `sandhome doctor` is the pass/fail view of the invariants a working
home must satisfy.
