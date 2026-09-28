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
    for sh_fr_owner in "$SH_REPO_OWNER" talaria0101/sandhome; do
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
    if sh_fr_runs curl --version; then
        if curl -fSL --retry 3 --retry-delay 2 -o "$2" "$1" 2>/dev/null && [ -s "$2" ]; then
            sh_fr_tool=curl
            printf 'bootstrap: fetched with curl from %s\n' "$1" >&2
            return 0
        fi
        printf 'bootstrap: curl could not fetch %s; trying the next downloader\n' "$1" >&2
    fi
    if sh_fr_runs wget --help; then
        if wget -q -O "$2" "$1" 2>/dev/null && [ -s "$2" ]; then
            sh_fr_tool=wget
            printf 'bootstrap: fetched with wget from %s\n' "$1" >&2
            return 0
        fi
        printf 'bootstrap: wget could not fetch %s; trying the next downloader\n' "$1" >&2
    fi
    if command -v fetch >/dev/null 2>&1; then
        if fetch -q -o "$2" "$1" 2>/dev/null && [ -s "$2" ]; then
            sh_fr_tool=fetch
            printf 'bootstrap: fetched with fetch from %s\n' "$1" >&2
            return 0
        fi
        printf 'bootstrap: fetch could not fetch %s\n' "$1" >&2
    fi
    printf 'bootstrap: [-] no curl, wget or fetch on PATH, so nothing can be downloaded\n' >&2
    printf 'bootstrap:     install one of them first: apt-get install curl, apk add curl,\n' >&2
    printf 'bootstrap:     dnf install curl, or pacman -S curl\n' >&2
    return 1
}

# ---------------------------------------------------------------- usage --
usage() {
    cat <<'USAGE'
usage: sh bootstrap.sh [options]

  --toolset NAME      minimal | cli | developer | languages | agent.
                      Default developer.
  --with NAME         add a toolchain. Repeatable, and also takes a
                      comma-separated list.
  --without NAME      leave a toolchain out. Repeatable, and also takes a
                      comma-separated list.
  --list-toolchains   print the known names and exit
  --home DIR          persistent data root. Default $XDG_DATA_HOME/sandhome
  --exec DIR          exec-capable root. Default: detected (see sandhome space)
  --no-shims          do not build the LD_PRELOAD shims
  --require-shims     refuse to finish when a needed shim could not be built
  --no-shell          do not install errandsh
  --no-profile        do not install the profile fragment or touch login files
  --no-path-line      do not add the exec bin directory to the login files
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
  SANDHOME_REF        branch or tag to fetch. Default main
  SANDHOME_SHA256     a default digest for any download that has no pin of its
                      own. Prefer the per-download forms below, which do not
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
USAGE
}

# ------------------------------------------------------------------- library --
sh_load_library() {
    SH_LIB_DIR="$SH_SELF_DIR/lib"
    SH_REPO_DIR="$SH_SELF_DIR"
    export SH_LIB_DIR SH_REPO_DIR
    for sh_ll_mod in common detect space fetch env toolchain shim report; do
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
SH_WITH=''
SH_WITHOUT=''
SH_HOME_ARG=''
SH_EXEC_ARG=''
SH_SHIMS=build
SH_NEED_SHIMS=0
SH_SHELL=install
SH_PROFILE=install
SH_PATH_LINE=install
SH_JSON=0

sh_need_value() {
    if [ "$#" -lt 2 ]; then
        printf 'bootstrap: [-] %s needs a value\n' "$1" >&2
        exit 2
    fi
}

sh_toolset_names() {
    case "$1" in
        minimal)   printf 'jq\n' ;;
        cli)       printf 'jq ripgrep fd\n' ;;
        developer) printf 'jq ripgrep fd python node\n' ;;
        languages) printf 'jq ripgrep fd python node rust go zig deno bun mold\n' ;;
        agent)     printf 'jq ripgrep fd python node rust go zig deno bun mold\n' ;;
        *)         return 1 ;;
    esac
}

sh_bootstrap_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --toolset)         sh_need_value "$@"; SH_TOOLSET=$2; shift 2 ;;
            --with)            sh_need_value "$@"; SH_WITH="$SH_WITH,$2"; shift 2 ;;
            --without)         sh_need_value "$@"; SH_WITHOUT="$SH_WITHOUT,$2"; shift 2 ;;
            --list-toolchains) for sh_ba_t in $(sh_toolchain_available); do
                                   printf '%s\n' "$sh_ba_t"
                               done
                               exit 0 ;;
            --home)            sh_need_value "$@"; SH_HOME_ARG=$2; shift 2 ;;
            --exec)            sh_need_value "$@"; SH_EXEC_ARG=$2; shift 2 ;;
            --no-shims)        SH_SHIMS=none; shift ;;
            --require-shims)   SH_NEED_SHIMS=1; shift ;;
            --no-shell)        SH_SHELL=none; shift ;;
            --no-profile)      SH_PROFILE=none; shift ;;
            --no-path-line)    SH_PATH_LINE=none; shift ;;
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
    cp -f "$sh_bic_src" "$SH_EXEC_BIN/sandhome" || {
        sh_fail 'could not install sandhome onto the exec root'
        return 1
    }
    chmod 0755 "$SH_EXEC_BIN/sandhome" 2>/dev/null || true
    sh_step "installed $SH_EXEC_BIN/sandhome"
    return 0
}

sh_bootstrap_path_line() {
    if [ "$SH_PATH_LINE" = none ] || [ "$SH_DRY_RUN" = 1 ]; then
        return 0
    fi
    sh_bpl_line="export PATH=\"$SH_EXEC_BIN:\$PATH\""
    # The prefix is what makes this line replaceable: without it a re-run that
    # moves the exec root appends a second PATH block and leaves the superseded
    # root first on PATH, where it still wins (issue #41).
    sh_append_login "$sh_bpl_line" "$SH_EXEC_BIN" 'export PATH="'
    sh_append_rc "$sh_bpl_line" "$SH_EXEC_BIN" 'export PATH="'
    return 0
}

sh_bootstrap_install_profile() {
    if [ "$SH_PROFILE" = none ]; then
        return 0
    fi
    sh_install_profile "$SH_REPO_DIR/lib/profile.sh"
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
    # # NOTE: PICK UP WHAT AN EARLIER RUN INSTALLED BEFORE DECIDING WHAT TO INSTALL.
    # Without this, the second bootstrap of an already-set-up sandbox downloads
    # jq again because its probe ran against a PATH that did not yet carry the
    # exec view. Adoption is the common case on a long-lived base.
    sh_env_load

    sh_say "$SH_OS_ID on $SH_KERNEL $SH_ARCH, $SH_LIBC, wsl=$SH_WSL, privilege=$SH_PRIVILEGE"
    sh_say "pty=$SH_PTY passwd=$SH_PASSWD"
    if [ "$SH_HOME_EXEC" = yes ]; then
        sh_say "home and exec are the same root: $SH_HOME"
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

    for sh_mb_name in $sh_mb_wanted; do
        sh_toolchain_ensure "$sh_mb_name" || true
    done

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
            for sh_mb_shim in fakepty fakepwd; do
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
    # Durable library (issue #20): the network-only path runs from a scratch
    # tree under /tmp that the reaper, a reboot, or gc removes, after which
    # every `sandhome` call exits 2. See sh_repo_persist in lib/env.sh.
    sh_repo_persist || true
    sh_env_write
    sh_env_load
    sh_bootstrap_path_line
    sh_bootstrap_install_profile || true
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
