#!/bin/sh
# bootstrap.sh - bring a sandbox up to a named set of toolchains, with the
# environment and the two filesystem roots handled, from one command.
#
#   sh bootstrap.sh --toolset developer
#   curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/bootstrap.sh | sh -s -- --with rust
#   . ./bootstrap.sh        # with SANDHOME_NO_RUN=1, defines its functions only
#
# THE PROBLEM IT EXISTS FOR. A sandbox can mount a directory rw and still refuse
# execve(2) on it, while allowing mmap(PROT_EXEC) - so a shared library read from
# there loads and a binary in it will not run. `mount` does not have to say
# noexec; the refusal can come from a policy invisible in /proc/mounts. Every
# hand-built userland handles that differently, and the difference is found weeks
# later inside a job that fails for a reason nobody wrote down.
#
# WHAT IT DOES, IN ORDER.
#   1. detects the machine (os, kernel, arch, libc, WSL, privilege, pty, passwd);
#   2. plans two roots: a persistent SH_HOME that may be noexec, and a small
#      exec-capable SH_EXEC. When the home runs binaries the two collapse.
#   3. adopts a toolchain that is already here, and installs one that is not,
#      with its executables promoted onto the exec root and its data left on the
#      home;
#   4. builds the LD_PRELOAD shims a cage needs and a normal host does not;
#   5. writes $SH_HOME/env.sh, installs the profile fragment and the one line a
#      login file needs, and reports what it read off the machine.
#
# STOP: IT IS POSIX sh AND IT IS CHECKED AS POSIX. No `local`, no arrays, no `[[`,
# no `$'...'`, no `a && b || c`. It depends on the shell and on almost nothing
# else: not awk, not sed, not grep, not tr, not find, not install, not dirname.
#
# EXIT CODES: 0 done, 1 something asked for could not be installed, 2 could not
# run at all.

set -u

SH_SELF=bootstrap
SH_VERSION=1
: "${SH_NO_RUN:=${SANDHOME_NO_RUN:-}}"

# ------------------------------------------------------------- locate or fetch --
# A script read from a pipe has no directory, and a modular bootstrap cannot work
# without lib/ and tools/. So when there is no directory the tree is fetched to a
# temp dir and this file re-execs itself from there. SANDHOME_NO_REFETCH stops a
# loop, and SANDHOME_REF pins the branch or tag.
SH_SELF_DIR=''
SH_FETCH_DIR=''
SH_REPO_OWNER=${SANDHOME_REPO:-talaria0101/sandhome}
SH_REPO_REF=${SANDHOME_REF:-main}

