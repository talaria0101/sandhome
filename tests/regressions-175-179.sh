#!/bin/sh
# tests/regressions-175-179.sh - one clause per defect fixed in the consumer
# round that closed issues #175-#179.
#
# Every clause names a mechanism, fails against the tree as it stood, and holds
# after. The clauses are deliberately UNIT-shaped where the defect is a function
# that can be driven with a fixture (the cargo wrapper, the python env step, the
# meson install probe, the in-process environment load), because a clause that
# needs a 900MB rust install would be skipped on most runners and a skipped
# clause does not fail against the old tree. The two things a fixture cannot
# fake - a noexec home and a real cargo - are handled explicitly: the meson
# clause runs its launcher from a directory that actually refuses execve, and
# the cargo clauses drive the real generated wrapper.
#
# RUNNING AGAINST THE OLD TREE. Every clause here reads the functions from
# $ROOT/lib and $ROOT/tools, so `git stash` the product fix, run this file, and
# the named clauses fail. That is the contract, not a comment.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

SH_REPO_DIR=$ROOT
SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-175-179

tmp=$(t_exec_tmpdir sandhome-regr-175-179)
sh_regr_tmp=$tmp
trap 'rm -rf "$sh_regr_tmp"' EXIT

# sh_regr_sh ROOTS DIR SNIPPET -> run SNIPPET in a fresh shell with the library
# and the pinned roots. The snippet is $1; the toolchain modules it wants are
# sourced by the snippet itself so one clause cannot leak a definition into
# another.
sh_regr_sh() {
    sh_rs_roots=$1
    sh_rs_snippet=$2
    SANDHOME_HOME=$sh_rs_roots/home SANDHOME_EXEC=$sh_rs_roots/exec \
    SH_HOME=$sh_rs_roots/home SH_HOME_TOOLCHAINS=$sh_rs_roots/home/toolchains \
    SH_HOME_TMP=$sh_rs_roots/home/tmp SH_HOME_EXEC=no \
    SH_EXEC=$sh_rs_roots/exec SH_EXEC_BIN=$sh_rs_roots/exec/bin \
    SH_EXEC_VIEWS=$sh_rs_roots/exec/views \
    SH_REPO_DIR=$ROOT SH_LIB_DIR=$ROOT/lib SH_SELF=test \
    SH_DRY_RUN=0 SH_VIEW_MODE=copy \
    sh -c 'for m in common detect space env fetch toolchain shim memexec; do . "$SH_REPO_DIR/lib/$m.sh"; done; eval "$1"' \
        _ "$sh_rs_snippet" 2>/dev/null
}

# =====================================================================  #175
# THE WRAPPER WROTE THROUGH THE EXEC-BIN SYMLINK AND CLOBBERED THE REAL CARGO.
# tc_rust_env writes the target-dir wrapper to $SH_EXEC_BIN/cargo, which the
# promote step had already linked to the real cargo in the view. A plain
# `> "$SH_EXEC_BIN/cargo"` follows the link chain to the real binary, truncates
# it, and writes the wrapper there; the wrapper then execs the view link back to
# itself and cargo hangs forever. The fix removes the link before the move. The
# fixture below is the exact shape: a symlinked exec-bin cargo whose real target
# is a runnable script.
r175=$tmp/r175
mkdir -p "$r175/home/toolchains" "$r175/home/tmp" "$r175/exec/bin" \
         "$r175/exec/views/rust/cargo/bin" "$r175/a/dup" "$r175/b/dup"
printf '#!/bin/sh\nprintf "CTD=%%s\\n" "${CARGO_TARGET_DIR:-none}"\n' > "$r175/real-cargo"
chmod 0755 "$r175/real-cargo"
ln -sfn "$r175/real-cargo" "$r175/exec/views/rust/cargo/bin/cargo"
ln -sfn "$r175/exec/views/rust/cargo/bin/cargo" "$r175/exec/bin/cargo"
for sh175_p in a b; do
    printf '[package]\nname = "dup"\nversion = "0.0.0"\n' > "$r175/$sh175_p/dup/Cargo.toml"
