# Reference

GENERATED. Do not edit. `sh docs/generate-reference.sh > docs/reference.md`
rewrites it, and `sh tests/docs.sh` fails when the two differ. Every line
below is extracted from the code that implements it.

## Commands

```
usage: sandhome COMMAND [args]

  doctor                 probe the environment and report what is missing
  doctor --json          the same gate as one JSON object
  status [--json]        one-line readiness: roots, view, toolchains, next
  resume                 rebuild the views after a tmpfs restart, then doctor
  env                    print the environment, for `eval "$(sandhome env)"`
  path                   print the exec-view bin directory
  global [--status|--remove]   install the global hook: every usable
                         directory on PATH loads the environment for a fresh
                         shell, so setup is once and no command needs
                         `. env.sh`. --status reports each entry and a
                         fresh-shell probe, --remove restores them.
  space [--probe]        where the two roots are, and every candidate tried
  space --largest [N]    the N biggest entries on the exec root (default 10)
  space --reclaim        reclaimable cache bytes without removing anything
  toolchains             name, one-line description, PATH binaries, versions
  skills                 where the skills are installed, one line per skill per
                         location, with the origin (this tree's copy, a link
                         into the checkout, or something else that was left
                         alone). Exits non-zero when none is installed
  install NAME...        adopt or install each toolchain, then write the env
  install --only NAMES   install exactly these and replace the recorded request
  install --with NAMES   add to the request and install it (comma list)
  install --without NAMES  drop from the request; alone, it records only
  install --force NAME   install NAME even when a working copy is on PATH
  install rust --target T   add rust cross targets (comma list, repeatable)
  install qemuuser --extra A  also install guest emulators (comma list)
  ensure NAME...         alias for install
  repair [NAME...]       rebuild the exec view and launchers, downloading
                         nothing. The fix for "Permission denied" on a tool
                         that is already installed or adopted. No names means
                         every toolchain sandhome knows.
  add NAME --url URL    fetch one asset as a new toolchain into the durable
                         local directory and install it. --sha256 pins it,
                         --bin names the executable inside an archive,
                         --scaffold-only writes the module without installing.
  shims [build]          build the LD_PRELOAD shims this machine needs
  test                   run this checkout's whole test suite
  selftest               the checks that need this machine and no network
  selftest shims         build and exercise the LD_PRELOAD shims
  selftest exec          the noexec-home end-to-end: install, promote, run
  shell [args]           run errandsh, the line discipline with a userspace pty
  project NAME [--python|--node]   a project that runs on a noexec work tree:
                         creates it on the exec root, links ./NAME to it,
                         and sets up the venv and npm project inside
  pty CMD...             run CMD with a userspace pty (no /dev/ptmx needed)
  exec CMD...            run CMD with the sandhome environment loaded
  exec-dir               print the exec-capable root (where build output runs)
  report [--json]        the full report
  gc [DAYS] [--dry-run]   remove staging and caches older than DAYS (default 7).
                         DAYS=0 (or --now) removes everything sandhome owns
                         in its caches however old, except what a live
                         install holds and what changed in the last 30 minutes
                         (SANDHOME_GC_FORCE=1 overrides both).
                         Views are never removed; `repair` rebuilds them.
                         Prints the entry count and the bytes reclaimed.
  prune [NAME...]        drop exec-view entries whose payload is gone.
                         No names means every toolchain sandhome knows.
  version                print the schema version
  help [CMD]             this text, or the help for CMD

Environment:
  SANDHOME_HOME   the persistent data root (default $XDG_DATA_HOME/sandhome)
  SANDHOME_EXEC   the exec-capable root; detected when unset
  SANDHOME_REPO   owner/name to fetch when run from a pipe (default
                  talaria0101/sandhome). The checkout that holds lib/ is named
                  by SANDHOME_REPO_DIR, which env.sh sets.
  SANDHOME_SHIMS  set to 1 to put the shims in LD_PRELOAD
  SANDHOME_PASSWD_USERS   extra names for the synthetic passwd database
  SANDHOME_SHA256 a default digest for downloads with no pin of their own.
                  Prefer SANDHOME_SHA256_<NAME> (the toolchain, upper-cased)
                  or SANDHOME_SHA256_<ASSET> (the url's last path segment,
                  upper-cased, no extension, hyphens as underscores), which
                  apply to one download. Resolution order: <NAME>, <ASSET>,
                  a digest the publisher published, then this.
  SANDHOME_REF    branch or tag the pipe bootstrap fetches. Default main
  SANDHOME_REPO_DIR   the checkout the installed copy of this command reads.
                      Set by env.sh; read it, do not set it.
  SANDHOME_MIN_EXEC_MB  free megabytes an exec candidate must have to be
                      preferred. Default 128
  SANDHOME_LOW_EXEC_MB  free megabytes below which the exec root is called low
                      and doctor fails. Default 100
  SANDHOME_CRIT_MB   free megabytes below which the exec root is called
                      critical. Default 32
  SANDHOME_LOW_EXEC_PCT  percent FREE below which a large exec root is low.
                      Default 10
  SANDHOME_PCT_MEANINGFUL_MB  exec root size under which the megabyte rules
                      decide and the percentage is ignored, because 10% of a
                      40MB root is 4MB. Default 1024
  SANDHOME_REQUIRE_DIGEST  1 refuses a download when no sha256 tool exists
  SANDHOME_DOH_URL    DNS-over-HTTPS resolver, e.g. https://1.1.1.1/dns-query.
                      Unset, and the fallback is off until it is set. Used
                      only after curl answers exit 6 twice.
  SANDHOME_GO_VERSION_URL, SANDHOME_GO_DL_JSON_URL, SANDHOME_NODE_INDEX_URL
                      point a version or digest parser at a mirror, so the
                      parsers can be tested offline
  SANDHOME_RUST_TARGETS   comma list of rust cross targets to add on install
                      (same as install rust --target T)
  SANDHOME_FORCE      install toolchains locally even when the host already
                      carries a working copy, which is otherwise adopted.
                      1 (or all) forces every requested toolchain; a comma
                      list forces the names in it. Same as install --force.
  SANDHOME_ZIG_VERSION    pin the zig release (default latest from index)
  SANDHOME_ZIG_INDEX_URL  point the zig version parser at a mirror for tests
```

