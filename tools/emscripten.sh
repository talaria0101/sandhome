#!/bin/sh
# emscripten - the Emscripten SDK (emcc) for wasm32-unknown-emscripten, via emsdk.
#
# WHY A MODULE, NOT A DOC ROW. Adding the rust target is necessary but not
# sufficient: wasm32-unknown-emscripten links with `emcc`, a separate ~640MB
# toolchain with its own LLVM/Binaryen and its own EM_CONFIG, and without it
# `cargo build --target wasm32-unknown-emscripten` dies with
# `linker 'emcc' not found`, which reads like a broken PATH rather than a
# missing toolchain (issue #163). The tree used to document that gap and stop;
# this module closes it: `sandhome install emscripten` provisions the linker,
# writes an EM_CONFIG whose paths point at the exec view (where the native
# tools can execve), and sets the cargo linker variable, so the rust target
# becomes a working link rather than a legible error.
#
# THE LAYOUT. emsdk is a version manager: the checkout holds emsdk.py and the
# installed SDK lands under it (node/, upstream/). The payload lives on the
# home (sh_toolchain_root emscripten) and the view mirrors it onto the exec
# root; EM_CONFIG is written beside the view with view paths, because the
# home may refuse execve and a config pointing there would hand emcc native
# tools it cannot run. The env fragment points PATH at the view's
# upstream/emscripten (emcc, em++) and upstream/bin (wasm-ld, binaryen).
TC_emscripten_DESC='Emscripten SDK (emcc) for wasm32-unknown-emscripten, via emsdk'
TC_emscripten_BINS='upstream/emscripten/emcc upstream/emscripten/em++'
TC_emscripten_EXEC_MB=900

# tc_emscripten_copy_bins -> emcc AND em++ MUST BE REAL COPIES IN THE VIEW, IN
# EVERY VIEW MODE, INCLUDING LAUNCH (issue #169).
#
# Both are `#!/bin/sh` wrappers whose final line is
#   exec "$PYTHON" -E "$0.py" "$@"
# so the SDK's own JavaScript next to them is located THROUGH $0. A launch-mode
# view does not put the script there at all: the helper copies the payload into
# a memfd and execve's /proc/self/fd/N, so the kernel runs
#   /bin/sh /proc/self/fd/N
# and the script's $0 is /proc/self/fd/N. `$0.py` then names /proc/self/fd/N.py,
# which is not a file that exists, and the measured failure is:
#   /usr/bin/python3: can't open file '/proc/self/fd/3.py': [Errno 2] No such file or directory
# `sandhome install emscripten` therefore failed its OWN post-install probe and
# doctor ended `FAIL toolchain_emscripten=no (wanted yes)` while the SDK itself
# was complete and fine. The install was refusing to hand over a working SDK.
#
# Only emcc and em++ are named, and that is not a guess: they are the only two
# entries in TC_emscripten_BINS, so they are the only two files exec'd by name.
# A real copy keeps $0 the view path, so $0.py is the view's link to the home's
# emcc.py, and python only ever READS that file, which a noexec home allows.
#
# NOTE THIS IS NOT THE SAME FIX AS THE GENERAL ONE IN lib/space.sh. That one
# stops the promote from stamping INTERPRETER SOURCE with a launcher (issue
# #173), which is a correctness fix for data a reader must open. This is the
# mirror image: a wrapper that a launcher can run perfectly well but that
# resolves its own neighbours through $0 needs to be SUMMONED BY ITS OWN PATH.
# Copying is the only shape that keeps that path. See sh_copy_listed.

tc_emscripten_copy_bins() {
    printf 'upstream/emscripten/emcc upstream/emscripten/em++'
}

# tc_emscripten_release -> the SDK release to install. Pinned, not latest: a
# moving default turns a 640MB fetch into a surprise on every reinstall, and
# the rust lockfile pins its own wasm-bindgen beside it. Override with
# SANDHOME_EMSDK_VERSION. Measured working: 3.1.73 and the 4.x line; the
# default below is the one the issue measured end to end.
tc_emscripten_release() {
    printf '%s' "${SANDHOME_EMSDK_VERSION:-3.1.73}"
}

tc_emscripten_probe() {
    sh_have emcc && emcc --version >/dev/null 2>&1
}

