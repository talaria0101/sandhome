#!/bin/sh
# tests/regressions-cargo-selfwrap.sh - the cargo wrapper must never name
# itself as the real cargo it execs.
#
# Measured on a host that adopted rust: the adopt loop in tc_rust_env passed
# "${SH_EXEC_BIN}/cargo" as the real cargo to sh_toolchain_rust_target_wrapper,
# and the wrapper overwrites exactly that path. The written wrapper then ended
# with `exec '<that same path>' "$@"`, so every `cargo` invocation re-exec'd
# the wrapper forever and hung (exit 124 on the consumer round, defunct
# `cargo` zombies). This file fails against the tree where the wrapper would
# happily write a self-exec body, and passes after.
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib.sh"
SH_REPO_DIR=$ROOT
SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-cargo-selfwrap

tmp=$(t_exec_tmpdir sandhome-cargo-selfwrap)
trap 'rm -rf "$tmp"' EXIT

# A real cargo that is NOT the wrapper output path: the wrapper must be
# written and must exec this real one.
mkdir -p "$tmp/home" "$tmp/exec/bin" "$tmp/realbin"
printf '#!/bin/sh\nprintf "REAL CARGO\\n"\n' > "$tmp/realbin/cargo"
chmod 0755 "$tmp/realbin/cargo"
(
    for m in common detect space env fetch toolchain shim memexec report; do
        . "$ROOT/lib/$m.sh"
    done
    . "$ROOT/tools/rust.sh"
    SH_HOME=$tmp/home SH_EXEC=$tmp/exec SH_EXEC_BIN=$tmp/exec/bin \
        SANDHOME_EXEC=$tmp/exec SANDHOME_HOME=$tmp/home \
        sh_toolchain_rust_target_wrapper "$tmp/exec/bin" "$tmp/realbin/cargo"
) 2>/dev/null
t_ok "$([ -x "$tmp/exec/bin/cargo" ] && echo 0 || echo 1)" \
    'a normal real cargo still gets a wrapper written (#cargo-selfwrap)'
t_ok "$(grep -qF "exec '$tmp/realbin/cargo'" "$tmp/exec/bin/cargo" && echo 0 || echo 1)" \
    'the wrapper execs the real cargo, not itself (#cargo-selfwrap)'

# The defect: handing the wrapper its own output path must NOT overwrite it
# with a self-exec body. Pre-fix, the file on disk would gain
# `exec '<same path>'` and a cargo run would spin until killed.
mkdir -p "$tmp/self/bin"
printf '#!/bin/sh\nprintf "SHOULD SURVIVE\\n"\n' > "$tmp/self/bin/cargo"
chmod 0755 "$tmp/self/bin/cargo"
SHOULD=$("$tmp/self/bin/cargo")
(
    for m in common detect space env fetch toolchain shim memexec report; do
        . "$ROOT/lib/$m.sh"
    done
    . "$ROOT/tools/rust.sh"
    SH_HOME=$tmp/home SH_EXEC=$tmp/exec SH_EXEC_BIN=$tmp/self/bin \
        SANDHOME_EXEC=$tmp/exec SANDHOME_HOME=$tmp/home \
        sh_toolchain_rust_target_wrapper "$tmp/self/bin" "$tmp/self/bin/cargo"
) 2>/dev/null
AFTER=$(timeout 5 "$tmp/self/bin/cargo" 2>/dev/null)
t_ok "$([ $? -ne 124 ] && echo 0 || echo 1)" \
    'the caller cargo still answers instead of spinning in a self-exec loop (#cargo-selfwrap)'
t_is "$AFTER" "$SHOULD" \
    'a same-path real cargo is refused: the caller cargo is left in place (#cargo-selfwrap)'
t_ok "$(grep -qF "exec '$tmp/self/bin/cargo'" "$tmp/self/bin/cargo" && echo 1 || echo 0)" \
    'no self-exec wrapper body is ever written (#cargo-selfwrap)'

t_end