sh_bootstrap_resolve_dir() {
    case "$0" in
        */*)
            [ -f "$0" ] || return 1
            SH_SELF_DIR=$(CDPATH='' cd -- "${0%/*}" && pwd) || return 1
            ;;
        *)
            # `sh bootstrap.sh` leaves $0 as a bare filename; stdin leaves it as
            # the interpreter's name. Only the first is a file in this directory.
            [ -f "$0" ] || return 1
            SH_SELF_DIR=$(CDPATH='' cd -- . && pwd) || return 1
            ;;
    esac
    [ -r "$SH_SELF_DIR/lib/common.sh" ] || return 1
    return 0
}

sh_bootstrap_refetch() {
    printf 'bootstrap: no library beside this script; fetching %s@%s\n' \
        "$SH_REPO_OWNER" "$SH_REPO_REF" >&2
    if [ -n "${SANDHOME_NO_REFETCH:-}" ]; then
        printf 'bootstrap: [-] refetch is disabled and there is no library here\n' >&2
        exit 2
    fi
    SH_FETCH_DIR="${TMPDIR:-/tmp}/sandhome-bootstrap.$$"
    rm -rf "$SH_FETCH_DIR" 2>/dev/null
    mkdir -p "$SH_FETCH_DIR" 2>/dev/null || {
        printf 'bootstrap: [-] cannot create %s\n' "$SH_FETCH_DIR" >&2
        exit 2
    }
    sh_fr_ok=0
    # STOP: EACH DISTINCT OWNER IS ATTEMPTED ONCE (issue #168). This iterated
    # `"$SH_REPO_OWNER" talaria0101/sandhome` and the DEFAULT owner IS
    # talaria0101/sandhome, so on the default run the whole failure was printed
    # twice: every "curl could not fetch ..." line and every "[-] no curl, wget
    # or fetch on PATH" line appeared twice, and a reader counting downloader
    # attempts could not tell one failing host from two. The default is added
    # only when it is not already the owner.
    sh_fr_owners=$SH_REPO_OWNER
    case " $sh_fr_owners " in
        *' talaria0101/sandhome '*) ;;
        *) sh_fr_owners="$sh_fr_owners talaria0101/sandhome" ;;
    esac
    for sh_fr_owner in $sh_fr_owners; do
        # STOP: THE TARBALL URL IS /tar.gz/<ref> AND NOT
        # /tar.gz/refs/heads/<ref>. Measured against the real codeload:
        #   codeload.github.com/OWNER/tar.gz/refs/heads/main  -> 404
        #   codeload.github.com/OWNER/tar.gz/main            -> 200
        # The longer form is what the git protocol uses and it is what a reader
        # reaches for first, and it fails on a repository that exists with a
        # body that names the URL and nothing about the cause. A branch, a tag
        # and a commit sha all work in the short form, so one form is enough.
        sh_fr_url="https://codeload.github.com/$sh_fr_owner/tar.gz/$SH_REPO_REF"
        sh_fr_tar="$SH_FETCH_DIR/src.tar.gz"
        if sh_fr_fetch "$sh_fr_url" "$sh_fr_tar"; then
            if tar -xzf "$sh_fr_tar" -C "$SH_FETCH_DIR" 2>/dev/null; then
                sh_fr_ok=1
                break
            fi
        fi
    done
    if [ "$sh_fr_ok" != 1 ]; then
        printf 'bootstrap: [-] could not fetch %s@%s; set SANDHOME_REPO to a checkout URL or run this from a clone\n' \
            "$SH_REPO_OWNER" "$SH_REPO_REF" >&2
        exit 2
    fi
    sh_fr_dir=''
    for sh_fr_e in "$SH_FETCH_DIR"/*; do
        [ -d "$sh_fr_e" ] || continue
        if [ -r "$sh_fr_e/bootstrap.sh" ]; then
            sh_fr_dir=$sh_fr_e
            break
        fi
    done
    if [ -z "$sh_fr_dir" ]; then
        printf 'bootstrap: [-] the fetched archive has no bootstrap.sh\n' >&2
        exit 2
    fi
    printf 'bootstrap: fetched the tree with %s and re-executing from %s\n' \
        "$sh_fr_tool" "$sh_fr_dir" >&2
    SANDHOME_NO_REFETCH=1
    export SANDHOME_NO_REFETCH
    SANDHOME_FETCH_DIR=$SH_FETCH_DIR
    export SANDHOME_FETCH_DIR
    exec sh "$sh_fr_dir/bootstrap.sh" "$@"
}

# The two fetch functions are duplicated here in a minimal form on purpose: they
# are needed before any library is loadable, and a bootstrap that could not fetch
# its own library could not do anything at all.
#
# NOTE: THE FETCHER IS NAMED WHEN ONE IS CHOSEN, AND ITS ABSENCE IS A SENTENCE
# RATHER THAN A STATUS. The three-way fallback was silent, so a run that fetched
# with wget and a run that fetched with fetch looked identical, and a machine with
# none of the three failed with "could not fetch" and no hint that the missing
# program was the reason. "apt-get install curl" is the whole fix, and a
# bootstrap that cannot say so is a bootstrap that wastes a session.
sh_fr_runs() {
    sh_fr_bin=$1
    shift
    command -v "$sh_fr_bin" >/dev/null 2>&1 || return 1
    "$sh_fr_bin" "$@" >/dev/null 2>&1
    return $?
}

sh_fr_which() {
    if sh_fr_runs curl --version; then printf 'curl';  return 0; fi
    if sh_fr_runs wget --help;   then printf 'wget';  return 0; fi
    if command -v fetch >/dev/null 2>&1; then printf 'fetch'; return 0; fi
    printf ''
}

# STOP: A FAILED ATTEMPT FALLS THROUGH TO THE NEXT TOOL (issue #3). The old
# form chose one tool and returned its status, so a curl that exists but
# fails never tried wget, and the self-fetch died where a fallback would
# have succeeded. Each failure names its tool; success names its route.
sh_fr_fetch() {
    sh_ff_url=$1
    sh_ff_out=$2
    sh_ff_tried=0
    if sh_fr_runs curl --version; then
        sh_ff_tried=1
        if curl -fSL --retry 3 --retry-delay 2 -o "$sh_ff_out" "$sh_ff_url" 2>/dev/null && [ -s "$sh_ff_out" ]; then
            sh_fr_tool=curl
            printf 'bootstrap: fetched with curl from %s\n' "$sh_ff_url" >&2
            return 0
        fi
        printf 'bootstrap: curl could not fetch %s; trying the next downloader\n' "$sh_ff_url" >&2
    fi
    if sh_fr_runs wget --help; then
        sh_ff_tried=1
        if wget -q -O "$sh_ff_out" "$sh_ff_url" 2>/dev/null && [ -s "$sh_ff_out" ]; then
            sh_fr_tool=wget
            printf 'bootstrap: fetched with wget from %s\n' "$sh_ff_url" >&2
            return 0
        fi
        printf 'bootstrap: wget could not fetch %s; trying the next downloader\n' "$sh_ff_url" >&2
    fi
    if command -v fetch >/dev/null 2>&1; then
        sh_ff_tried=1
        if fetch -q -o "$sh_ff_out" "$sh_ff_url" 2>/dev/null && [ -s "$sh_ff_out" ]; then
            sh_fr_tool=fetch
            printf 'bootstrap: fetched with fetch from %s\n' "$sh_ff_url" >&2
            return 0
        fi
        printf 'bootstrap: fetch could not fetch %s\n' "$sh_ff_url" >&2
    fi
    # STOP: "NOTHING ON PATH" AND "EVERYTHING ON PATH FAILED" ARE DIFFERENT
    # SENTENCES, AND THE OLD ONE PRINTED THE WRONG ONE (issue #168). This block
    # used to run unconditionally, so a host carrying curl AND wget, both of
    # which had just been tried and had just failed on a bad ref or a 404, was
    # told "no curl, wget or fetch on PATH, so nothing can be downloaded" and
    # then handed an install command for a tool it already had. The message
    # pointed at the wrong cause, and the two attempts printed just above it
    # named the real one. Which of the two it is is now recorded while the loop
    # runs, so the sentence matches the machine.
    if [ "$sh_ff_tried" = 0 ]; then
        printf 'bootstrap: [-] no curl, wget or fetch on PATH, so nothing can be downloaded\n' >&2
        printf 'bootstrap:     install one of them first: apt-get install curl, apk add curl,\n' >&2
        printf 'bootstrap:     dnf install curl, or pacman -S curl\n' >&2
    else
        printf 'bootstrap: [-] every downloader present failed to fetch %s\n' "$sh_ff_url" >&2
        printf 'bootstrap:     the ref/URL or the network is the problem, not a missing tool;\n' >&2
        printf 'bootstrap:     check the ref, then try the URL above directly to see why\n' >&2
    fi
    return 1
}

# ---------------------------------------------------------------- usage --
usage() {
    cat <<'USAGE'
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
USAGE
}

# ------------------------------------------------------------------- library --
sh_load_library() {
    SH_LIB_DIR="$SH_SELF_DIR/lib"
    SH_REPO_DIR="$SH_SELF_DIR"
    export SH_LIB_DIR SH_REPO_DIR
    for sh_ll_mod in common detect space fetch env toolchain shim memexec report; do
        if [ ! -r "$SH_LIB_DIR/$sh_ll_mod.sh" ]; then
            printf 'bootstrap: [-] missing library %s\n' "$SH_LIB_DIR/$sh_ll_mod.sh" >&2
            exit 2
        fi
        # shellcheck source=/dev/null
        . "$SH_LIB_DIR/$sh_ll_mod.sh"
    done
}

# ------------------------------------------------------------------ arguments --
SH_TOOLSET=developer
SH_TOOLSET_GIVEN=0
SH_ONLY=''
SH_ONLY_GIVEN=0
SH_WITH=''
SH_WITHOUT=''
SH_DETECT=auto
SH_HOME_ARG=''
SH_EXEC_ARG=''
SH_SHIMS=build
SH_NEED_SHIMS=0
SH_SHELL=install
SH_SKILLS=install
SH_PROFILE=install
SH_PATH_LINE=install
# The global hook is on by default; SANDHOME_GLOBAL=0 (or --no-global) keeps a
# hook out of every PATH directory. A test suite and a restricted host set it
# so nothing is written where they do not own the directory.
: "${SANDHOME_GLOBAL:=install}"
case "$SANDHOME_GLOBAL" in
    0|no|off|none) SH_GLOBAL=none ;;
    *)             SH_GLOBAL=install ;;
esac
SH_JSON=0

sh_need_value() {
    if [ "$#" -lt 2 ]; then
        printf 'bootstrap: [-] %s needs a value\n' "$1" >&2
        exit 2
    fi
}

sh_toolset_names() {
    case "$1" in
        # The empty base (issue #129): `--toolset none` names no toolchains
        # and prints none, so `--with`/`--only` are exactly what the caller
        # typed. It is a real toolset, not an error, and unlike a preset it
        # implies no auto-detect (an explicit request is never extended).
        none)      : ;;
        minimal)   printf 'jq\n' ;;
        cli)       printf 'jq ripgrep fd\n' ;;
        developer) printf 'jq ripgrep fd python node\n' ;;
        # REDUNDANCY: THE COMPILER SETS SHIP THE BUILD CHAIN, NOT JUST THE
        # COMPILER. A rust/go checkout that then configures a CMake subproject
        # failed with `cmake: command not found` after a languages install,
        # because languages named compilers but not the build systems that
        # drive them. The build tools are small beside the compilers, so they
        # ride with both compiler toolsets as well as with project.
        languages) printf 'jq ripgrep fd python node rust go zig deno bun mold clang cmake meson ninja pkgconf perl\n' ;;
        # agent IS NOT A SYNONYM FOR languages (issue #194). It was written as
        # the same line, so the name promised a modest step up from developer
        # and delivered the whole compiler set - including clang, a >1GB
        # download and ~16GB on the home root - for a caller who never asked to
        # build C++. An agent at work wants the RUNTIMES and the CLI/analysis
        # tools it actually runs, not a source-build chain: deno and bun beside
        # node, yq for structured data, shellcheck and shfmt for the shell it
        # writes, gh for the forge, and qemu-user for a foreign-arch artifact.
        # The small build pieces (mold, ninja, pkgconf, perl) ride along so a
        # configure step still works, but the multi-gigabyte compilers
        # (rust, go, zig, clang, cmake, meson) are named only by languages,
        # project, or an explicit --with. A caller who wants the compilers asks
        # for them, and a caller who asked for agent gets what the name says.
        agent)     printf 'jq ripgrep fd python node deno bun yq gh shellcheck shfmt qemuuser mold ninja pkgconf perl\n' ;;
        # The union a from-source C/C++ build needs, in one command, so an agent
        # that pasted a CMake or meson project does not hand-assemble the list
        # before the first configure (issue #123). meson pulls python through its
        # own REQUIRES, so naming it here is the whole closure.
        project)   printf 'jq ripgrep fd python node go rust clang cmake meson ninja mold pkgconf perl\n' ;;
        *)         return 1 ;;
    esac
}

# sh_bootstrap_detect -> the extra toolchains the working tree asks for, each
# once. A one-paste setup cannot know a project it was never told about, so a
# fresh Rust checkout whose owner asked for `--toolset developer` paid an
# `sandhome install rust` round-trip before the first `cargo build` (issue
# #116). The working DIRECTORY is read first, then the git top level when it
# differs, then one level of subdirs for monorepos: walking an arbitrary tree
# is a slower question that a setup step should not answer behind the
# caller's back, but top-level-only misses `frontend/package.json` and
# `backend/Cargo.toml` entirely. --no-detect and --without both turn the fold
# off.
sh_bootstrap_detect() {
    sh_bdet_seen=' '
    sh_bdet_out=''
    sh_bdet_add() {
        case "$sh_bdet_seen" in
            *" $1 "*) return 0 ;;
        esac
        sh_bdet_seen="$sh_bdet_seen$1 "
        sh_bdet_out="$sh_bdet_out $1"
        return 0
    }
    # One dir's markers, factored so PWD, the git root and one subdir level
    # share the same table. Manifests name the toolchain outright; a C/C++
    # build system names the compiler plus its linker and runner.
    sh_bdet_dir() {
        sh_bdet_d=${1:-.}
        if [ -e "$sh_bdet_d/Cargo.toml" ] || [ -e "$sh_bdet_d/Cargo.lock" ] || [ -e "$sh_bdet_d/rust-toolchain.toml" ] || [ -e "$sh_bdet_d/rust-toolchain" ]; then sh_bdet_add rust; fi
        if [ -e "$sh_bdet_d/go.mod" ] || [ -e "$sh_bdet_d/go.sum" ] || [ -e "$sh_bdet_d/go.work" ]; then sh_bdet_add go; fi
        if [ -e "$sh_bdet_d/package.json" ] || [ -e "$sh_bdet_d/package-lock.json" ] || [ -e "$sh_bdet_d/pnpm-lock.yaml" ] || [ -e "$sh_bdet_d/yarn.lock" ] || [ -e "$sh_bdet_d/.nvmrc" ]; then sh_bdet_add node; fi
        if [ -e "$sh_bdet_d/deno.json" ] || [ -e "$sh_bdet_d/deno.jsonc" ]; then sh_bdet_add deno; fi
        if [ -e "$sh_bdet_d/bun.lockb" ] || [ -e "$sh_bdet_d/bunfig.toml" ]; then sh_bdet_add bun; fi
        if [ -e "$sh_bdet_d/build.zig" ] || [ -e "$sh_bdet_d/build.zig.zon" ]; then sh_bdet_add zig; fi
        if [ -e "$sh_bdet_d/pyproject.toml" ] || [ -e "$sh_bdet_d/requirements.txt" ] || [ -e "$sh_bdet_d/setup.py" ] || [ -e "$sh_bdet_d/Pipfile" ] || [ -e "$sh_bdet_d/uv.lock" ]; then sh_bdet_add python; fi
        if [ -e "$sh_bdet_d/CMakeLists.txt" ] || [ -e "$sh_bdet_d/meson.build" ] || [ -e "$sh_bdet_d/configure.ac" ] || [ -e "$sh_bdet_d/CMakePresets.json" ]; then
            sh_bdet_add clang
            sh_bdet_add mold
            sh_bdet_add ninja
            sh_bdet_add pkgconf
            sh_bdet_add perl
            # The build system itself, not only its compiler and linker: a
            # CMakeLists.txt project configured with `cmake -S . -B build`
            # failed with `command not found` before the catalog shipped cmake
            # (issue #123). meson.build names meson; configure.ac is autotools
            # and needs pkgconf plus perl even when the base image carries them,
            # so both are folded here by name rather than relied on by accident.
            [ -e "$sh_bdet_d/CMakeLists.txt" ] || [ -e "$sh_bdet_d/CMakePresets.json" ] && sh_bdet_add cmake
            [ -e "$sh_bdet_d/meson.build" ] && sh_bdet_add meson
        fi
        # A Makefile alone is a weaker C signal than CMake: it names the need
        # for a compiler and a runner, but not necessarily a mold linker, so
        # only clang and ninja fold in. A bare `.c` is weaker still (below).
        if [ -e "$sh_bdet_d/Makefile" ] || [ -e "$sh_bdet_d/makefile" ] || [ -e "$sh_bdet_d/GNUmakefile" ]; then
            sh_bdet_add clang
            sh_bdet_add ninja
        fi
    }
    sh_bdet_dir .
    # The git top level, when it differs from PWD: the agent may sit in a
    # subdir of the project it was pasted to work on.
    if sh_have git; then
        sh_bdet_top=$(git rev-parse --show-toplevel 2>/dev/null) || sh_bdet_top=''
        case "$sh_bdet_top" in ''|.) ;;
            *)
                sh_bdet_here=$(pwd 2>/dev/null) || sh_bdet_here=''
                if [ -n "$sh_bdet_top" ] && [ "$sh_bdet_top" != "$sh_bdet_here" ] && [ -d "$sh_bdet_top" ]; then
                    sh_bdet_dir "$sh_bdet_top"
                fi ;;
        esac
    fi
    # One subdir level for monorepos: frontend/, backend/, crates/* each name
    # their own toolchain. Bounded (no recursion) and manifest-only (no
    # source globs down here, which would be noise from vendored trees).
    for sh_bdet_sub in ./*/; do
        [ -d "$sh_bdet_sub" ] || continue
        case "$sh_bdet_sub" in ./.*/ ) continue ;; esac
        case "$sh_bdet_sub" in ./node_modules/|./.git/|./target/|./.venv/|./venv/) continue ;; esac
        sh_bdet_dir "${sh_bdet_sub%/}"
    done
    # A source file at the top level is a real, if weaker, signal. The glob is
    # written relative so the shell does the matching and a directory that
    # matched nothing leaves the literal, which `-e` refuses.
    for sh_bdet_f in ./*.rs; do if [ -e "$sh_bdet_f" ]; then sh_bdet_add rust; fi; done
    for sh_bdet_f in ./*.go; do if [ -e "$sh_bdet_f" ]; then sh_bdet_add go; fi; done
    for sh_bdet_f in ./*.py; do if [ -e "$sh_bdet_f" ]; then sh_bdet_add python; fi; done
    for sh_bdet_f in ./*.zig; do if [ -e "$sh_bdet_f" ]; then sh_bdet_add zig; fi; done
    for sh_bdet_f in ./*.c ./*.cc ./*.cpp ./*.cxx ./*.h ./*.hpp; do
        if [ -e "$sh_bdet_f" ]; then sh_bdet_add clang; fi
    done
    printf '%s' "${sh_bdet_out# }"
    return 0
}

sh_bootstrap_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --toolset)         sh_need_value "$@"; SH_TOOLSET=$2; SH_TOOLSET_GIVEN=1; shift 2 ;;
            # --only NAME[,NAME...] is an explicit-only selection and is
            # DEFINED as the synonym `--toolset none --with NAME...` (issue
            # #129): it consumes every word up to the next flag, so both
            # `--only jq,ripgrep` and `--only jq ripgrep` are one request,
            # and it then goes through the same validation as the rest of the
            # arguments. The set of names it produced is checked below, so a
            # typo refuses the run before anything is downloaded.
            --only)
                sh_need_value "$@"
                SH_ONLY_GIVEN=1
                shift
                while [ "$#" -gt 0 ]; do
                    case "$1" in --*) break ;; esac
                    SH_ONLY="$SH_ONLY,$1"
                    shift
                done
                ;;
            --with)            sh_need_value "$@"; SH_WITH="$SH_WITH,$2"; shift 2 ;;
            --without)         sh_need_value "$@"; SH_WITHOUT="$SH_WITHOUT,$2"; shift 2 ;;
            --no-detect)       SH_DETECT=none; shift ;;
            --detect)          SH_DETECT=force; shift ;;
            --list-toolchains) for sh_ba_t in $(sh_toolchain_available); do
                                   printf '%s\n' "$sh_ba_t"
                               done
                               exit 0 ;;
            --home)            sh_need_value "$@"; SH_HOME_ARG=$2; shift 2 ;;
            --exec)            sh_need_value "$@"; SH_EXEC_ARG=$2; shift 2 ;;
            --no-shims)        SH_SHIMS=none; shift ;;
            --require-shims)   SH_NEED_SHIMS=1; shift ;;
            --no-shell)        SH_SHELL=none; shift ;;
            --no-skills)        SH_SKILLS=none; shift ;;
            --no-profile)      SH_PROFILE=none; shift ;;
            --no-path-line)    SH_PATH_LINE=none; shift ;;
            --no-global)       SH_GLOBAL=none; shift ;;
            --dry-run)         SH_DRY_RUN=1; shift ;;
            --json)            SH_JSON=1; shift ;;
            --doh-url)         sh_need_value "$@"; SANDHOME_DOH_URL=$2; export SANDHOME_DOH_URL; shift 2 ;;
            # # NOTE: THE VERSION LINE IS THE TREE'S SCHEMA AND NOT THIS FILE'S
            # NAME. It printed `bootstrap/1` where `sandhome version` printed
            # `sandhome/1`, so a caller checking whether this checkout is schema 1
            # had to try both programs and could not tell a version difference
            # from a program-name difference. `sandhome --version` and
            # `sandhome version` both answer `sandhome/1` now, and so does this.
            --version)         printf 'sandhome/%s\n' "$SH_VERSION"; exit 0 ;;
            -h|--help)         usage; exit 0 ;;
            *)                 usage >&2; printf 'bootstrap: [-] unknown argument %s\n' "$1" >&2; exit 2 ;;
        esac
    done
    if ! sh_toolset_names "$SH_TOOLSET" >/dev/null; then
        printf 'bootstrap: [-] unknown toolset %s\n' "$SH_TOOLSET" >&2
        exit 2
    fi
    # --only expands to `--toolset none --with NAME...` (issue #129) after
    # every argument is seen: an explicit non-none --toolset alongside it is
    # an ambiguous request and is refused rather than silently resolved by
    # argument order, while `--toolset none --only ...` is the same intent
    # spelled twice and passes.
    if [ "$SH_ONLY_GIVEN" = 1 ]; then
        if [ -z "$(sh_trim "$SH_ONLY")" ]; then
            printf 'bootstrap: [-] --only needs at least one toolchain name\n' >&2
            exit 2
        fi
        if [ "$SH_TOOLSET_GIVEN" = 1 ] && [ "$SH_TOOLSET" != none ]; then
            printf 'bootstrap: [-] --only selects exactly the names given and cannot be combined with --toolset %s (use --toolset none, or drop --only)\n' "$SH_TOOLSET" >&2
            exit 2
        fi
        for sh_bo_only_n in $(sh_split_on ',' "$SH_ONLY"); do
            if ! sh_toolchain_known "$sh_bo_only_n"; then
                printf 'bootstrap: [-] unknown toolchain %s in --only; run "sh bootstrap.sh --list-toolchains" for the list\n' "$sh_bo_only_n" >&2
                exit 2
            fi
        done
        SH_TOOLSET=none
        SH_WITH="$SH_WITH,$SH_ONLY"
    fi
}

# --------------------------------------------------------------------- steps --
sh_bootstrap_install_shell() {
    if [ "$SH_SHELL" = none ]; then
        return 0
    fi
    sh_bs_src="$SH_REPO_DIR/shell/errandsh"
    if [ ! -r "$sh_bs_src" ]; then
        sh_warn 'no shell/errandsh beside bootstrap.sh'
        return 0
    fi
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install errandsh as $SH_EXEC_BIN/errandsh"
        return 0
    fi
    mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
    cp -f "$sh_bs_src" "$SH_EXEC_BIN/errandsh" || {
        sh_fail 'could not install errandsh onto the exec root'
        return 1
    }
    chmod 0755 "$SH_EXEC_BIN/errandsh" 2>/dev/null || true
    sh_step "installed $SH_EXEC_BIN/errandsh"
    return 0
}

# sh_bootstrap_install_command -> put `sandhome` on the exec bin so a shell
# that has read env.sh can run it by name.
#
# NOTE: IT IS COPIED AND NOT LINKED, BECAUSE THE CHECKOUT IS USUALLY NOEXEC. A
# checkout that lives on a root refusing execve is the case this tool exists for,
# and a symlink into it answers `command -v sandhome` and then fails with
# `Permission denied`. Measured on a checkout under /workspace:
#   $ command -v sandhome
#   /workspace/sandhome/bin/sandhome
#   $ sandhome version
#   sh: sandhome: Permission denied
# The copy carries no state: it finds its library through SANDHOME_REPO_DIR,
# which env.sh exports, so a later `sandhome install` promotes against the same
# tree the bootstrap used.
sh_bootstrap_install_command() {
    sh_bic_src="$SH_REPO_DIR/bin/sandhome"
    if [ ! -r "$sh_bic_src" ]; then
        sh_warn "no bin/sandhome beside bootstrap.sh"
        return 0
    fi
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_bic_src as $SH_EXEC_BIN/sandhome"
        return 0
    fi
    mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
    # The bake lives in the library (sh_bake_command), because install and
    # repair write this same file and used to overwrite the bake with the raw
    # template; one writer means one bake (issue #133). The library function
    # also reads the written file back, so the step it prints describes the
    # artefact rather than the attempt.
    if ! sh_bake_command "$sh_bic_src" "$SH_EXEC_BIN/sandhome"; then
        sh_fail 'could not install sandhome onto the exec root'
        return 1
    fi
    # # STOP: THE BOOTSTRAP WRITES THE PRIVATE MIRROR TOO. bin/sandhome's
    # comment claims the bootstrap mirrors lib/ and bin/ into
    # $SANDHOME_EXEC/.sandhome-lib, but only install and repair called
    # sh_exec_mirror_library, so a fresh pipe setup had no mirror and
    # `env -i <exec>/bin/sandhome` failed while the docs said it works
    # (issue #147). Mirrored here from the tree in hand; bootstrap re-bakes and
    # re-mirrors from the durable repo after sh_repo_persist.
    sh_exec_mirror_library || true
    sh_step "installed $SH_EXEC_BIN/sandhome"
    sh_step "mirrored the library beside it at $SH_EXEC/.sandhome-lib"
    # # A STABLE ABSOLUTE WAY IN, BECAUSE A NON-LOGIN SHELL HAS NO PATH. The exec
    # bin is on PATH only through ~/.profile, which a login shell reads; an agent
    # harness spawns a non-login shell per tool call, so nothing sources the
    # environment and `eval "$(sandhome env)"` fails with `sandhome: not found`
    # and rc=0 (issue #122). The home is often NOEXEC, so a copy of the command
    # there cannot run - sourcing a file needs no exec permission, so what lands
    # on the home is a SOURCEABLE snippet, not a binary. It names the exec bin and
    # a `sandhome` function, so a caller with nothing but a shell and the home
    # path gets the command and the environment in one line. The exec bin path is
    # baked in, and `sandhome resume` rewrites the snippet after a tmpfs restart
    # moves the view.
    # REDUNDANCY: THREE ROOTS, NOT ONE BAKED PATH, BECAUSE THE BAKED PATH GOES
    # STALE. A tmpfs restart moves the exec view before `resume` rewrites this
    # file, so a snippet that names only the baked bin answers `not found` in
    # exactly the cold shell it exists for. The function tries the baked bin,
    # then the recorded SANDHOME_EXEC, then the repo copy beside the bootstrap,
    # then PATH, and fails loudly naming the home it read. Paths are quoted
    # with sh_sq_quote so a home with a space or quote survives sourcing.
    if [ -d "$SH_HOME" ] && [ -n "$SH_EXEC_BIN" ]; then
        sh_entry_write && sh_step "wrote $SH_HOME/entry.sh (source it from a shell with no PATH)"
    fi
    return 0
}

# sh_bootstrap_install_skills -> put the skills where harnesses discover them
# ($HOME/.agents/skills, plus $HOME/.pi/agent/skills when Pi state exists).
# A skill already there -- a directory or a symlink from an earlier run -- is
# left alone, so a hand-maintained skill is never overwritten. From a clone
# the skill is symlinked (later pulls update it, as ROUTE.md says); from a
# fetched tree it is copied (the staging tree is removed at the end of this
# run, so a link into it would dangle). Without a HOME there is nowhere to
# put them, and that is said rather than guessed.
sh_bootstrap_install_skills() {
    if [ "$SH_SKILLS" = none ]; then
        return 0
    fi
    if [ -z "${HOME:-}" ]; then
        sh_warn 'no HOME here, so the skills were not installed; fetch them by URL as ROUTE.md says'
        return 0
    fi
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install the skills into $HOME/.agents/skills"
        return 0
    fi
    sh_bis_link=0
    if [ -d "$SH_REPO_DIR/.git" ]; then
        sh_bis_link=1
    fi
    for sh_bis_s in sandhome errandsh sealed-sandbox; do
        [ -d "$SH_REPO_DIR/skills/$sh_bis_s" ] || continue
        for sh_bis_base in "$HOME/.agents/skills" "$HOME/.pi/agent/skills"; do
            case "$sh_bis_base" in
                "$HOME/.pi/agent/skills") [ -d "$HOME/.pi" ] || continue ;;
            esac
            if [ -e "$sh_bis_base/$sh_bis_s" ] || [ -L "$sh_bis_base/$sh_bis_s" ]; then
                continue
            fi
            mkdir -p "$sh_bis_base" 2>/dev/null || continue
            if [ "$sh_bis_link" = 1 ]; then
                if ln -s "$SH_REPO_DIR/skills/$sh_bis_s" "$sh_bis_base/$sh_bis_s" 2>/dev/null; then
                    sh_step "linked $sh_bis_base/$sh_bis_s"
                fi
            else
                if mkdir -p "$sh_bis_base/$sh_bis_s" 2>/dev/null && \
                   cp -f "$SH_REPO_DIR/skills/$sh_bis_s/SKILL.md" "$sh_bis_base/$sh_bis_s/SKILL.md" 2>/dev/null; then
                    sh_step "installed $sh_bis_base/$sh_bis_s/SKILL.md"
                fi
            fi
        done
    done
    return 0
}

sh_bootstrap_path_line() {
    if [ "$SH_PATH_LINE" = none ] || [ "$SH_DRY_RUN" = 1 ]; then
        return 0
    fi
    # THE MARKER IS WHAT MAKES THIS SAFE (issue #188). The line carries a
    # trailing comment naming this tree, and sh_append_once only replaces a line
    # that both starts `export PATH="` and carries the mark. A hand-written
    # PATH export shares the prefix but never the mark, so it is left byte for
    # byte - measured before the fix: a ~/.profile with two of the user's own
    # PATH exports came out with one, replaced by this one.
    sh_bpl_mark='# sandhome'
    sh_bpl_line="export PATH=\"$SH_EXEC_BIN:\$PATH\" $sh_bpl_mark"
    # The prefix is what makes this line replaceable: without it a re-run that
    # moves the exec root appends a second PATH block and leaves the superseded
    # root first on PATH, where it still wins (issue #41). The mark narrows it
    # to a line this tree wrote, so no other export is touched.
    sh_append_login "$sh_bpl_line" "$SH_EXEC_BIN" 'export PATH="' "$sh_bpl_mark"
    sh_append_rc "$sh_bpl_line" "$SH_EXEC_BIN" 'export PATH="' "$sh_bpl_mark"
    return 0
}

sh_bootstrap_install_profile() {
    if [ "$SH_PROFILE" = none ]; then
        return 0
    fi
    sh_install_profile "$SH_REPO_DIR/lib/profile.sh"
}

# sh_bootstrap_install_global -> put the environment in a directory a fresh
# non-login shell already searches (issue #127). One setup, every shell; see
# the global hook section in lib/env.sh for the mechanism and the measurement.
sh_bootstrap_install_global() {
    if [ "$SH_GLOBAL" = none ]; then
        return 0
    fi
    sh_global_install || true
}

# ---------------------------------------------------------------------- main --
sandhome_bootstrap_main() {
    sh_bootstrap_resolve_dir || sh_bootstrap_refetch "$@"
    sh_load_library
    sh_bootstrap_args "$@"
    # The command itself is in the checkout, and every other instruction in
    # every document says to run it by name. Carrying its directory in the
    # environment is what lets env.sh put it on PATH.
    SANDHOME_BIN_DIR=$SH_REPO_DIR/bin
    export SANDHOME_BIN_DIR

    if [ -n "$SH_HOME_ARG" ]; then SANDHOME_HOME=$SH_HOME_ARG; fi
    if [ -n "$SH_EXEC_ARG" ]; then SANDHOME_EXEC=$SH_EXEC_ARG; fi
    export SANDHOME_HOME SANDHOME_EXEC
    # # STOP: --require-shims AND --no-shims IS A REFUSAL, NOT A SILENT SUCCESS.
    # The require check used to run unconditionally below a build that --no-shims
    # had suppressed, so the pair read a file that was deliberately absent and
    # failed with a message about a shim the caller had just said not to build.
    if [ "$SH_SHIMS" = none ] && [ "$SH_NEED_SHIMS" = 1 ]; then
        sh_die '--require-shims and --no-shims together are contradictory; pick one'
    fi

    sh_detect_all
    sh_space_plan
    # # STOP: THE EXPORTED NAMES ARE BOUND FROM THE PLAN BEFORE ANY LOAD.
    # Under `set -u` a reference to an unset `$SANDHOME_HOME` is a runtime
    # abort, and `sh_env_load` sources every `$SH_HOME/env.d/*.sh`, whose
    # fragments reference those names. A single leftover fragment killed every
    # toolset on a re-run, including `minimal`, and on a virgin home the adopt
    # path wrote the first fragment and then aborted loading it. The plan owns
    # the values; the exports adopt them when the caller did not set them.
    : "${SANDHOME_HOME:=$SH_HOME}"
    : "${SANDHOME_EXEC:=$SH_EXEC}"
    export SANDHOME_HOME SANDHOME_EXEC
    # SANDHOME_FORCE forces a local install even when the host already
    # carries a working copy: 1 (or all) forces every requested toolchain,
    # a comma list forces the names in it. A usable host copy is otherwise
    # adopted, which is the common case; the force is for when the operator
    # wants the toolchain under sandhome's own control (a newer release, a
    # split-root view, a clean reinstall). `sandhome install --force NAME`
    # is the same decision per command.
    case "${SANDHOME_FORCE:-}" in
        ''|0|no|off|false) SH_FORCE_LIST='' ;;
        1|all|yes|on|true) SH_FORCE_LIST='*' ;;
        *) SH_FORCE_LIST=",${SANDHOME_FORCE}," ;;
    esac
    export SH_FORCE_LIST
    # The helper that lets views run from memory is built before any
    # toolchain installs, so the first promote already prices kilobytes.
    sh_memexec_ensure
    # # NOTE: PICK UP WHAT AN EARLIER RUN INSTALLED BEFORE DECIDING WHAT TO INSTALL.
    # Without this, the second bootstrap of an already-set-up sandbox downloads
    # jq again because its probe ran against a PATH that did not yet carry the
    # exec view. Adoption is the common case on a long-lived base.
    sh_env_load

    sh_say "$SH_OS_ID on $SH_KERNEL $SH_ARCH, $SH_LIBC, wsl=$SH_WSL, privilege=$SH_PRIVILEGE"
    sh_say "pty=$SH_PTY passwd=$SH_PASSWD"
    # # STOP: THE ROOTS LINE MUST NAME THE ROOTS THE RUN WILL USE. This printed
    # "home and exec are the same root: $SH_HOME" whenever the home happens to
    # run files, even when `--exec` named a different root -- so the one line a
    # consumer reads to find out where things will land said the opposite of
    # what the plan had decided, and read as "--exec was ignored" (issue #149).
    # The condition is now whether the two roots ARE the same, and a named
    # root says so.
    if [ "$SH_EXEC" = "$SH_HOME" ]; then
        sh_say "home and exec are the same root: $SH_HOME (no separate root named; the home runs binaries)"
    elif [ "$SH_HOME_EXEC" = yes ]; then
        sh_say "home $SH_HOME (runs binaries); exec $SH_EXEC (named)"
    else
        sh_say "home $SH_HOME (noexec); exec $SH_EXEC"
    fi

    # Compose the request: the toolset, plus --with, minus --without, first-seen
    # wins so a name the toolset and --with both carry is installed once.
    sh_mb_wanted=''
    for sh_mb_name in $(sh_toolset_names "$SH_TOOLSET") $(sh_split_on ',' "$SH_WITH"); do
        if sh_in_list "$sh_mb_name" "$(sh_split_on ',' "$SH_WITHOUT")"; then
            continue
        fi
        if sh_in_list "$sh_mb_name" "$sh_mb_wanted"; then
            continue
        fi
        sh_mb_wanted="$sh_mb_wanted $sh_mb_name"
    done
    # The working tree is asked for what it names (issue #116). The detected
    # names come after the toolset so a later --without still removes them, and
    # each one is said out loud: an install a caller did not name must be a
    # sentence they can see, not a surprise download.
    #
    # AN EXPLICIT-ONLY REQUEST IS NEVER EXTENDED (issue #129). With
    # `--toolset none` or `--only`, the request is exactly what was typed:
    # project markers are not folded in, so `--only rust` still reads
    # `requested=rust` in a tree whose Cargo.toml and package.json would have
    # added node. Detection stays available as an OPT-IN (`--detect`), which
    # is the other half of the same clause: the caller who wants both says so.
    # A preset toolset keeps the #116 behaviour unchanged, because there the
    # markers are a convenience on top of a broad ask.
    sh_mb_detect=${SH_DETECT:-auto}
    if [ "$sh_mb_detect" != none ] && [ "$sh_mb_detect" != force ]; then
        if [ "$SH_TOOLSET" = none ]; then
            sh_mb_detect=none
        fi
    fi
    if [ "$sh_mb_detect" != none ]; then
        SH_DETECTED_TOOLCHAINS=''
        for sh_mb_name in $(sh_bootstrap_detect); do
            if sh_in_list "$sh_mb_name" "$(sh_split_on ',' "$SH_WITHOUT")"; then
                continue
            fi
            if sh_in_list "$sh_mb_name" "$sh_mb_wanted"; then
                continue
            fi
            sh_mb_wanted="$sh_mb_wanted $sh_mb_name"
            SH_DETECTED_TOOLCHAINS="$SH_DETECTED_TOOLCHAINS $sh_mb_name"
            sh_say "detected a project marker for $sh_mb_name in $PWD; adding it to the request (--no-detect turns this off)"
        done
        SH_DETECTED_TOOLCHAINS=${SH_DETECTED_TOOLCHAINS# }
        export SH_DETECTED_TOOLCHAINS
    fi

    # Price the whole request before spending anything (issue #75): one line
    # per toolchain with what it wants and whether the root holds it, then
    # the total against the ceiling. A dry run prints this alongside the
    # per-toolchain would-lines and stops having written nothing; a real run
    # refuses the no-fit names up front - naming --exec DIR, gc, and a smaller
    # toolset as the three ways out - and installs only what fits, instead of
    # installing what fits and then failing partway with the root already
    # partly consumed.
    # shellcheck disable=SC2086
    sh_feasibility_plan $sh_mb_wanted
    # A detected toolchain is a convenience, not a request: one the exec root
    # cannot hold is named and dropped, and does not turn the setup red. A name
    # the caller asked for is still refused loudly, because that is a promise
    # the run has to keep or break on purpose.
    if [ -n "${SH_DETECTED_TOOLCHAINS:-}" ]; then
        sh_mb_keep=''
        for sh_mb_name in $sh_mb_wanted; do
            case " $SH_INFEASIBLE " in
                *" $sh_mb_name "*)
                    case " $SH_DETECTED_TOOLCHAINS " in
                        *" $sh_mb_name "*)
                            sh_warn "detected $sh_mb_name does not fit the exec root; skipping it (name it with --with to require it)"
                            continue ;;
                    esac ;;
            esac
            sh_mb_keep="$sh_mb_keep $sh_mb_name"
        done
        sh_mb_wanted=$sh_mb_keep
    fi
    if [ "${SH_DRY_RUN:-0}" = 1 ]; then
        # shellcheck disable=SC2086
        for sh_mb_name in $SH_FEASIBLE; do
            sh_toolchain_ensure "$sh_mb_name" || true
        done
    else
        for sh_mb_name in $SH_INFEASIBLE; do
            # A detected name was already dropped above with a warning; it is
            # not a refusal.
            case " ${SH_DETECTED_TOOLCHAINS:-} " in
                *" $sh_mb_name "*) continue ;;
            esac
            # The shortfall is named, not just the refusal: the plan priced
            # each name as name:need:free, so the reader sees which tool is
            # blocked and by how many megabytes (issue #87).
            sh_mb_why=''
            for sh_mb_trip in $SH_INFEASIBLE_WHY; do
                case "$sh_mb_trip" in
                    "$sh_mb_name:"*)
                        sh_mb_need=${sh_mb_trip#"$sh_mb_name:"}
                        sh_mb_need=${sh_mb_need%%:*}
                        sh_mb_free=${sh_mb_trip##*:}
                        case "$sh_mb_need" in
                            ''|*[!0-9]*) ;;
                            *)
                                case "$sh_mb_free" in
                                    ''|*[!0-9]*) ;;
                                    *) sh_mb_why=" (needs ${sh_mb_need}MB, ${sh_mb_free}MB free, short by $((sh_mb_need - sh_mb_free))MB)" ;;
                                esac ;;
                        esac ;;
                esac
            done
            sh_fail "toolchain $sh_mb_name does not fit the exec root$sh_mb_why (see the feas lines above); re-run with --exec DIR on a roomy exec-capable path, run 'sandhome gc' to reclaim caches, or ask for a smaller toolset"
        done
        for sh_mb_name in $SH_FEASIBLE; do
            sh_toolchain_ensure "$sh_mb_name" || true
        done
    fi
    # What was ASKED for, recorded so `sandhome doctor` can check it later. The
    # names are what the run wanted, not what it managed: a toolchain that
    # failed to install is exactly the one the readiness gate has to see, and
    # the failure is already counted in SH_FAILURES, so the bootstrap exits
    # non-zero on its own (#38).
    #
    # The bootstrap is the AUTHORITATIVE statement of the request, so it
    # REPLACES the stored list rather than merging into it: a re-run with
    # `--toolset none` or `--only` has to disarm the names an earlier run
    # recorded, or doctor would keep gating on a request the caller just took
    # back. The merge rule (issue #57) still governs `sandhome install`, which
    # adds to an existing request instead of restating it.
    SH_WANTED_TOOLCHAINS=$sh_mb_wanted
    SH_WANTED_REPLACE=1
    export SH_WANTED_TOOLCHAINS SH_WANTED_REPLACE

    if [ "$SH_SHIMS" != none ]; then
        sh_shim_build_all "$SH_REPO_DIR/shims"
        sh_shim_write_passwd
        # # NOTE: --require-shims NARROWS THIS AND DOES NOT ENABLE IT. The needed-
        # and-missing check lives in sh_shim_build_all, which is the single place
        # both entry points go through; it ran here a second time only under
        # --require-shims, so a machine with no compiler finished with
        # `failures=0` and exit 0. The flag now means one narrower thing: refuse
        # when a shim is PRESENT but older than its source, which is a different
        # defect and which this check could not see at all.
        if [ "$SH_NEED_SHIMS" = 1 ]; then
            for sh_mb_shim in $(sh_shim_names); do
                if [ "$(sh_shim_need "$sh_mb_shim")" = yes ] && [ -f "$(sh_shims_dir)/$sh_mb_shim.so" ]; then
                    if [ "$(sh_shims_dir)/$sh_mb_shim.so" -ot "$SH_REPO_DIR/shims/$sh_mb_shim.c" ]; then
                        sh_fail "the $sh_mb_shim shim is older than its source and --require-shims is set"
                    fi
                fi
            done
        fi
    fi

    sh_bootstrap_install_shell || true
    sh_bootstrap_install_command || true
    sh_bootstrap_install_skills || true
    # Durable library (issue #20): the network-only path runs from a scratch
    # tree under /tmp that the reaper, a reboot, or gc removes, after which
    # every `sandhome` call exits 2. See sh_repo_persist in lib/env.sh.
    sh_repo_persist || true
    # sh_repo_persist repoints SH_REPO_DIR at the durable copy under the home
    # when it ran from scratch. Re-bake the command and the private mirror from
    # THERE, so the bake names a tree that survives the /tmp cleanup below
    # instead of the scratch extraction dir that is about to be removed
    # (issue #147: the pipe bootstrap baked /tmp/sandhome-bootstrap.*/sandhome-main).
    sh_exec_install_launchers || true
    sh_env_write
    sh_env_load
    # # STOP: A THROWAWAY ROOT MUST NOT REWRITE THE CALLER'S LOGIN FILES (issue
    # #192). --home and --exec exist to put the sandbox somewhere other than the
    # default, and a run that names them was still appending a PATH line and a
    # profile-source line to $HOME/.profile. When the throwaway root is removed,
    # the user's login shell is left prepending a dead exec bin and sourcing a
    # dead fragment - a login change the caller never asked for. The rule:
    # a run that names either root is isolated and touches no login file unless
    # the caller also asks for it with SANDHOME_LOGIN=1 (or --login). The
    # default run, and any run with no --home/--exec, is unchanged.
    #
    # # STOP: THE GLOBAL HOOK IS A PATH CHANGE TOO, AND IT WAS LEFT ON (issue
    # #196). Disabling the profile and the PATH line was the whole of the first
    # fix, but sh_bootstrap_install_global still ran, so a named-root run wrote
    # .sandhome-dispatch and a baked `sandhome` into the FIRST writable
    # directory on the caller's real PATH (measured: $HOME/.local/bin), with the
    # dispatcher carrying the throwaway exec root. Removing the root left a dead
    # hook in every new shell - the same harm as the dead profile line, one
    # directory over. A named root is isolated, so the hook is skipped with the
    # login files unless SANDHOME_LOGIN=1 asks for the whole login change.
    if [ -n "$SH_HOME_ARG" ] || [ -n "$SH_EXEC_ARG" ]; then
        : "${SANDHOME_LOGIN:=0}"
        case "$SANDHOME_LOGIN" in
            1|yes|on|true) : ;;
            *)
                case "$SH_PROFILE" in
                    none) : ;;
                    *) sh_say 'named --home/--exec: leaving the login files alone (set SANDHOME_LOGIN=1 to install them)' ;;
                esac
                SH_PROFILE=none
                SH_PATH_LINE=none
                ;;
        esac
        # # STOP: THE GLOBAL HOOK IS OUTSIDE THE NAMED ROOT, AND IT IS STILL
        # INSTALLED (issue #196). The #192 isolation covers the login FILES;
        # the hook is independent, and tests/global.sh and tests/consumer.sh
        # rely on a named --exec run installing it (SANDHOME_GLOBAL=install is
        # also an explicit ask, so it must be honoured). What was missing is a
        # word: the run writes .sandhome-dispatch into a directory on the
        # caller's real PATH, bakes the named exec root into it, and REPOINTS a
        # previous working hook at that root. When the named root is a
        # throwaway, removing it leaves a dead hook in every new shell - the
        # same harm as the dead profile line, one directory over - and nothing
        # in the output says `--no-global` is the way to avoid it. The warning
        # is the fix; the behaviour stays, because forbidding it would break
        # the caller who named a persistent root and asked for the hook.
        case "${SH_GLOBAL:-install}" in
            none) : ;;
            *)
                case "$SANDHOME_LOGIN" in
                    1|yes|on|true) : ;;
                    *) sh_say 'named --home/--exec: the global hook is still installed and will point at the named exec root; pass --no-global (or SANDHOME_GLOBAL=none) to leave the caller PATH alone' ;;
                esac
                ;;
        esac
    fi
    sh_bootstrap_path_line
    sh_bootstrap_install_profile || true
    sh_bootstrap_install_global || true
    # The scratch tree served its purpose once the durable copy exists;
    # remove it so failed and partial runs do not accumulate under /tmp.
    if [ -n "${SANDHOME_FETCH_DIR:-}" ] && [ "${SANDHOME_FETCH_DIR:-}" != "$SH_REPO_DIR" ]; then
        rm -rf "${SANDHOME_FETCH_DIR:-/nonexistent}" 2>/dev/null || true
    fi
    if [ -n "${SH_FETCH_DIR:-}" ] && [ "${SH_FETCH_DIR:-}" != "$SH_REPO_DIR" ]; then
        rm -rf "${SH_FETCH_DIR:-/nonexistent}" 2>/dev/null || true
    fi

    SH_INSTALLED=$INSTALLED
    SH_ADOPTED=$ADOPTED
    if [ "$SH_JSON" = 1 ]; then
        sh_report_json
    else
        sh_report_text
    fi
    if [ "$SH_FAILURES" -gt 0 ]; then
        return 1
    fi
    return 0
}

if [ -z "$SH_NO_RUN" ]; then
    sandhome_bootstrap_main "$@"
    status=$?
    if [ -n "$SH_FETCH_DIR" ]; then
        rm -rf "$SH_FETCH_DIR" 2>/dev/null || true
    fi
    exit "$status"
fi