# tc_emscripten_adopted -> where a working emcc already lives, or nothing. An
# emcc on PATH with a readable EM_CONFIG is adopted like any other toolchain:
# the fragment below still points cargo at it, so `install emscripten` on a
# host that already has one is a no-op that records the linker.
tc_emscripten_adopted() {
    sh_ea_bin=''
    if sh_have emcc; then
        sh_ea_bin=$(command -v emcc 2>/dev/null)
    fi
    case "$sh_ea_bin" in
        ?*) printf '%s' "${sh_ea_bin%/*}" ;;
    esac
}

tc_emscripten_install() {
    sh_ei_root=$(sh_toolchain_root emscripten)
    sh_ei_ver=$(tc_emscripten_release)
    case "$sh_ei_ver" in
        ''|*[!0-9.A-Za-z_-]*) sh_warn "bad emsdk version '$sh_ei_ver'"; return 1 ;;
    esac
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64) ;;
        Linux:aarch64|Linux:arm64) ;;
        *) sh_warn "no emsdk build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    if ! sh_have python3 && ! sh_have python; then
        sh_warn 'emsdk needs python3 and none is on PATH'
        return 1
    fi
    # The SDK is ~640MB installed plus the download; both roots are gated
    # before anything is written, and the need is said out loud while the
    # operator is still choosing roots.
    sh_space_need 900 home || return 1
    sh_space_need 900 exec || {
        sh_warn "no exec root with 900MB free for emscripten; set SANDHOME_EXEC to a roomy root (--exec DIR)"
        return 1
    }
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install emsdk $sh_ei_ver into $sh_ei_root"
        return 0
    fi
    rm -rf "$sh_ei_root" 2>/dev/null
    mkdir -p "$sh_ei_root" 2>/dev/null || return 1
    # REDUNDANCY: CLONE FIRST, TARBALL SECOND. A git clone carries the exact
    # emsdk.py the release was tested with; when git is absent or the network
    # refuses it, the GitHub tarball unpacks through sh_tar, which drops
    # archive ownership first (a uid-0 sandbox without CAP_CHOWN refuses
    # tar's chown and exits 2 after a good download, issue #162). Either path
    # leaves the same checkout behind, so the steps below cannot tell which
    # one ran.
    sh_ei_have=no
    if sh_have git && git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$sh_ei_root/emsdk" >/dev/null 2>&1; then
        sh_ei_have=yes
    else
        rm -rf "$sh_ei_root/emsdk" 2>/dev/null
        mkdir -p "$sh_ei_root/emsdk" 2>/dev/null || return 1
        sh_ei_tar=${SH_HOME_TMP:-${TMPDIR:-/tmp}}/.emsdk.$$
        if sh_fetch "https://github.com/emscripten-core/emsdk/archive/main.tar.gz" "$sh_ei_tar" && \
           sh_tar -xzf "$sh_ei_tar" -C "$sh_ei_root" 2>/dev/null; then
            for sh_ei_d in "$sh_ei_root"/emsdk-*; do
                [ -d "$sh_ei_d" ] || continue
                rm -rf "$sh_ei_root/emsdk" 2>/dev/null
                mv "$sh_ei_d" "$sh_ei_root/emsdk" 2>/dev/null && sh_ei_have=yes
                break
            done
        fi
        rm -f "$sh_ei_tar" 2>/dev/null
    fi
    if [ "$sh_ei_have" != yes ] || [ ! -r "$sh_ei_root/emsdk/emsdk.py" ]; then
        sh_warn 'could not fetch emsdk (need git or a working tar+gzip path here)'
        rm -rf "$sh_ei_root" 2>/dev/null
        return 1
    fi
    sh_ei_py=python3
    sh_have python3 || sh_ei_py=python
    # Install then activate: the first fetches the SDK, the second writes the
    # .emscripten config the link reads. Both run inside the checkout so no
    # step depends on the caller's cwd.
    if ! ( cd "$sh_ei_root/emsdk" && "$sh_ei_py" emsdk.py install "$sh_ei_ver" ) >/dev/null 2>&1; then
        sh_warn "emsdk.py install $sh_ei_ver failed; run it by hand in $sh_ei_root/emsdk for the real error"
        return 1
    fi
    if ! ( cd "$sh_ei_root/emsdk" && "$sh_ei_py" emsdk.py activate "$sh_ei_ver" ) >/dev/null 2>&1; then
        sh_warn "emsdk.py activate $sh_ei_ver failed; run it by hand in $sh_ei_root/emsdk for the real error"
        return 1
    fi
    if [ ! -x "$sh_ei_root/emsdk/upstream/emscripten/emcc" ]; then
        sh_warn "emsdk installed $sh_ei_ver but upstream/emscripten/emcc is not executable"
        return 1
    fi
    return 0
}

