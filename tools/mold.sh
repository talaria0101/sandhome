#!/bin/sh
# mold - the mold linker, from the official rui314/mold release tarball.
TC_mold_DESC='mold, a fast ELF linker (gcc/clang/rust via -fuse-ld=mold)'
TC_mold_BINS='bin/mold bin/ld.mold'

tc_mold_probe() {
    sh_have mold && mold --version >/dev/null 2>&1
}

tc_mold_install() {
    sh_mi_root=$(sh_toolchain_root mold)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)  sh_mi_arch=x86_64 ;;
        Linux:aarch64|Linux:arm64) sh_mi_arch=aarch64 ;;
        Linux:armv7l|Linux:arm)    sh_mi_arch=arm ;;
        Linux:riscv64)             sh_mi_arch=riscv64 ;;
        Linux:s390x)               sh_mi_arch=s390x ;;
        Linux:ppc64le)             sh_mi_arch=ppc64le ;;
        *) sh_warn "no mold tarball for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_mi_ver=${SANDHOME_MOLD_VERSION:-$(sh_github_latest_tag rui314/mold)}
    case "$sh_mi_ver" in
        v[0-9]*) ;;
        *) sh_warn 'could not resolve the current mold release'; return 1 ;;
    esac
    sh_mi_name="mold-${sh_mi_ver#v}-${sh_mi_arch}-linux"
    sh_mi_url="https://github.com/rui314/mold/releases/download/${sh_mi_ver}/${sh_mi_name}.tar.gz"
    sh_space_need 120 home || return 1
    sh_space_need 60 exec || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_mi_url into $sh_mi_root"
        return 0
    fi
    rm -rf "$sh_mi_root" 2>/dev/null
    mkdir -p "$sh_mi_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_mi_url" "$sh_mi_root" '' mold; then
        return 1
    fi
    if [ ! -x "$sh_mi_root/bin/mold" ]; then
        sh_warn "the mold archive did not put mold at $sh_mi_root/bin/mold"
        return 1
    fi
    return 0
}

tc_mold_version() {
    sh_have mold && sh_first_line mold --version 2>/dev/null
}
