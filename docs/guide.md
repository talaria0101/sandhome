# The sandhome guide

This is the page to read before working in a sandbox this repository set up, and
the page to read before adding a toolchain to it.

## 1. The two roots

`sandhome` keeps two directories apart on purpose:

- **`SANDHOME_HOME`**  -  the persistent data root. Default
  `$XDG_DATA_HOME/sandhome`, else `$HOME/.local/share/sandhome`. It may be a
  mount that refuses `execve`; every read and write still works there.
- **`SANDHOME_EXEC`**  -  the root that runs binaries. Default: the home root when
  it runs binaries, otherwise the roomiest candidate that both is writable and
  *actually runs a file* and clears `SANDHOME_MIN_EXEC_MB` (128) megabytes free.
  Candidates are the explicit override, the working-tree namespaced dirs (PWD,
  its parents, the git top level), the named work volumes (`/workspace`,
  `$GITHUB_WORKSPACE`, `$RUNNER_TEMP`, `$AGENT_WORKFOLDER`, `$WORKSPACE`,
  `/mnt`, `/data`, `/scratch`, `/srv`), then the home, `/dev/shm`, `/tmp`,
  `/run/user/<uid>`, `$HOME/.cache/sandhome/exec`, and order is only a tie-break:
  preferring the first candidate that merely cleared the floor put a 184MB
  `/dev/shm` ahead of a 488MB `/tmp` and the default toolset failed for want of
  room (issue #37). Exec perms differ by sandbox, so every candidate is probed
  with a real file before it can win: a roomy noexec volume loses on its merits
  and a small exec-capable one wins only when nothing roomier runs. A cage
  without any of the named volumes simply does not have those entries, and the
  fallback is the roomiest tmpfs that runs.

  **The only honest way to read the plan on a new machine is to run it.** These
  figures are a property of the machine, not of the tree, and they go stale:
  exec permissions and free space both change under a long-lived sandbox, so a
  document that states them as fact is describing one host at one moment. Two
  from the sandbox this was measured on, kept because they are the shape of the
  problem rather than the answer to it - `/workspace` ran binaries while `/tmp`
  and `/dev/shm` did not, so the roomiest volume *won* and the tmpfs lost; on a
  host where both run, `/tmp` won on free space. Neither is a rule:

  ```sh
  sandhome space --probe   # every candidate: writable, exec, mount, free
  sandhome space           # the two the plan chose, and why
  ```

  **Free space decides between working candidates, and it is the decision that
  matters.** Where `/dev/shm` runs and is small while `/tmp` runs and is large,
  the plan picks `/tmp` on free space, and installing `go` onto the other one
  fails for want of room. `SANDHOME_MIN_EXEC_MB` raises the bar; when no
  candidate clears it the first that works is used and a warning says so.

  **When no roomy exec-capable root exists, nothing points at one (issue #59).**
  `sandhome space` names the ceiling once: `max_exec_free_mb` is the most free
  megabytes on any exec-capable candidate. A small ceiling restricts the
  *view*, not the toolchain: payloads live on the home and only executables
  mirror onto the exec root, so rust and clang install and compile on roots
  far smaller than their payloads (measured at 296MB free of a 488MB root).
  What does not fit is a view bigger than the root; the per-toolchain view
  costs are in `docs/architecture.md`, and an install that cannot fit names
  its measured need against the measured free space instead of failing
  mid-view. `gc` reclaims caches only, never views.

  **Harness scratch-quota kills bypass the df-based space gate (issue #63).**
  `doctor`, `space` and `report` read `df`, and no quota knob (`tmpSize`,
  `shmSize`, `fileMax`, `diskTmp`) is readable from inside: `/sys/fs/cgroup`
  limits do not exist here and the knobs have no signal. A quota kill arrives
  with gigabytes free on `df` and `doctor_failures=0`. What counts against
  scratch is everything a run writes: fetch shards, `SH_HOME_TMP`, caches,
  `go-bin`, `npm-global`, and every build artifact under the exec root (which
  is usually the scratch filesystem). `sandhome gc` reclaims sandhome's own
  caches; build output you own (`target/`, `GOCACHE`, staged tarballs) is
  removed by hand, found with `du -sh $SANDHOME_EXEC/* | sort -h | tail`.

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
  an absolute floor, because either alone is wrong. A pure share rule is
  nonsense at scale: measured on a 419GB disk at 6.6% free, 393GB was still on
  it and a share-only rule called that `low`, so `doctor` failed a freshly built
  home with 27GB free. A pure absolute rule is nonsense at the small end, which
  is why a root under `SANDHOME_PCT_MEANINGFUL_MB` (1GB) is judged on megabytes
  alone. So on a large root `low` means *both* under 10% free and under
  `SANDHOME_LOW_EXEC_MB`, which is the shape a genuinely draining root has: 40MB
  of 4TB is 0.001% free and cannot build anything.

  Every message names a command rather than only describing the state, because
  the value of hearing about it early is that there is still time to act.

When the home runs binaries and no separate root was named or recorded, the two collapse and nothing is copied. An explicit `--exec` (or a recorded root from one) always wins for payloads, views, caches and bins, and `space` reports `payloads=` read off disk so the plan and the state cannot disagree. When the roots do not collapse, a toolchain installs into the home and an **exec view** is mirrored onto the
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
| `--toolset NAME` | `minimal`, `cli`, `developer`, `project`, `languages`, `agent`, or `none` (no preset at all; pair with `--with`). What each carries is in the table below |
| `--with LIST` / `--without LIST` | add or drop toolchains by name |
| `--only LIST` | exactly these toolchains and nothing else: no preset, no auto-detection. Synonym for `--toolset none --with LIST`; space or comma separated |
| `--detect` | add the project markers even into an explicit request, which otherwise never auto-detects |
| `--list-toolchains` | print the known names |
| `--home DIR` / `--exec DIR` | override the roots. An option beats the environment variable of the same name. |
| `--no-shims` / `--require-shims` | do not build, or refuse without, the shims |
| `--no-shell` | do not install `errandsh` |
| `--no-profile` / `--no-path-line` | leave the login files alone |
| `--dry-run` / `--json` | preview (with per-toolchain `feas` lines and a `total_exec_need_mb` total), or one JSON report |
| `--doh-url URL` | DNS-over-HTTPS resolver for a confirmed no-resolver cage (see `SANDHOME_DOH_URL` in the reference). Off unless set. |
| | blocked origins: when plain downloaders fail for a non-DNS reason (a 403), mirror legs run before the failure message. `SANDHOME_MIRROR_URL` (default the pkgforge passthrough) carries any origin URL and is a second egress path; `SANDHOME_MIRROR_GH_URL` (default the API mirror) is an authenticated, read-only GitHub API proxy that serves `api.github.com` JSON at 5000/hour where a caller's IP gets 60/hour. API reads try the API mirror first and fall through to the passthrough (which was measured to carry api.github.com too), so an API read has two routes; downloads go through the passthrough, and a 420 (a path shape the API mirror does not serve, measured for release assets and raw) falls through rather than failing the fetch. Empty either base to opt out of its position. The pin still applies: mirrored bytes are the origin's bytes under another route (byte-identical, measured). |

The six toolsets, and the difference between them is the compilers:

| toolset | carries | copy-view MB (declared sum) |
| --- | --- | --- |
| `minimal` | `jq` | 8 |
| `cli` | `jq ripgrep fd` | 56 |
| `developer` | `jq ripgrep fd python node` | 286 |
| `project` | `developer` plus `go rust clang cmake meson ninja mold pkgconf perl` | 3766 |
| `languages` | `developer` plus `rust go zig deno bun mold clang cmake meson ninja pkgconf perl` | 4316 |
| `agent` | `developer` plus `deno bun yq gh shellcheck shfmt qemuuser mold ninja pkgconf perl` | 772 |

The sums are the declared copy-mode figures added up; launch mode costs less
per the per-toolchain table in `docs/architecture.md`, which owns every
figure here. `--dry-run` prices the actual request against the actual root
before spending anything.

`clang` is in `project` and `languages`, and is asked for by name otherwise:
`sandhome install clang` or `bootstrap.sh --with clang`. Its download is above
1GB and its tree wants ~16GB on the home root; in launch mode its exec view
is launcher copies, so a small exec root holds it. `agent` deliberately does
NOT carry clang, rust or zig: it is the runtime-and-CLI set an agent uses at
work, so the preset itself never pays for a compiler chain. Work-tree detection
can still fold one in (a `Cargo.toml`, `CMakeLists.txt` or `meson.build` in the
current tree), and `--no-detect` turns that off. `cmake`, `meson`,
`pkgconf` and `perl` ride with `project` and `languages`, and the C/C++ build
chain is folded in by work-tree detection (`CMakeLists.txt`, `meson.build`,
`configure.ac`) on any toolset, so a C/C++ checkout configures without
hand-assembling the chain. A toolchain already on
`PATH` is adopted, not downloaded; `SANDHOME_FORCE=1` (or a comma list of
names, or `sandhome install --force NAME`) installs locally regardless.

The run: detects the machine, plans the roots, adopts or installs each toolchain,
builds the shims this machine actually needs, writes `$SANDHOME_HOME/env.sh`,
installs `$SANDHOME_HOME/profile.sh` and the one line a login file reads,
installs the global hook (section 3), and prints a report **read from the
machine**  -  never from what was requested.

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

**The global hook is why the file is not sourced by hand.** The bootstrap puts
a dispatcher in **every** `PATH` directory that is writable and runs binaries
(six at most, and any one of them is enough), keyed on
`$0`, that sources `env.sh` and `exec`s the real binary from the exec root. A
new shell, including a non-login shell a harness spawns per tool call, finds
`sandhome` and every toolchain with nothing in front of the command. When the
only candidate is on a root that refuses `execve`, the directory is replaced by
a **symlink into the exec root**: the kernel resolves the link and permits
`execve` on the resolved root, which is the userspace route through the noexec
mount. Installation records each directory, how the dispatcher got there, and
what was there before, then verifies the result: every recorded directory is
run through a fresh `env -i` shell that has to print its marker back.

A run that names `--home`/`--exec` is isolated for the **login files**: it does
not touch `~/.profile` or the shell rc files unless `SANDHOME_LOGIN=1` asks.
**The global hook is not part of that isolation.** It is still installed (unless
`SANDHOME_GLOBAL=none` or `--no-global`), into a directory on the caller's real
`PATH`, and it bakes the named exec root. A throwaway root run with the hook left
on therefore repoints any previous hook at a root that will be removed, and
removing the root leaves a dead hook in every new shell. Name a persistent root,
or pass `--no-global` for a throwaway one.
`sandhome report` prints `global=on:<dir>` when a recorded directory answers
that shell, `global=stale:<dir>` when one was recorded and no longer does
(`doctor` fails on it and names the repair),`global=inside-exec-root:<dir>` when the hook was written into a directory this
tree uses as indirection (`$SANDHOME_EXEC/views/...` or the exec `bin`), which
`doctor` fails too - such a directory is on `PATH` only because `env.sh` put it
there, so a hook in it shadows that view's own tools with another view's names
(issue #149) - and
`global=none` when the host had no writable candidate; `sandhome global
--status` names every directory and its state,
`sandhome global` installs or repairs them, and `sandhome global --remove`
puts each entry back the way install found it: an empty directory comes back
as a directory, a dangling link as that link, an absent entry stays absent. A
refresh keeps a recorded directory even when the shell doing the refresh no
longer carries it on `PATH`. Installation is once; the hook serves every
future shell.

**The hook also carries the tools an operator installs after the setup.** A CLI
written by `npm install -g`, `uv tool install`, `go install` or `cargo install`
lives in a prefix on the exec root, and a fresh shell does not search it - so the
dispatcher puts those directories on the `PATH` of the tools it starts, and the
hook reads them from disk for its name list. One `sandhome global` after an
install is what teaches it a new CLI; a login shell is covered by the profile
fragment and a shell with no `PATH` at all by `entry.sh`, and the two together
cover the shells the dispatcher cannot (issue #138). Two kinds of directory are
refused outright and never become hook directories, whatever is in them: a
`bin` directory this tree created for another installer to write into,
because `npm i -g` writes **relative** links there and a redirect symlink
strands every one of them; and any directory under `$SANDHOME_EXEC/views`,
because a view bin is on `PATH` only because `env.sh` put it there, so a shell
that has sourced nothing cannot be served by it - taking one wrote a second
view's names into it (measured: `node`, `npm`, `npx` into the python view,
clashing with `uv`/`uvx`, so a sourced shell answered `command -v node` from the
python view). A directory on the exec root that this tree did **not** make is
still an ordinary candidate (issues #138, #149).

**A directory this tree PUT on PATH cannot be a hook directory, and the rule is
a mark, not a list.** `sh_global_skip_entry` refuses `$SANDHOME_EXEC/bin`,
`$SANDHOME_EXEC/global` and `$SANDHOME_EXEC/views/...` by name, and that list
is what let a defect through: the rust module added `$SANDHOME_EXEC/cargo-wrap`
and the rust fragment prepends it, and because the install and repair runs call
`sh_env_load` before `sh_global_install`, that directory was on `PATH`,
writable and exec-capable by the time the hook was planned, so the hook was
written into it and `report` printed `global=on:/workspace/sandexec/cargo-wrap`.
It served nobody, because the next session does not have it on `PATH`. It also
disabled the cargo target-dir wrapper, because the fragment's prepend is
guarded on the directory not already being on `PATH` (issue #176).

So a directory is marked inside itself, by `sh_env_mark_onpath`, at the point a
fragment puts it on `PATH`, and `sh_global_skip_entry` reads the mark off the
directory. A directory this tree invents next year is refused without anybody
remembering to add a name. A view is never marked: the mark would put a file
inside a tree the promote step mirrors, and the view is already refused by its
own path pattern. A neutral directory under the exec root that this tree did not
create and did not put on `PATH` is still a candidate, which is what keeps a
shell that sourced nothing serviceable (issue #185).

**The egress configuration is written down, because a proxy is a property of the
machine and not of the shell.** A sandbox that reaches the network only through
a proxy named in the environment loses the network the moment the environment is
scrubbed, and every cold path this project documents scrubs: `env -i
$SANDHOME_EXEC/bin/sandhome doctor`, `sh -c 'eval "$(sandhome env)"'`, a shell
with no `PATH` sourcing `entry.sh`, and above all the hook, which exists to
serve a shell that sourced nothing. On a proxy-only host measured here, from a
fresh hook-only shell, `curl` answered `000` for `nodejs.org`, `npm` answered
`getaddrinfo EAI_AGAIN`, `pip` answered "from versions: none" and `go` refused
the resolver; the same four commands with the variables carried through all
succeeded, which is what isolates the scrub rather than the registries as the
cause.

So the installing run records the eight variables curl and its relatives read -
`http_proxy`, `https_proxy`, `no_proxy`, `HTTP_PROXY`, `HTTPS_PROXY`,
`NO_PROXY`, `all_proxy`, `ALL_PROXY` - into `$SANDHOME_HOME/proxy.env`, and
`env.sh` also inlines them as guarded assignments, so a shell that has one
keeps its own. The dispatcher sources `proxy.env` as well as `env.sh`, because
it loads the environment for the **process it runs** and a child cannot change
its parent: a shell that typed `npm install` keeps an environment with no route
out no matter what `env.sh` says. A host with no proxy records no file at all,
rather than an empty one, and `sandhome report` prints `egress=direct` for it
and `egress=proxy:<names>` for one that has. `SANDHOME_DOH_URL` remains the
answer for a genuinely caged host and is unchanged by this; it is simply no
longer the only thing offered on a host that already had a working route
(issue #181).

**A rebuild keeps the egress, and a shell's own wins.** `sh_env_load` reads
`proxy.env` before anything else, so `sandhome resume` - which is reached
through `entry.sh` or by absolute path, and whose process has no proxy in it -
comes back with the egress the install had. Measured before the fix: after
`mv exec exec.wiped` and the documented `. entry.sh; sandhome resume`, `doctor`
was green with `doctor_failures=0` and every toolchain present, and `report`
printed `egress=unknown`: a machine that could not install a package. Each name
is applied only when the calling process does not already have one, so a shell
that exported a proxy for one build keeps it. A tool that is not one of the
hook's names - a `pip` inside a venv the operator created, say - is not
reachable by the hook, because the hook can only serve names it knows; run it
through `sandhome exec`, which applies the whole environment to whatever you
name.

```sh
sandhome version             # the schema version, and the cheapest way to prove the copy runs
sandhome global                    # where the hook is, and whether it is stale
. "$SANDHOME_HOME/env.sh"          # in a shell, when no hook is installed
eval "$(sandhome env)"             # without sourcing the file
sandhome env                       # to read it
sandhome path                       # the exec bin directory, for a script
sandhome exec CMD...               # run CMD with the environment already loaded
sandhome skills                     # what the setup installed for a harness
```

Two of those exist for scripts, and neither was documented until this was
noticed by looking for the reverse of what `tests/docs.sh` checks. That test
fails when a document names a command the code does not have, which is the
direction that bites a reader. It also now runs the other direction - every
dispatched command must be named in a document - because that gap was real:
`sandhome path` and `sandhome exec` sat in the dispatcher and in neither the
guide nor the router for as long as they existed, and the suite was green
throughout.

- `sandhome path` prints `$SANDHOME_EXEC/bin` and nothing else, so a script can
  extend `PATH` without parsing `env.sh`. A tool harness that wants the exec
  directory and is handed `sandhome` has no other way to learn it.
- `sandhome exec CMD...` loads the environment and `exec`s. It is the form for a
  caller that cannot source a file into its own shell, which is the same
  situation `eval "$(sandhome env)"` covers for a shell but not for a process
  that was not given one:

  ```sh
  sandhome exec make -j"$(nproc)"   # a build with GOCACHE and the tool bins set
  ```

  It replaces the `sh -c '. "$SANDHOME_HOME/env.sh" && ...'` incantation, which is
  what every caller wrote before this existed.

The installed profile fragment **loads `env.sh` for every login shell**, and only
the rest is interactive-only: the `PATH` de-dup, the history that survives the
session, and the move out of a mounted Windows drive in WSL are gated on `$-`
containing `i`, so a person typing at a prompt gets them and a tool that sends a
command to a login shell does not have them changed underneath it. It fetches
nothing, defines no alias or prompt, and is off in one switch
(`SANDHOME_NO_PROFILE=1`).

The environment is loaded first for a reason that was measured. `~/.profile`
carries one unconditional `export PATH="$SANDHOME_EXEC/bin:$PATH"` line, so a
**non-interactive login shell** - `bash -lc`, `sh -l -c`, the shape a tool
harness uses - got the exec bin first and never the roots. A launch-mode view
then resolved to its own copies, which cannot map themselves back without
`SANDHOME_EXEC`, and every one of them died with `cannot map this copy back to
its payload` while `doctor` reported zero failures (issue #131). The read is
done in a subshell whose assignments are kept only when it succeeded, so a
missing `HOME` cannot put a line on stderr in front of every command:

```sh
$ bash -lc 'echo $SANDHOME_EXEC'   # before: UNSET, after: the exec root
```

Note that `bash -lc` with an uppercase `C` reads no startup file at all, so it
shows nothing either way; a real login shell (`bash -lc`, with `HOME` set) is
the shape to measure with.

## 4. Adding a toolchain

Drop `tools/<name>.sh`. It declares:

```sh
TC_<name>_DESC='one line for sandhome toolchains'
TC_<name>_BINS='bin/tool'          # relative executables to expose
TC_<name>_REQUIRES='other'         # optional; ensured first
TC_<name>_EXEC_MB=32               # fresh-install exec need in MB, for the feas plan

tc_<name>_probe()   { ...; }       # 0 when a working copy is already here
tc_<name>_install() { ...; }       # install into $(sh_toolchain_root <name>)
tc_<name>_env()     { ...; }       # write the env fragment (optional)
tc_<name>_version() { ...; }       # print a version (optional)
tc_<name>_exec_mb()  { ...; }      # computed exec need, when it depends on the view mode (optional)
tc_<name>_copy_bins(){ ...; }      # executables that must stay REAL copies in launch mode (optional)
tc_<name>_doctor()  { ...; }       # health check the readiness gate runs (optional)
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

### Files larger than the file-size limit

A sandbox can pin a per-file cap (`ulimit -f`, RLIMIT_FSIZE) that no process can
raise  -  measured on one host at 1,000,000,000 bytes, where `curl` died with
`File size limit exceeded` on a 1.9GB asset. The figure is that host's reading,
not a constant: any pinned cap behaves the same way. A single file above the cap is
unreachable by construction, and resuming appends to a file already at the cap.

`sandhome` never makes one: when `Content-Length` exceeds the cap, `sh_fetch_stream`
fetches numbered ranges  -  each under the cap  -  and `sh_stream_untar` unpacks a
`.tar.*` from the concatenated stream. The digest is taken over the stream, so
verification is unchanged. `SANDHOME_FETCH_CHUNK_MB` sets the range size
(default 256, capped at three quarters of the limit). A `.zip` above the limit is
refused by name, because a zip's directory sits at the end and cannot be read as
a stream. `sandhome install clang` is the worked example: the x86_64 LLVM tarball
is about 1.9GB.

**The cap is per `write(2)`, not per download.** A tool that *generates* one
enormous file is cut off exactly like a download, and sharding does not apply
because there is no `Content-Length` to inspect and nothing to range over.
Measured: `wasm-dis index_bg.wasm -o out.wat` on a 35.4 MiB module (whose text
expansion is ~1 GB) dies with `File size limit exceeded` at the cap, on an exec
root with 61 GB free. The fix is to stream it and bound the consumer instead of
materialising one file: `wasm-dis index_bg.wasm 2>/dev/null | head -c 400000000
> out.wat`, or point the tool at a directory (`wasm-dis -d dir/`), or split its
output. Two 600 MB writes are fine; one 1.2 GB write is not, so "the file is
under the cap" is not the question for a program that writes incrementally.
`shard` applies to fetching only. `sandhome report` names the measured
`file_size_limit` when the host pins one, so an agent can plan around it instead
of discovering it by hitting it.

### Cross targets, and the linker rustc does not own

`SANDHOME_RUST_TARGETS` and `rustup target add` add a target's std, and for most
cross targets that is the whole story: `zig cc` (or the host linker) links it.
`wasm32-unknown-emscripten` is the exception, and it is the target Cloudflare's
Workers Rust toolchain uses. Its linker is `emcc`, a separate ~640MB toolchain
with its own LLVM, Binaryen and generated `EM_CONFIG`; `rustup target add`
succeeds, the build then dies with `linker 'emcc' not found`, and the message
reads like a broken `PATH` rather than a missing toolchain. The fix is four
things together: `rustup target add`, Emscripten installed and activated,
`EM_CONFIG` written (the sanity check runs without it and the link still fails),
and `CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=emcc`. `sandhome install
emscripten` provisions all four: it installs and activates emsdk (git clone
first, tarball through `sh_tar` second, so the uid-0 unpack abort in #162
cannot bite this path), writes `EM_CONFIG` beside the exec view with view
paths (a config pointing at the noexec home hands emcc native tools it cannot
run), and sets the cargo linker variable. Override the SDK release with
`SANDHOME_EMSDK_VERSION` (default 3.1.73). `--with emscripten` is
not in a toolset on purpose: it overlaps `zig` (a wasm target) and `qemuuser`
(another architecture), but neither gives Emscripten's `std::fs`/`epoll` surface
on the Workers event loop, and 900MB is a lot to carry for one target. The
tree's part today is both halves: `tools/rust.sh` says the
target list is not a link promise, `sandhome doctor` prints
`emscripten_linker` when a recorded target needs `emcc` and there is none, and
`tools/emscripten.sh` installs the toolchain that gate names.

`--with clang` is the one toolchain not in a toolset, because its view is large
(hundreds of MB) and it wants a roomy exec root; `deno`, `bun` and `mold` are in
the `languages` and `agent` toolsets, and `zig` is in `languages` only.

### qemu-user, shellcheck, and the long tail

Two modules cover needs the base set does not. `qemuuser` ships the static
user-mode emulators: the host one always (`qemu-x86_64` on x86_64), guests
only when asked through `SANDHOME_QEMUUSER_EXTRA` (a name like `aarch64` or
`qemu-aarch64`), because all 33 emulators are ~280MB of view for a machine
that will run one or two. A static guest runs from a noexec tree under its
emulator, and `qemu-x86_64 -strace` traces its syscalls with no ptrace at all
(~2x native against ~21x for system-mode TCG). `shellcheck` is the shell
linter as a single static binary, and the same binary `tests/syntax.sh` runs
over this tree when it is present.

### AppImages in a sealed sandbox

Portable artifacts build here end to end (measured: a hello-world AppImage
via `quick-sharun.sh` in 16s), but the cage changes five assumptions of the
upstream HOW-TO-MAKE-THESE guide:

- Skip the `/usr` and `pacman` steps. There is no write access to `/usr` and
  no package DB; build the app straight into `AppDir/bin` instead.
- Keep `ICON` and `DESKTOP` outside `AppDir`. A path inside it fails with
  `cp: 'X' and 'X' are the same file`.
- No FUSE here (`/dev/fuse` absent, measured), so every AppImage runs via
  `--appimage-extract-and-run`. That fallback working is expected, not a
  broken artifact.
- No `xvfb-run`, so GUI dlopen verification is skipped: `quick-sharun`
  warns once and continues, which means a GUI AppImage built in the cage is
  **unverified** for runtime-dlopened libraries. That caveat is the single
  most important thing to carry out of the build.
- Build on the exec root (a `sandhome project` dir), because deployment
  downloads and the whole AppDir land wherever they run: tens of MB for a
  hello-world, hundreds for GTK/Qt/OpenGL, all against the same exec
  ceiling as everything else (see section 7).

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

Seven `LD_PRELOAD` interposers, each built only when the machine needs it, and
none of them all-purpose: `sh_shim_need` names the detector that decides, so a
shim is present exactly when its answer is missing and a machine that already
has the thing does not carry it.

Three answer for a cage with no kernel support at all:

- **`fakepty`**  -  a USERSPACE pty. It makes the session's descriptors look
  like a terminal (isatty, termios, window size, `/dev/tty`) where there is no
  `/dev/ptmx`, so readline, echo and full-screen programs work over a pipe.
- **`fakepwd`**  -  answers `getpwnam`/`getpwuid` from a synthetic database, for a
  cage with no `/etc/passwd`. It reads `$SANDHOME_PASSWD`; `env.sh` exports it.
- **`antiptrace`**  -  lets a program that self-checks with
  `ptrace(PTRACE_TRACEME)`, or reads `TracerPid` from `/proc/self/status`,
  run on a host whose seccomp profile denies the ptrace syscall class. The
  detector (`ptrace=yes|no|partial|unknown` in the report) sends a bogus
  request too, which tells a seccomp filter (refuses before looking) apart
  from YAMA/LSM (refuse after validating). `TRACEME` is answered with
  success; `TracerPid` and `wchan` are zeroed on `open`/`open64`/`openat`/
  `openat64` reads handed back through a memfd. It cannot make a ptrace-based
  tracer work (the filter runs before libc), and glibc-internal opens
  (`fopen`) never cross the PLT, so no shim shaped like this one sees those.
  `SANDHOME_ANTIPTRACE_TRACEME`, `SANDHOME_ANTIPTRACE_STATUS` and
  `SANDHOME_ANTIPTRACE_WCHAN` switch the behaviours off separately (`=0`).

All seven are built into `$SANDHOME_HOME/shims/`. `env.sh` puts them in `LD_PRELOAD`
only when `SANDHOME_SHIMS` is set to something other than `0`. `fakepty` is no
longer a blanket `isatty()==1`: `env.sh` also exports `SANDHOME_FAKEPTY_ID`, the
readlink identity of the session's own descriptors, and only THOSE are faked. A
pipe opened later is a new object and stays a pipe, so `jq -n 1 | cat` does not
put ANSI codes into `cat`. Without the variable the older fds 0-2 behaviour is
kept.

`shell/faketty` is the caller-facing half: it sets that id, the window size, a
usable `TERM` and `LD_PRELOAD`, then `exec`s, so a subshell the command starts
inherits the terminal. `sandhome pty CMD` and errandsh's foreground mode both go
through it.

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

### Headless hardware and GUI tests

Three layers, in the order to reach for them. `env.sh` exports
`XDG_RUNTIME_DIR` on the exec scratch (0700) when no valid one exists, which
removes the first error of every headless GL/EGL/Wayland tool.

First, the toolkits' own null drivers -- no shim, and preferred wherever one
exists:

| stack | lever | values |
| --- | --- | --- |
| SDL2 video | `SDL_VIDEODRIVER` | `dummy`, `offscreen` |
| SDL2 audio | `SDL_AUDIODRIVER` | `dummy` |
| Mesa GL | `LIBGL_ALWAYS_SOFTWARE` | `1` (real software rasterisation where `swrast`/`llvmpipe` is present -- actual pixels, better than any fake) |
| EGL | `EGL_PLATFORM` | `surfaceless`, `device` |
| Qt | `QT_QPA_PLATFORM` | `offscreen`, `minimal`, `vnc` |

Second, the enumeration shims, for surfaces with no null mode. They make
initialisation stop failing at the open or the probe; none of them renders:

| shim | answers | scope switch |
| --- | --- | --- |
| `fakedrm` | opens/stats under `/dev/dri`, `/sys/class/drm` | `SANDHOME_FAKEDRM=0` |
| `fakeinput` | opens/stats under `/dev/input`, `/dev/uinput` | `SANDHOME_FAKEINPUT=0` |
| `fakexenv` | `XOpenDisplay` and client probes (one screen, fixed extension base) | `SANDHOME_FAKEXENV=0` |
| `fakedisplay` | `wl_display_connect`, registry | `SANDHOME_FAKEDISPLAY=0` |

Each is built only when the machine needs it (no `/dev/dri`, no input
devices, no `DISPLAY`/`WAYLAND_DISPLAY`) and loads with `SANDHOME_SHIMS=1`
like the rest. That is four of the seven: the three above plus these, so
"three interposers" undercounts the tree by design. Not built: audio shims
(`SDL_AUDIODRIVER=dummy` covers SDL; raw ALSA callers have no lever, but faking
samples is a different category from faking enumeration), sysfs sensors, and
deterministic RNG -- each is a project of its own, not a probe answer.

Third, the hard limits, stated so no test pretends past them: no display
server can exist here (bind is denied, so no in-cage Xvfb -- a client-side
fake is the only X/Wayland option, and it cannot draw), no FUSE (every
AppImage runs via `--appimage-extract-and-run`), and no real GPU (only
enumeration; pixels come from software rasterisation or not at all).

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
nothing to interpose into.

The list of programs `ERRANDSH_PTY_PROGRAMS` auto-runs in the foreground, and
the rest of that session's variables, are in
`skills/errandsh/SKILL.md`. `SANDHOME_FAKEPTY_SIZE` (`COLSxROWS`) is documented
here, because the guide pointed at the reference for it and the reference does
not carry it:

| variable | meaning | default |
| --- | --- | --- |
| `SANDHOME_FAKEPTY` | the `fakepty.so` to preload; `faketty` finds it under the home | the shim this build wrote |
| `SANDHOME_FAKEPTY_SIZE` | the window size a full-screen program is told | `COLUMNSxLINES` when it is unset, then 80x24. When it **is** set it wins outright and `COLUMNS`/`LINES` are not consulted |
| `SANDHOME_FAKEPTY_ID` | which descriptors count as the terminal | set by `env.sh` and `faketty`; unset, the feature is off |
| `SANDHOME_FAKEPTY_CRLF` | `0` stops `\n` becoming `\r\n` on output | on, which is what a terminal with `OPOST\|ONLCR` does |
| `SANDHOME_FAKEPTY_TERM` | the `TERM` a full-screen program is told when the caller's is unset, empty, `dumb` or `unknown` | `xterm-256color`. Only an unusable value is replaced, so a real `TERM` is never overwritten |

A full-screen program lays out to this size once and does not ask again, so it
has to be right before the program starts. Set it when a program is told 80x24
and the terminal is not:

```sh
SANDHOME_FAKEPTY_SIZE=120x40 sandhome pty less big.log
```

## 7. Troubleshooting

| symptom | first thing to read |
| --- | --- |
| a tool "installed" and is not found | `sandhome space --probe`; the toolchain may have landed on a root that does not run it |
| a tool is on PATH but a shell that inherited nothing cannot find it | it was adopted, not installed, and its binary could not be linked into the exec view; `sandhome repair <name>` retries the link, and `sandhome install --force <name>` puts a copy there when the adopted binary cannot be linked at all |
| `Permission denied` running a binary | the home is noexec and the exec view was not built  -  run `sandhome repair <name>`, which rebuilds the view and downloads nothing. `install` is the command that adopts and downloads, and on an adopted toolchain it is what broke the view, so routing the diagnosis through it reproduced the defect 8 times out of 8 (#49) |
| `Too many levels of symbolic links` on a binary | the view links a tool to itself; `sandhome repair <name>` rewrites the link |
| `fork/exec ... permission denied` after a successful `go build` | the Go build cache landed on a noexec root; re-run the install so `GOCACHE` is written to `SANDHOME_EXEC` |
| `go install` binary neither runs nor is on PATH | `GOBIN` now points at `$SANDHOME_EXEC/go-bin` and is on PATH; re-run `sandhome install go`, then `go install`. Build output in a noexec work tree still will not run: build under `$SANDHOME_EXEC` |
| `npm i -g` CLI not found or `bad interpreter` | the prefix lives on `$SANDHOME_EXEC/npm-global` with `bin` on `PATH`; re-run `sandhome install node`. **A CLI installed after the setup is found by a shell that sourced nothing as soon as the installer returns**: the dispatcher runs `npm`/`npx`/`go`/`cargo`/`uv` as a child and links every new executable into the hook (issue #142), so the normal installers need no manual `sandhome global`. A CLI copied in by other means still needs one `sandhome global`; a login shell finds it immediately. Project-local `.bin` on a noexec checkout has the same cause: run the project from `$SANDHOME_EXEC` |
| `npm i -g` CLI exists but cannot be run (`sh: cowsay: not found` with the link present) | a directory this tree created for an installer to write into was taken as a hook directory, so the RELATIVE link `bin/cowsay -> ../lib/node_modules/...` resolved against the hook instead of the prefix (issue #138). `sandhome global` moves our own link out, restores the directory and rescues the stranded links |
| `cargo` or `rustc` answers `error: command failed: 'cargo': Permission denied (os error 13)` from a fresh shell but works in a sourced one | rustup's proxies resolve the toolchain under `$RUSTUP_HOME`, which on a split root is the mount that refuses `execve`. The exec-bin entries now point at the real toolchain binaries and the proxies are rewritten on every repair; if the view predates that, run `sandhome repair rust` (issue #135) |
| `rustc.real: Argument list too long` | the sysroot wrapper exec'd itself because its `.real` was a damaged copy. `sandhome repair rust` rebuilds the pair from the home compiler (issue #135) |
| `rustc` answers from a sourced shell and a browser or bundler still dies with `spawn /memfd:sandhome (deleted) ENOENT` | the node view is a launcher, so `process.execPath` is a path that no longer exists. `node`, `deno` and `bun` are real copies now; `doctor` fails with `toolchain_node_spawn` when they are not (issue #139) |
| a login shell (`bash -lc`) dies with `cannot map this copy back to its payload` | the shell resolved the exec bin before the environment was loaded. The profile fragment now loads `env.sh` for every login shell; re-run the setup once to rewrite it, or `. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh"` for the shell in hand (issue #131) |
| `env -i $SANDHOME_EXEC/bin/sandhome doctor` cannot find the library | the bake and the home pointer both name a checkout or a home that is gone. The copy keeps its own library in `$SANDHOME_EXEC/.sandhome-lib`; re-run the setup or `sandhome repair` once to write it (issue #133) |
| `collect2: posix_spawnp: Permission denied` linking rust | the sysroot linker is on the noexec home, so it cannot be exec'd at all. A `-fuse-ld=` flag does not fix it: rustc appends its own `-fuse-ld=lld` and `-B<sysroot>` after any `-C link-arg`, so the last one wins. `sandhome install --force rust` installs a toolchain whose data lives on the home and whose executables run from the exec view, where a plain `rustc -O hello.rs -o out` links and runs with no `RUSTFLAGS` |
| the working tree itself is noexec | `sandhome doctor` prints a note naming `$SANDHOME_EXEC`; build and run output there, not in the checkout |
| a project needs a venv, npm, or native CLIs on a noexec checkout | one command does the whole dance: `sandhome project NAME [--python|--node]` creates `$SANDHOME_EXEC/projects/NAME`, links `./NAME` to it, and sets up the venv and the npm project inside, so console scripts, `npx` and native CLIs run where they stand. A tmpfs exec root does not survive a restart; re-running the command rebuilds it |
| a per-project `.venv` half-works: `python -m` runs, every console script says `bad interpreter: Permission denied` | the venv is on a noexec checkout, and each console script's shebang is an absolute path into it. `uv venv` has already made the symlink, which is why python itself works. Put the venv on the exec root: `uv venv "$SANDHOME_EXEC/venvs/NAME" && uv pip install --python "$SANDHOME_EXEC/venvs/NAME/bin/python" PKG` (#42) |
| `npm install` exits 0 and `./node_modules/.bin/CLI` says `bad interpreter: Permission denied` | same cause: the shebang is `/usr/bin/env node` resolved through a noexec tree. `node node_modules/CLI/index.js` works only for a pure-JS CLI, because node reads the file rather than exec'ing it (#42): a CLI that ships a native payload (`@typescript/typescript-linux-x64`, `@esbuild/*`, `sharp`) then dies with `spawnSync .../node_modules/... EACCES`, which is the same noexec refusal one level down, not a missing dependency. For the normal project commands (`npm run`, `npx`, `.bin/CLI`), and always for a native payload, put the project itself on the exec root and symlink it back: `mkdir -p "$SANDHOME_EXEC/jsproj" && ln -s "$SANDHOME_EXEC/jsproj" ./jsproj`, then work in `./jsproj` (#58). Symlinking only `node_modules` does not survive `npm install`, which replaces the symlink with a real directory. A tmpfs exec root does not survive a restart |
| no echo / no line editing over ssh | the shims are not loaded; `SANDHOME_SHIMS=1` and restart the shell |
| an ssh login is refused with `publickey` | the login name is absent from the synthetic passwd; set `SANDHOME_PASSWD_USERS` |
| a full-screen program runs in batch mode | it is statically linked (nothing to interpose into), or `faketty` is not built. `sandhome pty CMD` forces the userspace pty; `sandhome shims build` builds it |
| `File size limit exceeded` on a download | `ulimit -f` pins a per-file cap; sandhome shards any download whose `Content-Length` exceeds it and unpacks a `.tar.*` from the stream. `SANDHOME_FETCH_CHUNK_MB` tunes the range size. A `.zip` above the cap is refused by name |
| `File size limit exceeded` while a tool **writes** one file | the cap is per `write(2)`, so a disassembler's multi-GB `.wat`, a core dump, or a huge unpack is cut off the same way a large download is, and `shard` cannot help (the tool is generating, not fetching). Stream it and bound the consumer (`tool ... \| head -c N > out`), point it at a directory where it supports one, or split the output. See section 2 |
| an adopted `rustup target add` prints `Read-only file system` and exits 0 | the adopted `RUSTUP_HOME` cannot take a write, so no target can be added to any toolchain and a later build dies with a missing std. `sandhome install rust` points `RUSTUP_HOME` at a writable root on the exec root with the toolchains linked in and `doctor` reports `rustup_writable` (#159) |
| a third-party SDK installer aborts with `Cannot change ownership` / `tar` exit 2 / `installation failed` | its `tar -xf` has no `--no-same-owner` and the archive carries a foreign uid; the download is fine and the unpack is not. `env.sh` exports `TAR_OPTIONS=--no-same-owner` as a guarded default so those installers unpack as the caller with no patching, and `doctor` reports `tar_no_same_owner` while the live shell lacks it; this tree's `sh_tar` in `lib/fetch.sh` stays the unpack path for its own fetches (#162) |
| `mold` is on PATH but `-fuse-ld=mold` cannot find it | the mold archive ships both `mold` and `ld.mold`; both land on the exec bin. Check `command -v ld.mold`. Clang accepts `--ld-path=$(command -v mold)` as well |
| `cargo build --target <T>` dies with `linker '<name>' not found` | the target's std is present and its linker is not. For `wasm32-unknown-emscripten` the linker is `emcc`: run `sandhome install emscripten`, which provisions it on the exec view, writes `EM_CONFIG` with view paths, and sets `CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=emcc`. `sandhome doctor` prints `emscripten_linker` while it is missing (#163). Any other `<name>` is a real missing PATH entry |
| `doctor` says `FAIL exec_space=low` or `=critical` | the exec root is draining. `sandhome space` names the state and the numbers, `sandhome space --probe` lists roomier candidates, `sandhome space --largest` names the entries holding the space, `sandhome gc` reclaims sandhome's own caches, and re-running the setup with `--exec DIR` moves everything to a roomy path. See section 1 for the thresholds |
| the exec root filled | `sandhome gc` prints the entry count with the bytes reclaimed; staging (any age, `$SH_HOME/.staging` and `$SH_EXEC/.staging`), exec caches (`cache/`, `tmp/`, `node-gyp-tmp-*` entries older than DAYS; `gc 0` or `gc --now` removes them however old except a live install's hold and entries changed in the last 30 minutes), and home tmp older than DAYS are removed, toolchain data stays. What a live install holds survives even `gc 0` (`SANDHOME_GC_FORCE=1` overrides), and `go install` output in `go-bin` is not a cache: `gc` no longer removes it, nor anything else under the installer roots (`npm-global`, `uv-bin`, `cargo-install`) (issue #141). Views are never reclaimed: stale view entries go with `sandhome prune`, views are rebuilt by `sandhome repair`, not by `gc` (#67). `gc` returning 0 bytes on a full root means the space is in build output you own or in views, so `sandhome space --largest` names it first with one tag per entry (`reclaim` = gc removes it, `sandhome` = the tree owns it and gc keeps it, `yours` = remove it yourself; `space --reclaim` prints the cache bytes `gc --now` would free). `GOCACHE`, `GOBIN`, `NPM_CONFIG_PREFIX`, `CARGO_INSTALL_ROOT`, `CARGO_TARGET_DIR`, and `target/` all land on the exec root: heavy and multi-target builds need a roomy `--exec DIR`. If no candidate fits, the install names the constraint before writing anything |
| an ASan/UBSan binary prints nothing and exits 1 (`LeakSanitizer has encountered a fatal error`) | LSan stops threads with `ptrace`, which this cage denies, and loses the programme's buffered stdout with it; `env.sh` sets `ASAN_OPTIONS=detect_leaks=0` and `LSAN_OPTIONS=detect_leaks=0` for every ptrace answer except a measured `yes`, so an unmeasured host gets the workaround too and ASan and UBSan keep working. A caller who sets either keeps theirs; `SANDHOME_ASAN=off` restores leak checking where it works. Use clang for a sanitizer build: `zig cc` ships no `libasan`/`libtsan`, while clang's own runtimes live under its resource dir (issue #144) |
| a headless browser is `Permission denied`/`EACCES` after a successful install, or `bind() failed`/`Cannot start http server for devtools` | the browser cache defaulted to `$HOME/.cache`, the mount that refuses `execve`; `env.sh` points `PUPPETEER_CACHE_DIR` at `$SANDHOME_EXEC/puppeteer` and `PLAYWRIGHT_BROWSERS_PATH` at `$SANDHOME_EXEC/ms-playwright`, and `doctor` fails while either points elsewhere. Launch with `--no-sandbox` and puppeteer's `pipe: true`: a listener cannot bind here (issue #143) |
| `npm install puppeteer` succeeds and the launch says Chrome is missing | the bundled npm blocks lifecycle scripts by default, so the postinstall that fetches Chrome never runs; approve it explicitly: `npm install-scripts approve puppeteer` (then reinstall). The same policy skips `node-gyp rebuild` for native addons: prefer a prebuilt, or approve the package the same way (issue #143) |
| a tool is on PATH but its file is gone | the payload was deleted while its view entry survived; every reinstall leaves it because the mirror only adds. `sandhome prune <name>` drops view entries whose payload is gone, downloading nothing (#110) |
| the exec root was cleared by a restart | the tmpfs exec view is gone while `env.sh` persists; re-run the setup, then run `sandhome repair` only if `doctor` still fails. Re-running the setup rebuilds the view on its own (measured); never run `install <name>` here, it re-runs the adopt path that broke 8 views in 8 rounds (#49, #43) |

## 8. The report

`sandhome report` prints one `key=value` per line, and `--json` one object. It is
read from probes: `pty`, `passwd`, `home_exec`, per-toolchain versions, and
`failures`. `sandhome doctor` is the pass/fail view of the invariants a working
home must satisfy.