# tc_emscripten_write_config VIEW ROOT -> write EM_CONFIG beside the view with
# view paths. emsdk activate writes .emscripten with the payload's absolute
# paths; on a split root those point at the home that refuses execve, so the
# native node/llvm/binaryen it names cannot run. The view mirror holds the
# same bytes on the exec root, so the config is rewritten to name the view.
# Both the generated file (when present) and a minimal fallback are handled:
# a checkout whose activate wrote nothing still yields a working config.
tc_emscripten_write_config() {
    sh_ew_view=$1
    sh_ew_root=$2
    [ -n "$sh_ew_view" ] || return 1
    sh_ew_dir="$SH_EXEC/emscripten"
    mkdir -p "$sh_ew_dir" 2>/dev/null || return 1
    # Explicit writer: names the view's node, llvm and binaryen. EMSDK, LLVM
    # and BINARYEN roots are the three the emcc driver reads; NODE is the
    # fourth it execs on every link. An activate-generated .emscripten with
    # payload-absolute paths is not copied: on a split root those point at the
    # home that refuses execve, so the native tools it names cannot run. The
    # view mirror holds the same bytes on the exec root, so view paths are
    # written instead.
    # One NODE_JS line, decided before writing: the SDK-provisioned node when
    # it exists and executes, else the view's node, else PATH's. Two NODE_JS
    # lines would leave the winner to file order instead of to this choice.
    sh_ew_node="$sh_ew_view/emsdk/node/bin/node"
    if [ ! -x "$sh_ew_node" ]; then
        if [ -x "$sh_ew_view/node/bin/node" ]; then
            sh_ew_node="$sh_ew_view/node/bin/node"
        elif sh_have node; then
            sh_ew_node=$(command -v node 2>/dev/null)
        else
            sh_ew_node="$sh_ew_view/emsdk/node/bin/node"
        fi
    fi
    {
        printf '# generated by sandhome; EM_CONFIG for the exec view.\n'
        printf 'EMSDK = %s\n' "'$sh_ew_view/emsdk'"
        printf 'LLVM_ROOT = %s\n' "'$sh_ew_view/emsdk/upstream/bin'"
        printf 'BINARYEN_ROOT = %s\n' "'$sh_ew_view/emsdk/upstream'"
        printf 'NODE_JS = %s\n' "'$sh_ew_node'"
        printf 'EM_CONFIG = %s\n' "'$sh_ew_dir/.emscripten'"
    } > "$sh_ew_dir/.emscripten" 2>/dev/null || return 1
    unset sh_ew_node
    printf '%s' "$sh_ew_dir/.emscripten"
}

