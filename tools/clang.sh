#!/bin/sh
# clang - Clang/LLVM, from the official LLVM release tarball.
#
# NOTE: THIS IS THE >1GB TOOLCHAIN, AND IT IS WHY THE FETCH PATH SHARDS. The
# x86_64 tarball is about 1.9GB, well past the 1GB RLIMIT_FSIZE measured on a
# sandbox and past every single-file limit a process can raise. The install goes
# through sh_fetch_unpack, which fetches ranges into parts under the limit and
# unpacks from the concatenated stream, so no file bigger than the limit is ever
# written. The view is large (the LLVM binaries are hundreds of MB), so the exec
# floor is deliberately high; on a small exec root the install refuses by name
# rather than filling it.
TC_clang_DESC='Clang/LLVM, from the official LLVM release tarball (a >1GB download)'
TC_clang_BINS='bin/clang bin/clang++'

tc_clang_probe() {
    sh_have clang && clang --version >/dev/null 2>&1
}

tc_clang_adopted() {
    sh_ca_which=$(command -v clang 2>/dev/null)
    [ -n "$sh_ca_which" ] || return 0
    sh_ca_dir=${sh_ca_which%/*}
    [ -n "$sh_ca_dir" ] || sh_ca_dir=.
    ( CDPATH='' cd -- "$sh_ca_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_ca_dir"
}

tc_clang_install() {
    sh_ci_root=$(sh_toolchain_root clang)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)  sh_ci_arch=X64 ;;
        Linux:aarch64|Linux:arm64) sh_ci_arch=ARM64 ;;
        *) sh_warn "no LLVM release tarball for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_ci_tag=${SANDHOME_LLVM_TAG:-$(sh_github_latest_tag llvm/llvm-project)}
    case "$sh_ci_tag" in
        llvmorg-[0-9]*) ;;
        *) sh_warn 'could not resolve the current LLVM release'; return 1 ;;
    esac
    sh_ci_ver=${sh_ci_tag#llvmorg-}
    sh_ci_asset="LLVM-${sh_ci_ver}-Linux-${sh_ci_arch}.tar.xz"
    sh_ci_url="https://github.com/llvm/llvm-project/releases/download/${sh_ci_tag}/${sh_ci_asset}"
    # The x86_64 tree extracted to ~12GB here, plus ~1.9GB of parts held at the
    # same time, and a view in the hundreds of MB; both roots are named so a
    # small host refuses before spending the transfer.
    sh_space_need 16000 home || return 1
    sh_space_need 3000 exec || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_ci_url into $sh_ci_root"
        return 0
    fi
    rm -rf "$sh_ci_root" 2>/dev/null
    mkdir -p "$sh_ci_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_ci_url" "$sh_ci_root" '' clang; then
        return 1
    fi
    if [ ! -x "$sh_ci_root/bin/clang" ] && [ ! -x "$sh_ci_root/bin/clang++" ]; then
        sh_warn "the LLVM archive did not put clang under $sh_ci_root/bin"
        return 1
    fi
    return 0
}

tc_clang_version() {
    sh_have clang && sh_first_line clang --version 2>/dev/null
}