## bootstrap.sh flags

```
usage: sh bootstrap.sh [options]

  --toolset NAME      minimal | cli | developer | project | languages | agent,
                      or none for an empty base. Default developer.
  --only NAME[,NAME]  exactly these toolchains and nothing else: an empty
                      base plus the names, no auto-detect, no preset. Takes
                      several words too (--only jq ripgrep). Same as
                      --toolset none --with NAME...
  --with NAME         add a toolchain. Repeatable, and also takes a
                      comma-separated list.
  --without NAME      leave a toolchain out. Repeatable, and also takes a
                      comma-separated list.
  --no-detect         do not add toolchains implied by project markers in the
                      working directory (Cargo.toml, go.mod, package.json, ...)
  --detect            add the implied project markers even into an explicit
                      --only/--toolset none request, which otherwise never
                      auto-detects. With a preset toolset this is the default.
  --list-toolchains   print the known names and exit
  --home DIR          persistent data root. Default $XDG_DATA_HOME/sandhome
  --exec DIR          exec-capable root. Default: detected (see sandhome space)
  --no-shims          do not build the LD_PRELOAD shims
  --require-shims     refuse to finish when a needed shim could not be built
  --no-shell          do not install errandsh
  --no-skills         do not install the skills into ~/.agents/skills
  --no-profile        do not install the profile fragment or touch login files
  --no-path-line      do not add the exec bin directory to the login files
  --no-global         do not install the global hook (a directory already on
                      PATH that loads the environment for a fresh shell)
  --login             with --home/--exec, still install the login files
                      (same as SANDHOME_LOGIN=1)
  --dry-run           print what would be done and change nothing
  --json              print the report as one JSON object
  --doh-url URL       DNS-over-HTTPS resolver for a confirmed no-resolver
                      cage, e.g. https://1.1.1.1/dns-query. Off unless set;
                      used only after curl answers exit 6 twice (see
                      SANDHOME_DOH_URL below).
  --version           print the schema version (sandhome/1) and exit
  -h, --help          this text

  SANDHOME_REPO       owner/name to fetch when run from a pipe.
                      Default talaria0101/sandhome.
  SANDHOME_REF        branch or tag to fetch. Default main. Export it before
                      the pipe, or set it on the sh side
                      (curl ... | SANDHOME_REF=X sh -s -- ...): a VAR=value
                      prefix on curl never reaches the piped sh.
  SANDHOME_FORCE      install toolchains locally even when the host already
                      carries a working copy, which is otherwise adopted.
                      1 (or all) forces every requested toolchain; a comma
                      list forces the names in it (SANDHOME_FORCE=rust,go).
                      Same placement rule as SANDHOME_REF. `sandhome install
                      --force NAME` is the same decision per command.
  SANDHOME_GLOBAL     install the global hook (default install). 0 (or
                      --no-global) skips it, which is what a test suite
                      wants and what a host whose PATH directories are not
                      the caller's to write wants.
  SANDHOME_VIEW_MODE  copy forces real-copy views (`/proc/self/exe` stays a
                      real path, at the price of exec-root room); launch
                      demands the memfd helper with a copy fallback; empty or
                      anything else decides per machine. Same placement rule
                      as SANDHOME_REF.
  SANDHOME_SHA256     a default digest for any download that has no pin of its
                      own. Same placement rule as SANDHOME_REF: export it or
                      set it on the sh side. Prefer the per-download forms below, which do not
                      apply to a download the caller did not name.
  SANDHOME_SHA256_<NAME>    pin one toolchain, e.g. SANDHOME_SHA256_RIPGREP.
                      <NAME> is the toolchain name, upper-cased.
  SANDHOME_SHA256_<ASSET>   pin one url asset, e.g.
                      SANDHOME_SHA256_JQ_LINUX_AMD64. <ASSET> is the url's
                      last path segment, upper-cased, without its extension,
                      with hyphens written as underscores.
                      Resolution order per download: <NAME>, then <ASSET>, then
                      a digest the publisher published, then SANDHOME_SHA256.
                      See docs/decisions/pinning.md.
  SANDHOME_DOH_URL    DNS-over-HTTPS resolver, e.g. https://1.1.1.1/dns-query.
                      Unset, and the fallback is off until it is set. Used
                      only after the system resolver fails twice with curl
                      exit 6; the retry pins the resolver by IP literal so it
                      cannot itself need DNS.
  SANDHOME_MIRROR_URL Mirror base tried once when plain downloaders fail for
                      a non-DNS reason, e.g. a 403-blocked origin. Default
                      https://api.rv.pkgforge.dev/ (the origin URL is appended).
                      Empty opts out. The pin still applies: mirrored bytes are
                      the origin's bytes under another route.
  SANDHOME_MIRROR_GH_URL
                      Same, for https://api.github.com/ paths. Default
                      https://api.gh.pkgforge.dev/. Empty opts out.
```