done
sh_regr_sh "$r175" '
. "$SH_REPO_DIR/tools/rust.sh"
sh_toolchain_rust_target_wrapper "$SH_EXEC_BIN" "$SANDHOME_EXEC/views/rust/cargo/bin/cargo"
'
t_ok "$([ -L "$r175/exec/bin/cargo" ] && echo 1 || echo 0)" \
    'the cargo wrapper replaces the exec-bin symlink instead of writing through it (#175)'
t_ok "$(grep -q 'written by sandhome' "$r175/real-cargo" 2>/dev/null && echo 1 || echo 0)" \
    'the real cargo behind the symlink is not clobbered by the wrapper (#175)'

# A live proof that the wrapper the run just generated actually runs, with a
# hard timeout: the old shape recursed forever and `timeout` is what turns that
# hang into a failed clause instead of a stalled suite.
sh175_out=$(cd "$r175/b/dup" && SANDHOME_EXEC="$r175/exec" timeout 10 "$r175/exec/bin/cargo" 2>/dev/null)
t_ok "$([ -n "$sh175_out" ] && echo 0 || echo 1)" \
    'the generated cargo wrapper executes the real cargo and returns (#175)'

# =====================================================================  #176
# THE TARGET DIR WAS RESOLVED ONCE PER SHELL, SO TWO PROJECTS SHARED ONE.
# env.sh sets CARGO_TARGET_DIR at shell start, and the wrapper only acted when
# it was UNSET. A login shell that cd'd afterwards kept the variable from its
# start directory, so two different `dup` crates shared the first one's target
# dir and the second ran the first's binary. The fix records the value env.sh
# chose in SANDHOME_CARGO_TARGET_DEFAULT and recomputes when the current value
# is still that recorded default. The fixture drives the wrapper with a stale
# default and asks the real cargo which dir it was handed.
r176=$r175
r176_stale="$r176/exec/target-stale"
# STOP: THE PROJECT DIRECTORY IS MADE NOEXEC, BECAUSE THAT IS THE CONDITION #176
# IS ABOUT (issue #190). The wrapper redirects CARGO_TARGET_DIR only where the
# project directory cannot RUN a file: on an exec-capable tree the redirect buys
# nothing and moved the target out of the project, so `cargo build` then
# `./target/debug/<bin>` was ENOENT (#190). The re-derivation rule this clause
# asserts is now reached only when the exec probe fails, so the fixture makes it
# fail by taking write permission away - the probe cannot write, so it cannot
# run, so the wrapper redirects. `chmod` is restored after, and the clause is
# skipped where the directory is not the caller's to chmod (uid 0 or a foreign
# mount), so a run that cannot stage the condition does not report a false red.
chmod 0555 "$r176/b/dup" 2>/dev/null || true
if [ -w "$r176/b/dup" ]; then
    # A root user can write a 0555 directory, so the probe would run and this
    # clause would assert the exec-capable answer while calling it noexec. The
    # condition cannot be staged here; say so instead of reporting a false red.
    chmod 0755 "$r176/b/dup" 2>/dev/null || true
    t_skip 'cannot make the project directory refuse exec here (running as root); the #176 noexec clause did not run'
else
    sh176_b=$(cd "$r176/b/dup" && SANDHOME_EXEC="$r176/exec" \
        CARGO_TARGET_DIR="$r176_stale" SANDHOME_CARGO_TARGET_DEFAULT="$r176_stale" \
        timeout 10 "$r176/exec/bin/cargo" 2>/dev/null)
    chmod 0755 "$r176/b/dup" 2>/dev/null || true
    case "$sh176_b" in
        *target-dup*) t_ok 0 'a wrapper in a noexec project re-derives the target dir from the project (#176)' ;;
        *) t_ok 1 'a wrapper in a noexec project re-derives the target dir from the project (#176)' ;;
    esac
fi
# The override rule is the other half: a caller who points cargo somewhere else
# must keep it, and the recorded default must not be mistaken for a stale value.
sh176_custom=$(cd "$r176/b/dup" && SANDHOME_EXEC="$r176/exec" \
    CARGO_TARGET_DIR="$r176/exec/target-custom" SANDHOME_CARGO_TARGET_DEFAULT="$r176_stale" \
    timeout 10 "$r176/exec/bin/cargo" 2>/dev/null)
t_contains "$sh176_custom" 'target-custom' \
    "a caller's own CARGO_TARGET_DIR is never overridden by the wrapper (#176)"