tc_emscripten_env() {
    sh_ee_root=$(sh_toolchain_root emscripten)
    sh_ee_view=$(sh_toolchain_view emscripten)
    sh_ee_adopted=$(tc_emscripten_adopted)
    if [ ! -d "$sh_ee_root/emsdk" ] && [ -z "$sh_ee_adopted" ]; then
        return 0
    fi
    # Adopted emcc: no view, no config to write. The linker variable is still
    # owed, because `rustup target add` succeeding is not a link promise and
    # the failure without it reads like a broken PATH (issue #163).
    if [ ! -d "$sh_ee_root/emsdk" ]; then
        sh_ee_abin=${sh_ee_adopted%/*}
        sh_env_write_fragment emscripten <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
case ":\$PATH:" in
  *":$sh_ee_abin:"*) ;;
  *) PATH="$sh_ee_abin:\$PATH" ;;
esac
export PATH
CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER="\${CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER:-emcc}"
export CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER
EOF
        return $?
    fi
    sh_ee_cfg=$(tc_emscripten_write_config "$sh_ee_view" "$sh_ee_root")
    [ -n "$sh_ee_cfg" ] || {
        sh_warn "could not write the emscripten config beside the view"
        return 1
    }
    sh_env_write_fragment emscripten <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
EMSDK="\$SANDHOME_EXEC/emscripten/emsdk"
EM_CONFIG="\$SANDHOME_EXEC/emscripten/.emscripten"
CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER="\${CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER:-emcc}"
export EMSDK EM_CONFIG CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER
case ":\$PATH:" in
  *":$sh_ee_view/emsdk/upstream/emscripten:"*) ;;
  *) PATH="${PATH:+\$PATH:}$sh_ee_view/emsdk/upstream/emscripten" ;;
esac
# STOP: THE SDK'S LLVM BIN DIR IS APPENDED, NOT PREPENDED, AND THE EMPTY-PATH
# FORM MATTERS (issue #171). This used to PREPEND upstream/bin, which holds
# clang/clang++ beside wasm-ld and the Binaryen tools, so plain clang resolved to
# the SDK's bundled LLVM and an installed clang toolchain was shadowed by a
# version the user never asked for. Measured after a plain 'sandhome install
# emscripten' on a host that also had the clang toolchain:
#   command -v clang  -> .../views/emscripten/emsdk/upstream/bin/clang
#   clang --version   -> clang version 20.0.0git (Emscripten's bundled LLVM)
#   sandhome toolchains -> clang present  clang version 23.1.2
#   sandhome report      -> toolchain.clang=clang version 20.0.0git
# so the report named a version that was not the toolchain and doctor stayed
# green throughout. Appending keeps the installed clang first, and emcc is
# unaffected because it finds its LLVM through EM_CONFIG (LLVM_ROOT), not PATH.
#
# THE EMPTY-PATH FORM IS THE POINT, AND NOT A COSMETIC ONE. An append written
# as PATH="\$PATH:\$dir" on a shell whose PATH is EMPTY produces ":\$dir", and an
# empty PATH element means the CURRENT DIRECTORY on every POSIX shell. Measured:
#   dash -c 'unset PATH; PATH="\$PATH:/x"; case ":\$PATH:" in *::*) echo HAZARD;; esac'
#   HAZARD
# The prepended form had the same shape in reverse but could not produce a
# LEADING colon, so the change to append would have introduced this hazard
# rather than removed one. The guard makes an empty PATH a single entry.
case ":\$PATH:" in
  *":$sh_ee_view/emsdk/upstream/bin:"*) ;;
  *) PATH="${PATH:+\$PATH:}$sh_ee_view/emsdk/upstream/bin" ;;
esac
export PATH
EOF
    return $?
}

# tc_emscripten_doctor -> 0 when emcc runs and EM_CONFIG names a live config.
# The version check alone passes on a half-activated SDK whose link then dies
# naming emcc; the config existing and pointing at directories that exist is
# the second half, and a two-line C-to-wasm link is the third when the SDK
# answers quickly. The link is bounded: it runs only when emcc already
# answered, with a trivial input, so a healthy tree pays milliseconds.
tc_emscripten_doctor() {
    sh_ed_bin=''
    if [ -n "${SH_EXEC_VIEWS:-}" ] && [ -x "$SH_EXEC_VIEWS/emscripten/emsdk/upstream/emscripten/emcc" ]; then
        sh_ed_bin="$SH_EXEC_VIEWS/emscripten/emsdk/upstream/emscripten/emcc"
    elif [ -n "${SANDHOME_EXEC:-}" ] && [ -x "$SANDHOME_EXEC/views/emscripten/emsdk/upstream/emscripten/emcc" ]; then
        sh_ed_bin="$SANDHOME_EXEC/views/emscripten/emsdk/upstream/emscripten/emcc"
    elif sh_have emcc; then
        sh_ed_bin=emcc
    fi
    [ -n "$sh_ed_bin" ] || return 1
    "$sh_ed_bin" --version >/dev/null 2>&1 || return 1
    # EM_CONFIG must name a file that exists when the toolchain is ours; an
    # adopted emcc carries its own config and is exempt.
    if [ -d "${SH_EXEC_VIEWS:-/nonexistent}/emscripten" ] || [ -d "${SANDHOME_EXEC:-/nonexistent}/views/emscripten" ]; then
        sh_ed_cfg=${EM_CONFIG:-${SANDHOME_EXEC:-${SH_EXEC:-}}/emscripten/.emscripten}
        [ -r "$sh_ed_cfg" ] || return 1
    fi
    return 0
}

tc_emscripten_version() {
    sh_have emcc && sh_first_line emcc --version 2>/dev/null
}
