#!/bin/sh
# deno - the Deno runtime, from the official denoland/deno release zip.
TC_deno_DESC='Deno, a TypeScript/JavaScript runtime (single binary, from GitHub)'
TC_deno_BINS='deno'

tc_deno_probe() {
    sh_have deno && deno --version >/dev/null 2>&1
}

tc_deno_install() {
    sh_di_root=$(sh_toolchain_root deno)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_di_triple=x86_64-unknown-linux-gnu ;;
        Linux:aarch64|Linux:arm64)  sh_di_triple=aarch64-unknown-linux-gnu ;;
        Darwin:x86_64)              sh_di_triple=x86_64-apple-darwin ;;
        Darwin:arm64)               sh_di_triple=aarch64-apple-darwin ;;
        *) sh_warn "no deno build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_di_tag=$(sh_github_latest_tag denoland/deno)
    case "$sh_di_tag" in
        v[0-9]*) ;;
        *) sh_warn 'could not resolve the current deno release'; return 1 ;;
    esac
    sh_di_name="deno-${sh_di_triple}"
    sh_di_base="https://github.com/denoland/deno/releases/download/${sh_di_tag}"
    sh_di_url="${sh_di_base}/${sh_di_name}.zip"
    sh_di_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_di_stage" 2>/dev/null || return 1
    sh_space_need 300 home || return 1
    sh_space_need 150 exec || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_di_url into $sh_di_root"
        return 0
    fi
    # The release publishes a .sha256sum sidecar next to each asset, so the
    # download is held to the publisher's digest as well as to any caller pin.
    sh_di_sha=''
    sh_di_sum="$sh_di_stage/deno-sum.$$"
    if sh_fetch "${sh_di_base}/${sh_di_name}.zip.sha256sum" "$sh_di_sum"; then
        read -r sh_di_sha _ < "$sh_di_sum" || :
        sh_is_hex64 "$sh_di_sha" || sh_di_sha=''
        rm -f "$sh_di_sum" 2>/dev/null
    fi
    rm -rf "$sh_di_root" 2>/dev/null
    mkdir -p "$sh_di_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_di_url" "$sh_di_root" "$sh_di_sha" deno; then
        return 1
    fi
    if [ ! -x "$sh_di_root/deno" ]; then
        sh_warn "the deno archive did not put deno at $sh_di_root/deno"
        return 1
    fi
    return 0
}

tc_deno_version() {
    sh_have deno && sh_first_line deno --version 2>/dev/null
}