# The fragment must be able to reach the wrapper at all. The rust fragment
# prepends the toolchain bin ahead of $SH_EXEC_BIN, so the exec-bin link is
# shadowed; the fix adds a directory that is prepended first.
t_ok "$([ -L "$r176/exec/cargo-wrap/cargo" ] && echo 0 || echo 1)" \
    'the cargo wrapper also lands in a directory the rust fragment can put first on PATH (#176)'

# =====================================================================  #177
# THE MESON LAUNCHER WAS EXECUTED BY ITS HOME PATH ON A NOEXEC HOME.
# tc_meson_install proves the launcher it wrote with `"$sh_me_launcher"
# --version`, but the launcher lives on the home, which refuses execve. Every
# first `sandhome install meson` failed with "unpacked but does not answer" and
# needed a documented `repair`. The fix reads the script through `sh`. The
# fixture puts the launcher on a directory that really refuses execve (probed,
# not assumed) and a fake uv on an exec-capable directory, then runs the
# install step.
sh_regr_noexec() {
    for sh_nx_base in "${HOME:-}" /state/home /home "$tmp"; do
        [ -n "$sh_nx_base" ] && [ -d "$sh_nx_base" ] || continue
        sh_nx_dir="$sh_nx_base/.sandhome-noexec.$$"
        mkdir -p "$sh_nx_dir" 2>/dev/null || continue
        sh_nx_f="$sh_nx_dir/probe"
        printf '#!/bin/sh\nexit 0\n' > "$sh_nx_f" 2>/dev/null || { rm -rf "$sh_nx_dir"; continue; }
        chmod 0755 "$sh_nx_f" 2>/dev/null
        if "$sh_nx_f" >/dev/null 2>&1; then
            rm -rf "$sh_nx_dir"
            continue
        fi
        rm -f "$sh_nx_f"
        printf '%s' "$sh_nx_dir"
        return 0
    done
    return 1
}
r177_nodir=$(sh_regr_noexec)
if [ -n "$r177_nodir" ]; then
    r177_bin=$tmp/r177-bin
    r177_home=$r177_nodir/home
    mkdir -p "$r177_bin" "$r177_home/toolchains" "$r177_home/tmp" \
             "$tmp/r177/exec/bin" "$tmp/r177/exec/views"
    # uv must run, so it lives on the exec root; only the meson payload and its
    # launcher are on the noexec home.
    cat > "$r177_bin/uv" <<'UV'
#!/bin/sh
tgt=""
while [ $# -gt 0 ]; do
    case "$1" in --target) shift; tgt=$1 ;; esac
    shift
done
mkdir -p "$tgt/mesonbuild"
exit 0
UV
    chmod 0755 "$r177_bin/uv"
    printf '#!/bin/sh\nexit 0\n' > "$r177_bin/python3"
    chmod 0755 "$r177_bin/python3"
    SANDHOME_HOME=$r177_home SANDHOME_EXEC=$tmp/r177/exec \
    SH_HOME=$r177_home SH_HOME_TOOLCHAINS=$r177_home/toolchains \
    SH_HOME_TMP=$r177_home/tmp SH_HOME_EXEC=no \
    SH_EXEC=$tmp/r177/exec SH_EXEC_BIN=$tmp/r177/exec/bin \
    SH_EXEC_VIEWS=$tmp/r177/exec/views \
    SH_REPO_DIR=$ROOT SH_LIB_DIR=$ROOT/lib SH_SELF=test \
    SH_DRY_RUN=0 SH_VIEW_MODE=copy PATH="$r177_bin:/usr/bin:/bin" \
    sh -c 'for m in common detect space env fetch toolchain shim memexec; do . "$SH_REPO_DIR/lib/$m.sh"; done; . "$SH_REPO_DIR/tools/meson.sh"; tc_meson_install' \
        >/dev/null 2>&1
    t_ok "$?" \
        'the meson launcher is proven through sh even when its home refuses execve (#177)'
else
    t_skip 'no writable noexec directory to place the meson launcher on (#177)'
fi

