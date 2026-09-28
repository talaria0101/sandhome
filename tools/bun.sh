#!/bin/sh
# bun - the Bun JavaScript/TypeScript runtime, from the official oven-sh/bun zip.
TC_bun_DESC='Bun, a JavaScript/TypeScript runtime and toolkit (single binary)'
TC_bun_BINS='bun'

tc_bun_probe() {
    sh_have bun && bun --version >/dev/null 2>&1
}

tc_bun_install() {
    sh_bi_root=$(sh_toolchain_root bun)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)  sh_bi_arch=x64 ;;
        Linux:aarch64|Linux:arm64) sh_bi_arch=aarch64 ;;
        *) sh_warn "no bun build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_bi_extra=''
    [ "${SH_LIBC:-unknown}" = musl ] && sh_bi_extra='-musl'
    sh_bi_tag=$(sh_github_latest_tag oven-sh/bun)
    case "$sh_bi_tag" in
        bun-v*) ;;
        *) sh_warn 'could not resolve the current bun release'; return 1 ;;
    esac
    sh_bi_url="https://github.com/oven-sh/bun/releases/download/${sh_bi_tag}/bun-linux-${sh_bi_arch}${sh_bi_extra}.zip"
    sh_space_need 400 home || return 1
    sh_space_need 200 exec || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_bi_url into $sh_bi_root"
        return 0
    fi
    rm -rf "$sh_bi_root" 2>/dev/null
    mkdir -p "$sh_bi_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_bi_url" "$sh_bi_root" '' bun; then
        return 1
    fi
    if [ ! -x "$sh_bi_root/bun" ]; then
        sh_warn "the bun archive did not put bun at $sh_bi_root/bun"
        return 1
    fi
    return 0
}

tc_bun_version() {
    sh_have bun && sh_first_line bun --version 2>/dev/null
}
