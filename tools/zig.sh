#!/bin/sh
# zig - zig cc as a portable cross compiler and linker, from the official tarball.
#
# NOTE: THE TARBALL URL AND DIGEST COME FROM index.json, NOT FROM A NAME BUILT BY
# THIS MODULE. Zig renamed its assets between releases (`zig-linux-x86_64-<v>`
# became `zig-x86_64-linux-<v>`), and the old code built the URL from the old
# pattern, so a current release fetched a 404 and the failure blamed the mirror.
# The index already publishes the tarball and shasum for every platform; reading
# them is both shorter and correct across the rename, and it turns the
# publisher's own digest into a real check.
TC_zig_DESC='zig cc cross compiler and linker, from the official tarball'
TC_zig_BINS='zig'

# tc_zig_resolve PLATFORM [VERSION] -> "VERSION URL SHA" for PLATFORM
# (`x86_64-linux`), the newest STABLE release by default. The first top-level key
# in index.json is `master`, a dev build whose tarball lives under /builds/ and
# whose version carried `-dev`; the old parser took it and built a /download/
# URL that does not exist.
tc_zig_resolve() {
    sh_zr_platform=$1
    sh_zr_want=${2:-}
    sh_zr_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_zr_stage" 2>/dev/null || { printf ''; return 0; }
    sh_zr_file="$sh_zr_stage/.zig-index.$$"
    if ! sh_fetch "${SANDHOME_ZIG_INDEX_URL:-https://ziglang.org/download/index.json}" "$sh_zr_file"; then
        printf ''
        return 0
    fi
    sh_zr_ver=''
    sh_zr_url=''
    sh_zr_sha=''
    sh_zr_state=0
    sh_zr_have_ver=0
    while IFS= read -r sh_zr_l || [ -n "$sh_zr_l" ]; do
        case "$sh_zr_l" in
            '  "'*)
                # A top-level key (two-space indent). Once a version is chosen,
                # the next one ends its object.
                if [ "$sh_zr_have_ver" = 1 ]; then
                    break
                fi
                sh_zr_k=${sh_zr_l#  \"}
                sh_zr_k=${sh_zr_k%%\"*}
                case "$sh_zr_k" in
                    master) : ;;
                    *[!0-9.]*) : ;;
                    [0-9]*.[0-9]*.[0-9]*)
                        if [ -z "$sh_zr_want" ] || [ "$sh_zr_k" = "$sh_zr_want" ]; then
                            sh_zr_ver=$sh_zr_k
                            sh_zr_have_ver=1
                        fi ;;
                esac
                ;;
            '    "'*)
                # A four-space key inside the chosen version's object. The
                # platform block is the first one whose key matches, but ONLY
                # once a stable version has been chosen: master's own platform
                # block comes first in the file, and selecting it is the bug
                # this guard exists for.
                if [ "$sh_zr_have_ver" = 1 ] && [ "$sh_zr_state" = 0 ]; then
                    sh_zr_k2=${sh_zr_l#    \"}
                    sh_zr_k2=${sh_zr_k2%%\"*}
                    if [ "$sh_zr_k2" = "$sh_zr_platform" ]; then
                        sh_zr_state=1
                    fi
                fi
                ;;
            *)
                if [ "$sh_zr_state" = 1 ]; then
                    case "$sh_zr_l" in
                        *'"tarball"'*)
                            sh_zr_u=${sh_zr_l#*\"tarball\"}
                            sh_zr_u=${sh_zr_u#*:}
                            sh_zr_u=${sh_zr_u#*\"}
                            sh_zr_url=${sh_zr_u%%\"*} ;;
                        *'"shasum"'*)
                            sh_zr_s=${sh_zr_l#*\"shasum\"}
                            sh_zr_s=${sh_zr_s#*:}
                            sh_zr_s=${sh_zr_s#*\"}
                            sh_zr_sha=${sh_zr_s%%\"*}
                            sh_zr_state=2
                            break ;;
                    esac
                fi
                ;;
        esac
    done < "$sh_zr_file"
    rm -f "$sh_zr_file" 2>/dev/null
    printf '%s %s %s' "$sh_zr_ver" "$sh_zr_url" "$sh_zr_sha"
}

tc_zig_probe() {
    sh_have zig && zig version >/dev/null 2>&1
}

tc_zig_install() {
    sh_zi_root=$(sh_toolchain_root zig)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_zi_plat=x86_64-linux ;;
        Linux:aarch64|Linux:arm64)  sh_zi_plat=aarch64-linux ;;
        Darwin:x86_64)              sh_zi_plat=x86_64-macos ;;
        Darwin:arm64)               sh_zi_plat=aarch64-macos ;;
        *) sh_warn "no zig tarball for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_zi_line=$(tc_zig_resolve "$sh_zi_plat" "${SANDHOME_ZIG_VERSION:-}")
    sh_zi_ver=${sh_zi_line%% *}
    sh_zi_rest=${sh_zi_line#* }
    sh_zi_url=${sh_zi_rest%% *}
    sh_zi_sha=${sh_zi_rest#* }
    case "$sh_zi_url" in
        https://*) ;;
        *) sh_warn 'could not resolve the current zig release'; return 1 ;;
    esac
    # The zig binary is about 180MB and the extracted tree is larger; both roots
    # are gated before anything is written.
    sh_space_need 400 home || return 1
    sh_space_need 200 exec || {
        sh_warn "no exec root with 200MB free for zig; set SANDHOME_EXEC to a roomy root (--exec DIR)"
        return 1
    }
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_zi_url into $sh_zi_root"
        return 0
    fi
    rm -rf "$sh_zi_root" 2>/dev/null
    mkdir -p "$sh_zi_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_zi_url" "$sh_zi_root" "$sh_zi_sha" zig; then
        return 1
    fi
    if [ ! -x "$sh_zi_root/zig" ]; then
        sh_warn "the zig archive did not put zig at $sh_zi_root/zig"
        return 1
    fi
    return 0
}

tc_zig_env() {
    return 0
}

tc_zig_version() {
    sh_have zig && sh_first_line zig version 2>/dev/null
}