# =====================================================================  #178
# THE PYTHON INTERPRETER WAS ONLY ON THE FRAGMENT PATH, WHICH A FRESH SHELL
# NEVER READS. The global hook serves only the names in $SH_EXEC_BIN, and
# python declared no bins (TC_python_BINS is empty), so `env -i .../sh -c
# 'python3 ...'` with only the hook directory on PATH could not find python at
# all. The fix links the interpreter the module discovered into the module's
# own bin/, where the hook reads it, and the repair path must run the module's
# env step even when its bin list is empty. The fixture is a fake installed
# python view and the real tc_python_env.
r178=$tmp/r178
mkdir -p "$r178/home/toolchains/python/bin" \
         "$r178/home/toolchains/python/python/cpython-3.12-x/bin" \
         "$r178/home/tmp" "$r178/exec/bin" "$r178/exec/views" "$r178/fakebin"
printf '#!/bin/sh\nprintf "Python 3.12.0\\n"\n' > "$r178/home/toolchains/python/python/cpython-3.12-x/bin/python3"
chmod 0755 "$r178/home/toolchains/python/python/cpython-3.12-x/bin/python3"
for sh178_t in uv uvx; do
    printf '#!/bin/sh\nexit 0\n' > "$r178/home/toolchains/python/bin/$sh178_t"
    chmod 0755 "$r178/home/toolchains/python/bin/$sh178_t"
    printf '#!/bin/sh\nexit 0\n' > "$r178/fakebin/$sh178_t"
    chmod 0755 "$r178/fakebin/$sh178_t"
done
PATH="$r178/fakebin:/usr/bin:/bin" \
SANDHOME_HOME=$r178/home SANDHOME_EXEC=$r178/exec \
SH_HOME=$r178/home SH_HOME_TOOLCHAINS=$r178/home/toolchains \
SH_HOME_TMP=$r178/home/tmp SH_HOME_EXEC=no \
SH_EXEC=$r178/exec SH_EXEC_BIN=$r178/exec/bin SH_EXEC_VIEWS=$r178/exec/views \
SH_REPO_DIR=$ROOT SH_LIB_DIR=$ROOT/lib SH_SELF=test SH_DRY_RUN=0 SH_VIEW_MODE=copy \
sh -c 'for m in common detect space env fetch toolchain shim memexec; do . "$SH_REPO_DIR/lib/$m.sh"; done; . "$SH_REPO_DIR/tools/python.sh"; tc_python_env' \
    >/dev/null 2>&1
t_ok "$([ -L "$r178/exec/bin/python3" ] && echo 0 || echo 1)" \
    'tc_python_env links the interpreter into the exec bin the hook serves (#178)'

# =====================================================================  #179
# A COMMAND THAT NEVER SOURCES env.sh RAN ITS SUBPROCESS PROBES WITH NO HOME.
# `env -i /tmp/bin/sandhome doctor` is documented to work, but sh_env_load sets
# PATH and the fragments and not the scratch roots, so the deno self-exec probe
# died with "Could not resolve global Deno cache directory" and npm with
# "uv_os_homedir returned ENOENT". The fix gives the readiness gate a scratch
# HOME before it runs the spawn probes. The clause drives the real loader and
# the real gate with HOME unset; it must not be sh_env_load alone that sets it,
# because every read-only command calls that and must still create nothing.
r179=$tmp/r179
mkdir -p "$r179/home/env.d" "$r179/home/tmp" "$r179/exec/bin" "$r179/exec/views"
sh179_home=$(env -u HOME \
    SANDHOME_HOME=$r179/home SANDHOME_EXEC=$r179/exec \
    SH_HOME=$r179/home SH_HOME_TOOLCHAINS=$r179/home/toolchains \
    SH_HOME_TMP=$r179/home/tmp SH_HOME_EXEC=no \
    SH_EXEC=$r179/exec SH_EXEC_BIN=$r179/exec/bin SH_EXEC_VIEWS=$r179/exec/views \
    SH_REPO_DIR=$ROOT SH_LIB_DIR=$ROOT/lib \
    sh -c 'for m in common detect space env fetch toolchain shim report memexec; do . "$SH_REPO_DIR/lib/$m.sh"; done; sh_env_load; sh_doctor >/dev/null 2>&1; printf "%s" "${HOME:-UNSET}"' 2>/dev/null)
t_is "$sh179_home" "$r179/exec/home" \
    'the readiness gate gives a HOME-less process the same scratch HOME a sourced shell gets (#179)'

t_end