## Toolsets

| name | toolchains |
| --- | --- |
| `minimal` | jq |
| `cli` | jq ripgrep fd |
| `developer` | jq ripgrep fd python node |
| `languages` | jq ripgrep fd python node rust go zig deno bun mold clang cmake meson ninja pkgconf perl |
| `agent` | jq ripgrep fd python node deno bun yq gh shellcheck shfmt qemuuser mold ninja pkgconf perl |
| `project` | jq ripgrep fd python node go rust clang cmake meson ninja mold pkgconf perl |

## Environment variables

| variable | read by | default |
| --- | --- | --- |
| `SANDHOME_ASAN` | env.sh | `on` |
| `SANDHOME_BIN_DIR` | bootstrap.sh sandhome | `$SH_REPO_DIR/bin` |
| `SANDHOME_CARGO_TARGET_DEFAULT` | env.sh rust.sh | `$CARGO_TARGET_DIR` |
| `SANDHOME_CMAKE_VERSION` | cmake.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_CRIT_MB` | space.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_DOH_CANARY` | fetch.sh | `https://github.com` |
| `SANDHOME_DOH_URL` | env.sh fetch.sh bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_EMSDK_VERSION` | emscripten.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_EXEC` | common.sh env.sh profile.sh report.sh space.sh bootstrap.sh sandhome bun.sh cmake.sh deno.sh emscripten.sh fd.sh go.sh jq.sh meson.sh node.sh python.sh ripgrep.sh rust.sh zig.sh | `*)` |
| `SANDHOME_FAKEPTY` | env.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_FAKEPTY_ID` | env.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_FETCH_CHUNK_MB` | fetch.sh | `256` |
| `SANDHOME_FETCH_DIR` | bootstrap.sh | `$SH_FETCH_DIR` |
| `SANDHOME_FORCE` | toolchain.sh bootstrap.sh sandhome rust.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_GC_FORCE` | space.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_GH_VERSION` | gh.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_GLOBAL` | env.sh bootstrap.sh | `install` |
| `SANDHOME_GO_DL_JSON_URL` | sandhome go.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_GO_VERSION_URL` | sandhome go.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_HERE` | profile.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_HOME` | env.sh profile.sh space.sh bootstrap.sh sandhome emscripten.sh go.sh node.sh python.sh rust.sh | `$SH_BAKED_HOME` |
| `SANDHOME_LLVM_TAG` | clang.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_LOGIN` | bootstrap.sh | `0` |
| `SANDHOME_LOW_EXEC_MB` | space.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_LOW_EXEC_PCT` | space.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_MESON_LIB` | meson.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_MIN_EXEC_MB` | space.sh sandhome | `128` |
| `SANDHOME_MIRROR_GH_URL` | fetch.sh bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_MIRROR_LIB` | env.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_MIRROR_URL` | fetch.sh bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_MOLD_VERSION` | mold.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_NODE_INDEX_URL` | sandhome node.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_NO_PROFILE` | profile.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_NO_REFETCH` | bootstrap.sh | `1` |
| `SANDHOME_NO_RUN` | bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_PASSWD` | env.sh shim.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_PASSWD_USERS` | shim.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_PCT_MEANINGFUL_MB` | space.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_PKGCONF_VERSION` | pkgconf.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_PROFILE` | profile.sh | `1` |
| `SANDHOME_PROXY_VARS` | env.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_PTRACE` | env.sh | `*)` |
| `SANDHOME_QEMUUSER_EXTRA` | sandhome qemuuser.sh | `$SANDHOME_QEMUUSER_EXTRA $sh_c_x` |
| `SANDHOME_REF` | bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_REPO` | env.sh profile.sh bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_REPO_DIR` | env.sh profile.sh bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_REQUIRE_DIGEST` | fetch.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_RUST_TARGETS` | env.sh report.sh sandhome rust.sh | `*)` |
| `SANDHOME_SHA256` | fetch.sh bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_BUN` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_CLANG` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_CMAKE` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_DENO` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_EMSCRIPTEN` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_FD` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_GO` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ` | fetch.sh bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ_LINUX_AMD64` | fetch.sh bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ_LINUX_ARM64` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ_LINUX_I386` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ_MACOS_AMD64` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_MESON` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_MOLD` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_NODE` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_PERL` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_PKGCONF` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_PYTHON` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_QEMUUSER` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_RIPGREP` | fetch.sh bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_RUST` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_SHELLCHECK` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_ZIG` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHELLCHECK_VERSION` | shellcheck.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHFMT_VERSION` | shfmt.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHIMS` | env.sh shim.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_VIEW_MODE` | env.sh memexec.sh report.sh space.sh bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_WANTED_TOOLCHAINS` | env.sh report.sh sandhome | `*)` |
| `SANDHOME_WORKSPACE` | space.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_ZIG_INDEX_URL` | sandhome zig.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_ZIG_VERSION` | sandhome zig.sh | `unset, and the feature is off until it is set` |

## errandsh variables

| variable | default |
| --- | --- |
| `ERRANDSH_HISTORY` | `$HOME/.errandsh-history` |
| `ERRANDSH_MAXHIST` | `500` |
| `ERRANDSH_NAME` | `the hostname, or errand` |
| `ERRANDSH_PTY` | `1 (the automatic path is on unless this is 0)` |
| `ERRANDSH_SHELL` | `/bin/sh` |

## pty shim variables

| variable | meaning | default |
| --- | --- | --- |
| `SANDHOME_FAKEPTY` | the `fakepty.so` to preload | the shim this build wrote, named in env.sh |
| `SANDHOME_FAKEPTY_SIZE` | the window size a full-screen program is told | `COLUMNSxLINES` when unset, then 80x24; when set it wins outright |
| `SANDHOME_FAKEPTY_ID` | which descriptors count as the terminal | set by env.sh and by `faketty`; unset, the feature is off |
| `SANDHOME_FAKEPTY_CRLF` | `0` stops a bare `\n` becoming `\r\n` on output | on, which is what a terminal with `OPOST\|ONLCR` does |

## Toolchains

| name | binaries on PATH | description |
| --- | --- | --- |
| `bun` | `bun` | Bun, a JavaScript/TypeScript runtime and toolkit (single binary) |
| `clang` | `bin/clang bin/clang++` | Clang/LLVM, from the official LLVM release tarball (a >1GB download) |
| `cmake` | `bin/cmake bin/ctest bin/cpack` | CMake, the build system for C/C++/Fortran projects |
| `deno` | `deno` | Deno, a TypeScript/JavaScript runtime (single binary, from GitHub) |
| `emscripten` | `upstream/emscripten/emcc upstream/emscripten/em++` | Emscripten SDK (emcc) for wasm32-unknown-emscripten, via emsdk |
| `fd` | `bin/fd` | fd, a fast and user-friendly find replacement |
| `gh` | `bin/gh` | gh, the GitHub command-line tool (single binary from its tarball) |
| `go` | `go/bin/go go/bin/gofmt` | Go, from the official go.dev tarball (GOROOT stays in the home root) |
| `jq` | `bin/jq` | jq, the command-line JSON processor (single static binary) |
| `meson` | `bin/meson` | Meson, the build system for C/C++/Rust/Vala projects |
| `mold` | `bin/mold bin/ld.mold` | mold, a fast ELF linker (gcc/clang/rust via -fuse-ld=mold) |
| `ninja` | `ninja` | ninja, a small build system (single static binary) |
| `node` | `bin/node bin/npm bin/npx` | Node.js with the bundled npm, from the official nodejs.org tarball |
| `perl` | `perl` | perl, the interpreter autoconf and ./configure need (adopted) |
| `pkgconf` | `bin/pkgconf bin/pkg-config` | pkgconf, the pkg-config implementation for ./configure builds |
| `python` | `(via its own PATH fragment)` | CPython, installed by uv (uv is always left on PATH) |
| `qemuuser` | `bin/qemu-x86_64` | qemu-user, the static user-mode emulators (run a guest ELF, trace its syscalls without ptrace) |
| `ripgrep` | `bin/rg` | ripgrep (rg), the fast recursive search tool |
| `rust` | `cargo/bin/rustup cargo/bin/cargo cargo/bin/rustc cargo/bin/rustdoc cargo/bin/cargo-clippy cargo/bin/cargo-fmt` | Rust via rustup (rustc, cargo, rustup, rustdoc, cargo-clippy, cargo-fmt; minimal profile) |
| `shellcheck` | `bin/shellcheck` | ShellCheck, the shell script linter (single static binary) |
| `shfmt` | `bin/shfmt` | shfmt, a shell script formatter (single static binary) |
| `yq` | `bin/yq` | yq, a YAML/TOML/XML command-line processor (single binary) |
| `zig` | `zig` | zig cc cross compiler and linker, from the official tarball |

## Tests

| file | what it checks |
| --- | --- |
| `sh tests/syntax.sh` | that will read it. `dash -n` is the check that matters; bash --posix is a |
| `sh tests/unit.sh` | machine. A helper exercised only through a full bootstrap is a helper whose bug |
| `sh tests/space.sh` | tests/space.sh - the two-root plan, the exec probe and the mirror. |
| `sh tests/toolchain.sh` | requirements cycle must be refused, and a linear requirement must install in |
| `sh tests/shims.sh` | tests/shims.sh - build and actually use both LD_PRELOAD shims. |
| `sh tests/docs.sh` | tests/docs.sh - the documentation is checked against the code, not trusted. |
| `sh tests/bootstrap.sh` | does NOT run binaries, prove the exec split put it where it runs, and prove the |
| `sh tests/global.sh` | A fresh shell finds the environment with no `. env.sh`, through a PATH dir. |
| `sh tests/errandsh-posix.sh` | errandsh's test, and it is a test rather than a claim. |
