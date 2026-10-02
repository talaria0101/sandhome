#!/bin/sh
# rust - the Rust toolchain through rustup, split across the two roots.
#
# THE SHAPE. The toolchain data (RUSTUP_HOME, CARGO_HOME) lives on the home,
# where there is room for ~900MB, and only executables are mirrored into the
# exec view. Shared objects stay home: mmap(PROT_EXEC) is allowed where
# execve is not, so librustc_driver and libLLVM load from the home while a
# copied binary in it would not run.
#
# THE VIEW MODE DECIDES WHAT "MIRRORED" COSTS. In launch mode each executable
# is a 20KB launcher copy that runs the home payload from memory, plus a few
# megabytes of real copies for spawn targets, so the view is ~17MB measured.
# In copy mode each executable is a full copy (~100MB). The mode is
# chosen by sh_memexec_ensure before any install; this module only prices its
# own gate off it and writes the wrappers both modes need.
TC_rust_DESC='Rust via rustup (rustc, cargo, rustup, rustdoc, cargo-clippy, cargo-fmt; minimal profile)'
TC_rust_BINS='cargo/bin/rustup cargo/bin/cargo cargo/bin/rustc cargo/bin/rustdoc cargo/bin/cargo-clippy cargo/bin/cargo-fmt'

# tc_rust_exec_mb -> the fresh-install exec need in MB: 25 in launch mode
# (launcher copies plus the few real spawn-target copies), 150 in copy mode
# (full ~100MB executable copies). The install gate below reads this, and so
# does the up-front feasibility plan, so the two never disagree.
tc_rust_exec_mb() {
    if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
        printf '25'
    else
        printf '150'
    fi
}

# tc_rust_probe -> 0 when a WORKING rustc is already here, which is the whole
# question. It used to be `sh_have rustc && rustc --version`, and that answers
# yes for a copy that cannot build: some sealed sandboxes ship a multi-arch rust
# as a shim that prints a version and refuses everything else. So the adopt path
# was taken, `sandhome install rust` exited 0 having printed "a working copy is
# already here; adopting it", `sandhome report` printed
#   toolchain.rust=rustc 1.99.0 (proxy build 2026-01-01)
# and the first build the consumer attempted died with "proxy rustc: refusing,
# not a compiler" (issue #53). Nothing in the setup said the toolchain was a
# placeholder, and there was no --force to skip the probe (that came with #45).
#
# The decision being made is "can this copy build", so it is answered by
# building. tc_rust_behavioural compiles and runs one trivial binary, which is
# the same measurement the noexec-sysroot repair already used, and it is
# reported when it fails rather than falling through silently, because a
# consumer whose rustc was rejected needs to know which one was thrown away.
#
# The cost is one compile of a four-line program, and it is only paid when a
# rustc is present: with none on PATH there is nothing to probe. A working host
# copy is adopted and no workaround runs at all; SANDHOME_FORCE (or install
# --force) skips the probe and installs under sandhome's own control.
tc_rust_probe() {
    sh_have rustc || return 1
    rustc --version >/dev/null 2>&1 || return 1
    if tc_rust_behavioural >/dev/null 2>&1; then
        return 0
    fi
    sh_warn "the rustc on PATH answers --version but does not compile here, so it is not a working copy; install a real toolchain instead of adopting it"
    return 1
}

# tc_rust_behavioural -> 0 when a trivial native binary links and runs.
# This is the probe that catches the noexec sysroot: `rustc --version`
# runs from the view while `collect2` spawns `ld.lld` from the noexec home.
tc_rust_behavioural() {
    sh_rb_tmp=${SH_EXEC:-${TMPDIR:-/tmp}}/rust-probe.$$
    mkdir -p "$sh_rb_tmp" 2>/dev/null || return 1
    printf 'fn main(){println!("ok");}\n' > "$sh_rb_tmp/hello.rs" 2>/dev/null || {
        rm -rf "$sh_rb_tmp" 2>/dev/null
        return 1
    }
    if rustc "$sh_rb_tmp/hello.rs" -o "$sh_rb_tmp/hello" >/dev/null 2>&1; then
        if "$sh_rb_tmp/hello" >/dev/null 2>&1; then
            rm -rf "$sh_rb_tmp" 2>/dev/null
            return 0
        fi
    fi
    rm -rf "$sh_rb_tmp" 2>/dev/null
    return 1
}

# sh_toolchain_ensure_rust_exec -> install a rust toolchain and promote its
# executable view, 0 on success. Called from the adopt path when the borrowed
# rustc cannot link here (issue #52): the only repair that makes a link succeed
# is a toolchain whose sysroot runs what is in it, and a linker flag provably
# does not.
#
# It is deliberately not `tc_rust_install`, because that records the toolchain in
# INSTALLED and the caller is still inside the adopt branch, where the consumer
# was told the host copy was adopted. What is printed is the truth: a usable
# toolchain was added, and where it came from. The promote belongs here and not
# in tc_rust_env: the framework promoted the tree this was ADOPTED from before
# it called here, and the tree just installed replaces that view, so it has to
# be mirrored after the install. On the ordinary install path the framework's
# own promote has already run and a second mirror would only re-hit the size
# gate after its own copy had spent the free space.
sh_toolchain_ensure_rust_exec() {
    sh_ere_saved_installed=$INSTALLED
    sh_ere_saved_targets=${SH_RUST_TARGETS:-}
    SH_RUST_TARGETS=''
    export SH_RUST_TARGETS
    if tc_rust_install; then
        INSTALLED=$sh_ere_saved_installed
        [ -n "$sh_ere_saved_targets" ] && SH_RUST_TARGETS=$sh_ere_saved_targets
        export SH_RUST_TARGETS
        sh_promote_toolchain rust cargo/bin/rustup cargo/bin/cargo
        return 0
    fi
    INSTALLED=$sh_ere_saved_installed
    [ -n "$sh_ere_saved_targets" ] && SH_RUST_TARGETS=$sh_ere_saved_targets
    export SH_RUST_TARGETS
    return 1
}

# sh_toolchain_rust_proxies -> ensure CARGO_HOME/bin holds cargo and rustup.
# `rustup toolchain install --no-self-update` skips the proxy-writing step,
# so a clean shell has cargo only through the exec view and no rustup at all
# (measured: `command -v rustup` empty after install, while TC_rust_BINS
# promises it). cargo links to the toolchain's own real binary (globbed, so
# no triple is spelled); rustup links to the installer that just ran, which
# is what manages this RUSTUP_HOME. Missing targets are skipped, never
# invented: the install still succeeds and the probe still decides.
sh_toolchain_rust_proxies() {
    sh_rr_cargo=$1
    sh_rr_rustup=$2
    sh_rr_host=$3
    mkdir -p "$sh_rr_cargo/bin" 2>/dev/null || return 0
    # # STOP: EVERY COMMAND TC_rust_BINS ADVERTISES GETS A PROXY, BECAUSE THE
    # NAME A FRESH SHELL RESOLVES IS THE ONE THAT HAS TO WORK. Only cargo and
    # rustup were proxied, so the exec view exposed no rustc and a fresh shell
    # fell through to the host's rustup shim, which answers "rustup could not
    # choose a version of rustc to run, because one wasn't specified
    # explicitly, and no default is configured" (issue #135) while `doctor`
    # said `toolchain_rust=yes` and `cargo --version` worked. rustc is the one
    # command a Rust toolchain exists to provide; the description already
    # named it and the bins did not.
    #
    # THE PROXY IS THE REAL TOOLCHAIN BINARY, NEVER A rustup PROXY, AND THAT
    # IS A CORRECTNESS RULE ON A SPLIT ROOT, NOT A TIDYNESS ONE. rustup writes
    # `cargo/bin/cargo -> rustup` and `cargo/bin/rustc -> rustup` in its own
    # tree; those proxies resolve the toolchain under $RUSTUP_HOME, which is
    # this tree's HOME, and the home is the mount that refuses execve. So every
    # proxy invocation execs the HOME's rustc and dies:
    #   $ env -i HOME=... PATH=<hook>:... sh -c 'cargo --version'
    #   error: command failed: 'cargo': Permission denied (os error 13)
    # while the SAME cargo works in a sourced shell, because env.sh prepends
    # toolchains/<triple>/bin (the real binaries, already on the exec root)
    # AHEAD of the exec bin. The exec bin is the surface the global hook uses,
    # so a link there that points at a rustup proxy is a tool that answers
    # `command -v` and cannot run - measured on this tree, and the behaviour is
    # unchanged from before this fix, which is why the guard below replaces the
    # proxy rather than accepting it.
    #
    # A link is only left alone when it already points somewhere OTHER than
    # rustup, because that is a real binary or a sysroot wrapper, and both run.
    for sh_rr_name in cargo rustc rustdoc cargo-clippy cargo-fmt rustup; do
        sh_rr_existing=''
        [ -e "$sh_rr_cargo/bin/$sh_rr_name" ] && sh_rr_existing=$(readlink "$sh_rr_cargo/bin/$sh_rr_name" 2>/dev/null) || sh_rr_existing=''
        case "$sh_rr_existing" in
            ''|rustup|./rustup|"$sh_rr_rustup/cargo/bin/rustup") : ;;
            *)  continue ;;
        esac
        for sh_rr_c in "$sh_rr_rustup"/toolchains/*/bin/"$sh_rr_name"; do
            if [ -f "$sh_rr_c" ]; then
                rm -f "$sh_rr_cargo/bin/$sh_rr_name" 2>/dev/null
                ln -sfn "$sh_rr_c" "$sh_rr_cargo/bin/$sh_rr_name" 2>/dev/null || \
                    cp -f "$sh_rr_c" "$sh_rr_cargo/bin/$sh_rr_name" 2>/dev/null || true
                break
            fi
        done
    done
    if [ ! -x "$sh_rr_cargo/bin/rustup" ] && [ -n "$sh_rr_host" ] && [ -x "$sh_rr_host" ]; then
        # Belt and braces beside the caller's sh_path_where: a host inside
        # the exec view or inside this very cargo dir is never a working
        # copy, it is the view link (or self). Linking it would build the
        # home -> exec -> view -> exec cycle measured on a force-install
        # over an adopted tree. Refuse it and leave the proxy missing rather
        # than linked wrong; the install still succeeds and names the gap.
        sh_rr_bad=no
        case "$sh_rr_host" in "${SH_EXEC:-/tmp}"/*) sh_rr_bad=yes ;; esac
        case "$sh_rr_host" in "$sh_rr_cargo"/*) sh_rr_bad=yes ;; esac
        if [ "$sh_rr_bad" = no ]; then
            ln -sfn "$sh_rr_host" "$sh_rr_cargo/bin/rustup" 2>/dev/null || \
                cp -f "$sh_rr_host" "$sh_rr_cargo/bin/rustup" 2>/dev/null || true
        fi
    fi
    return 0
}

# sh_toolchain_rust_target_wrapper EXEC_BIN REAL_CARGO -> put a `cargo` on the
# exec bin that resolves CARGO_TARGET_DIR for the directory it is run in.
#
# THE RULE IT ENFORCES, IN ORDER:
#   1. a caller who set CARGO_TARGET_DIR keeps it, always. env.sh only ever
#      GUARDS the variable for the same reason, and a wrapper that overrode it
#      would break every build script that points cargo somewhere on purpose;
#   2. otherwise the id is the nearest Cargo.toml ancestor of $PWD, which is
#      cargo's own rule for what a project is (`cargo locate-project` answers
#      the same path), plus a digest so two projects with the same basename do
#      not share a directory;
#   3. and it is re-derived on EVERY invocation, which is the part the static
#      fragment could not do.
#
# It is written next to the real cargo rather than in its place, so the real
# binary keeps its own path: it is reached through the view link
# <view>/cargo/bin/cargo, which is a link to the toolchain binary.
#
# The walker is a loop, not recursion (rule 5), and reads no tool beyond `cksum`
# with a pure-shell fallback, because this script runs on a machine that may not
# have installed any.
sh_toolchain_rust_target_wrapper() {
    sh_rw2_bin=$1
    sh_rw2_real=$2
    [ -n "$sh_rw2_bin" ] || return 0
    [ -x "$sh_rw2_real" ] || return 0
    mkdir -p "$sh_rw2_bin" 2>/dev/null || return 0
    sh_rw2_out=$sh_rw2_bin/cargo
    sh_rw2_tmp="$sh_rw2_out.tmp.$$"
    sh_rw2_real_q=$(sh_sq_quote "$sh_rw2_real")
    {
        printf '#!/bin/sh\n'
        printf '# written by sandhome: resolve CARGO_TARGET_DIR for the directory\n'
        printf '# cargo is run in, then run the real cargo (issue #167).\n'
        printf 'if [ -n "${SANDHOME_EXEC:-}" ] && { [ -z "${CARGO_TARGET_DIR:-}" ] || [ "${CARGO_TARGET_DIR:-}" = "${SANDHOME_CARGO_TARGET_DEFAULT:-}" ]; }; then\n'
        printf '  # THE REDIRECT IS ONLY OWED WHEN THE PROJECT DIRECTORY CANNOT RUN A\n'
        printf '  # FILE (issue #190). On an exec-capable tree the redirect bought\n'
        printf '  # nothing and moved the target out of the project, so the documented\n'
        printf '  # cargo path broke: `cargo build` then `./target/debug/<bin>` died\n'
        printf '  # ENOENT because the artifact was under $SANDHOME_EXEC. Probe exec by\n'
        printf '  # RUNNING a real file, not by reading a mount option, which is the\n'
        printf '  # same rule sh_exec_probe follows; when the probe runs, cargo keeps its\n'
        printf '  # own target directory and the naive path works.\n'
        printf '  _sh_cw_exec=no\n'
        printf '  if [ -w "$PWD" ]; then\n'
        printf '    _sh_cw_pb="$PWD/.sandhome.exec.$$"\n'
        printf '    if ( umask 077; printf "#!/bin/sh\\nexit 0\\n" > "$_sh_cw_pb" ) 2>/dev/null; then\n'
        printf '      chmod 0700 "$_sh_cw_pb" 2>/dev/null\n'
        printf '      "$_sh_cw_pb" >/dev/null 2>&1 && _sh_cw_exec=yes\n'
        printf '      rm -f "$_sh_cw_pb" 2>/dev/null\n'
        printf '    fi\n'
        printf '  fi\n'
        printf '  if [ "$_sh_cw_exec" = yes ]; then\n'
        printf '    # THE PROJECT CAN RUN A FILE, SO CARGO KEEPS ITS OWN target/. The\n'
        printf '    # recorded default (if any) is dropped here rather than left in\n'
        printf '    # place: leaving it would keep pointing cargo at the exec root\n'
        printf '    # and the naive ./target/debug/<bin> would stay ENOENT. Only the\n'
        printf '    # value env.sh recorded is dropped; a caller who exported their\n'
        printf '    # own CARGO_TARGET_DIR never reaches this branch (the guard above).\n'
        printf '    unset CARGO_TARGET_DIR\n'
        printf '    unset SANDHOME_CARGO_TARGET_DEFAULT\n'
        printf '  else\n'
        printf '  _sh_cw_d=$PWD\n'
        printf '  while [ -n "$_sh_cw_d" ] && [ "$_sh_cw_d" != / ] && [ ! -f "$_sh_cw_d/Cargo.toml" ]; do\n'
        printf '    case "$_sh_cw_d" in */*) _sh_cw_d=${_sh_cw_d%%/*} ;; *) _sh_cw_d=/ ;; esac\n'
        printf '  done\n'
        printf '  [ -f "$_sh_cw_d/Cargo.toml" ] || _sh_cw_d=$PWD\n'
        printf '  _sh_cw_w=""\n'
        printf '  _sh_cw_t=$_sh_cw_d\n'
        printf '  while [ -n "$_sh_cw_t" ] && [ "$_sh_cw_t" != / ]; do\n'
        printf '    [ -f "$_sh_cw_t/Cargo.toml" ] || { case "$_sh_cw_t" in */*) _sh_cw_t=${_sh_cw_t%%/*} ;; *) _sh_cw_t=/ ;; esac; continue; }\n'
        printf '    _sh_cw_k=""\n'
        printf '    while IFS= read -r _sh_cw_l 2>/dev/null; do\n'
        printf '      case "$_sh_cw_l" in\n'
        printf "        '[workspace]'*) _sh_cw_k=\$_sh_cw_t; break ;;\n"
        printf '      esac\n'
        printf '    done < "$_sh_cw_t/Cargo.toml"\n'
        printf '    if [ -n "$_sh_cw_k" ]; then\n'
        printf '      _sh_cw_w=$_sh_cw_t; break\n'
        printf '    fi\n'
        printf '    case "$_sh_cw_t" in */*) _sh_cw_t=${_sh_cw_t%%/*} ;; *) _sh_cw_t=/ ;; esac\n'
        printf '  done\n'
        printf '  [ -n "$_sh_cw_w" ] && _sh_cw_d=$_sh_cw_w\n'
        printf '  _sh_cw_b=${_sh_cw_d##*/}; [ -n "$_sh_cw_b" ] || _sh_cw_b=work\n'
        printf '  if command -v cksum >/dev/null 2>&1; then\n'
        printf '    _sh_cw_s=$(printf "%%s" "$_sh_cw_d" | cksum)\n'
        printf '    _sh_cw_b="${_sh_cw_b}-${_sh_cw_s%%%% *}"\n'
        printf '  else\n'
        printf '    _sh_cw_o=$_sh_cw_b; _sh_cw_r=$_sh_cw_d\n'
        printf '    while [ -n "$_sh_cw_r" ]; do\n'
        printf '      _sh_cw_c=${_sh_cw_r%%%%"${_sh_cw_r#?}"}\n'
        printf '      _sh_cw_r=${_sh_cw_r#?}\n'
        printf '      case "$_sh_cw_c" in\n'
        printf '        /) _sh_cw_o="${_sh_cw_o}%%2f" ;;\n'
        printf '        %%) _sh_cw_o="${_sh_cw_o}%%25" ;;\n'
        printf '        *) _sh_cw_o="${_sh_cw_o}$_sh_cw_c" ;;\n'
        printf '      esac\n'
        printf '    done\n'
        printf '    _sh_cw_b=$_sh_cw_o\n'
        printf '  fi\n'
        printf '  CARGO_TARGET_DIR="$SANDHOME_EXEC/target-${_sh_cw_b}"\n'
        printf '  export CARGO_TARGET_DIR\n'
        printf '  SANDHOME_CARGO_TARGET_DEFAULT=$CARGO_TARGET_DIR\n'
        printf '  export SANDHOME_CARGO_TARGET_DEFAULT\n'
        printf '  fi\n'
        printf '  unset _sh_cw_d _sh_cw_b _sh_cw_s _sh_cw_o _sh_cw_r _sh_cw_c _sh_cw_w _sh_cw_t _sh_cw_exec _sh_cw_pb\n'
        printf 'fi\n'
        printf 'exec %s "$@"\n' "$sh_rw2_real_q"
    } > "$sh_rw2_tmp" 2>/dev/null || { rm -f "$sh_rw2_tmp" 2>/dev/null; return 0; }
    chmod 0755 "$sh_rw2_tmp" 2>/dev/null || true
    # STOP: rm BEFORE mv, BECAUSE $sh_rw2_out IS A SYMLINK. The promote step
    # links $SH_EXEC_BIN/cargo onto the view, which links onto the real cargo
    # in the toolchain; a plain `> "$sh_rw2_out"` follows that chain and
    # truncates the real cargo, then the wrapper execs the chain that is now
    # itself and every `cargo` invocation recurses forever. Removing the link
    # first keeps the payload untouched (issue #175).
    rm -f "$sh_rw2_out" 2>/dev/null || true
    mv -f "$sh_rw2_tmp" "$sh_rw2_out" 2>/dev/null || {
        rm -f "$sh_rw2_tmp" 2>/dev/null
        sh_warn "could not write the cargo target-dir wrapper into $sh_rw2_out"
        return 0
    }
    [ -x "$sh_rw2_out" ] || { rm -f "$sh_rw2_out" 2>/dev/null; return 0; }
    # A SECOND ENTRY POINT, BECAUSE THE FRAGMENT PUTS THE TOOLCHAIN BIN FIRST.
    # The rust fragment prepends $sh_re_bin ahead of $SH_EXEC_BIN, so a shell
    # that sourced env.sh resolved `cargo` straight to the real binary and
    # never reached this wrapper - #167 stayed live in exactly the login shell
    # it was measured in (issue #176). The fragment now prepends this
    # directory first; a symlink keeps one artifact rather than two copies.
    if [ -n "${SH_EXEC:-}" ]; then
        mkdir -p "$SH_EXEC/cargo-wrap" 2>/dev/null || true
        ln -sfn "$sh_rw2_out" "$SH_EXEC/cargo-wrap/cargo" 2>/dev/null || \
            cp -f "$sh_rw2_out" "$SH_EXEC/cargo-wrap/cargo" 2>/dev/null || true
        # # STOP: THE DIRECTORY IS MARKED WHERE IT IS CREATED, NOT WHERE IT IS
        # PREPENDED (issue #185). It is on PATH only because the fragment below
        # prepends it, so a shell that has not read the environment cannot be
        # served from it, and the global hook installer must not take it. The
        # install and repair runs call sh_env_load before sh_global_install, so
        # this directory was on PATH, writable and exec-capable by the time the
        # hook was planned, and the hook was written into it:
        #     global=on:/workspace/sandexec/cargo-wrap
        # which served nobody, because the next session does not have it on
        # PATH. The marker is written here, next to the mkdir, so a directory
        # created after the skip list was written cannot be taken by mistake.
        if [ -d "$SH_EXEC/cargo-wrap" ] && [ ! -e "$SH_EXEC/cargo-wrap/.sandhome-on-path" ]; then
            ( umask 022; : > "$SH_EXEC/cargo-wrap/.sandhome-on-path" ) 2>/dev/null || \
                { [ -n "${SH_HOME:-}" ] && [ -d "$SH_HOME" ] && \
                  printf '%s\n' "$SH_EXEC/cargo-wrap" >> "$SH_HOME/on-path.dirs" 2>/dev/null; } || true
        fi
    fi
    return 0
}

# sh_rust_target_resolver -> print the fragment that resolves
# CARGO_TARGET_DIR for the directory the shell is in when cargo runs.
#
# WHY A FRAGMENT CANNOT DO IT AND THIS STILL CAN: the static part of env.sh sets
# CARGO_TARGET_DIR once, at shell start, from the $PWD at that moment. A login
# shell sources env.sh and the consumer cds afterwards, so the variable names
# whichever directory the shell started in. Measured on a real login shell:
#   bash -lc 'cd .../a/dup && cargo run -q'  ->  PROJECT-A
#   bash -lc 'cd .../b/dup && cargo run -q'  ->  PROJECT-A
# both at ctd=target-workspace-306203429, one target dir for two crates, so the
# second was "fresh" and ran the first's binary (issue #167).
#
# A trap or a prompt command could re-run code on cd, and both are ruled out:
# AGENTS.md rule 6 forbids a prompt and an alias in this profile, and neither
# exists in POSIX sh for every consumer that sources env.sh. So the correction
# is made where the variable is USED rather than where it is set, and it is
# written as a FUNCTION the consumer calls, not as a hook that fires by itself.
# That keeps the shell's start-up free of anything that can fail, which is what
# rule 6 is protecting.
#
# THE FUNCTION IS OPT-IN AND SAFE TO CALL ON EVERY BUILD. It yields to a caller
# who set CARGO_TARGET_DIR themselves, and it is the same walk and digest
# sh_env_body uses, so the two cannot disagree about what a project is.
sh_rust_target_resolver() {
    cat <<'RESOLVEREOF'
# sandhome: re-derive CARGO_TARGET_DIR for the current project. Provided as a
# function, not run automatically: nothing here fires at shell start (rule 6).
# Call it after a cd into a project, or from a build script:
#   . /path/to/env.d/rust.sh   # already done by env.sh
#   sandhome_cargo_target      # then cargo build
sandhome_cargo_target() {
    # env.sh sets CARGO_TARGET_DIR once at shell start, from the $PWD at that
    # moment. That value is a DEFAULT, not a caller's choice, so recompute it
    # per call; a value the caller set themselves is kept (issue #176).
    if [ -n "${CARGO_TARGET_DIR:-}" ] && [ "${CARGO_TARGET_DIR:-}" != "${SANDHOME_CARGO_TARGET_DEFAULT:-}" ]; then
        return 0
    fi
    [ -n "${SANDHOME_EXEC:-}" ] || return 0
    _sh_ctr_d=$PWD
    _sh_ctr_r=$PWD
    while [ -n "$_sh_ctr_d" ] && [ "$_sh_ctr_d" != / ] && [ ! -f "$_sh_ctr_d/Cargo.toml" ]; do
        case "$_sh_ctr_d" in */*) _sh_ctr_d=${_sh_ctr_d%/*} ;; *) _sh_ctr_d=/ ;; esac
    done
    [ -f "$_sh_ctr_d/Cargo.toml" ] || _sh_ctr_d=$PWD
    # STOP: KEEP WALKING UP PAST A MEMBER MANIFEST TO THE WORKSPACE ROOT, OR A
    # WORKSPACE BUILDS ITSELF SEVERAL TIMES. A member's Cargo.toml is found
    # first, so stopping there named the member the project, while cargo builds
    # every member into the WORKSPACE root's target directory. Measured here on a
    # two-crate workspace:
    #   bash -lc 'cd ws && sandhome_cargo_target'          ->  target-ws-2829255314
    #   bash -lc 'cd ws/crates/one && sandhome_cargo_target' ->  target-one-514637701
    # two target dirs for one build, so building from the root and then from a
    # member rebuilt every crate twice. cargo's own answer is the authority and
    # it names the workspace root:
    #   $ cargo locate-project --workspace
    #   {"root":"/workspace/proof2/ws/Cargo.toml"}
    # A manifest that declares [workspace] is the root: keep walking while the
    # one found does not, and stop at the first that does. A single crate's
    # manifest has no [workspace] section, so the walk stops at it exactly as
    # before, and a member reached from outside its own manifest still finds the
    # root on the way up.
    _sh_ctr_w=''
    _sh_ctr_t=$_sh_ctr_d
    # STOP: A DIRECTORY WITHOUT A MANIFEST IS SKIPPED, NOT A STOPPING POINT.
    # `break` here ended the walk one level too early: from
    # ws/crates/one, the member manifest has no [workspace], the walk moved to
    # ws/crates, that directory has no Cargo.toml of its own, and `break` left
    # the loop before it ever reached ws/Cargo.toml - which IS the workspace
    # root. Measured with the trace on:
    #   + '[' -f /workspace/proof2/ws/crates/one/Cargo.toml ']'
    #   + grep -q '^\[workspace\]' .../one/Cargo.toml      -> no match
    #   + _sh_ctr_t=/workspace/proof2/ws/crates
    #   + '[' -f /workspace/proof2/ws/crates/Cargo.toml ']'  -> false, so break
    #   (never reached ws, so ctd stayed target-one-514637701)
    # A project tree has directories with no manifest between the member and
    # the root all the time, and cargo walks straight through them. Only the
    # filesystem root ends the search.
    while [ -n "$_sh_ctr_t" ] && [ "$_sh_ctr_t" != / ]; do
        [ -f "$_sh_ctr_t/Cargo.toml" ] || { case "$_sh_ctr_t" in */*) _sh_ctr_t=${_sh_ctr_t%/*} ;; *) _sh_ctr_t=/ ;; esac; continue; }
        # STOP: THE PATTERN IS `^\[workspace\]` AND NOT `[workspace]`, WHICH IS
        # A CHARACTER CLASS. `[workspace]` matches any ONE of the letters
        # w,o,r,k,s,p,a,c,e between brackets, so it matches `[package]` - every
        # manifest in the tree - and the walk stopped at the nearest one, which
        # is the member, which is the case the walk exists to get past.
        # Measured here:
        #   $ grep -q '[workspace]' ws/crates/one/Cargo.toml   ->  rc=0 (wrong)
        #   $ grep -q '^[workspace]' ws/crates/one/Cargo.toml ->  rc=1 (right)
        #   $ grep -q '^[workspace]' ws/Cargo.toml            ->  rc=0 (right)
        # The backslash is what makes the brackets literal; the anchor is what
        # makes it a section header rather than a mention of the word - and BOTH
        # still put a tool in a fragment every consumer shell sources, which
        # AGENTS.md rule 4 rules out. A TOML section header is a line that is
        # exactly `[workspace]`, so a case on the whole line is the test and it
        # needs nothing external.
        _sh_ctr_k=''
        while IFS= read -r _sh_ctr_l 2>/dev/null; do
            case "$_sh_ctr_l" in
                '[workspace]'*) _sh_ctr_k=$_sh_ctr_t; break ;;
            esac
        done < "$_sh_ctr_t/Cargo.toml"
        if [ -n "$_sh_ctr_k" ]; then
            _sh_ctr_w=$_sh_ctr_t
            break
        fi
        case "$_sh_ctr_t" in */*) _sh_ctr_t=${_sh_ctr_t%/*} ;; *) _sh_ctr_t=/ ;; esac
    done
    [ -n "$_sh_ctr_w" ] && _sh_ctr_d=$_sh_ctr_w
    _sh_ctr_b=${_sh_ctr_d##*/}
    [ -n "$_sh_ctr_b" ] || _sh_ctr_b=work
    if command -v cksum >/dev/null 2>&1; then
        _sh_ctr_s=$(printf "%s" "$_sh_ctr_d" | cksum)
        _sh_ctr_b="${_sh_ctr_b}-${_sh_ctr_s%% *}"
    else
        _sh_ctr_o=$_sh_ctr_b
        _sh_ctr_r=$_sh_ctr_d
        while [ -n "$_sh_ctr_r" ]; do
            _sh_ctr_c=${_sh_ctr_r%"${_sh_ctr_r#?}"}
            _sh_ctr_r=${_sh_ctr_r#?}
            case "$_sh_ctr_c" in
                /) _sh_ctr_o="${_sh_ctr_o}%2f" ;;
                %) _sh_ctr_o="${_sh_ctr_o}%25" ;;
                *) _sh_ctr_o="${_sh_ctr_o}$_sh_ctr_c" ;;
            esac
        done
        _sh_ctr_b=$_sh_ctr_o
    fi
    CARGO_TARGET_DIR="$SANDHOME_EXEC/target-${_sh_ctr_b}"
    export CARGO_TARGET_DIR
    SANDHOME_CARGO_TARGET_DEFAULT=$CARGO_TARGET_DIR
    export SANDHOME_CARGO_TARGET_DEFAULT
    unset _sh_ctr_d _sh_ctr_b _sh_ctr_s _sh_ctr_o _sh_ctr_r _sh_ctr_c _sh_ctr_w _sh_ctr_t
    return 0
}
RESOLVEREOF
}

tc_rust_install() {
    : "${SH_RUST_TARGETS:=${SANDHOME_RUST_TARGETS:-}}"
    sh_ri_root=$(sh_toolchain_root rust)
    # THE TOOLCHAIN DATA GOES ON THE HOME, AND ONLY ITS EXECUTABLES ARE
    # MIRRORED TO THE EXEC ROOT. The x86_64 minimal stable toolchain is
    # ~600MB, of which ~500MB is librustc_driver.so, libLLVM.so and the
    # rustlib rlibs - none of which needs execve. They are read and
    # mmap(PROT_EXEC) from a noexec mount is allowed, so the home holds them
    # and the view mirrors only the executables. In launch mode that mirror
    # is launcher copies plus a few megabytes of real spawn-target copies;
    # in copy mode it is full copies (~100MB), and the gate below prices the
    # mode this run actually chose.
    sh_ri_rustup="$sh_ri_root/rustup"
    sh_ri_cargo="$sh_ri_root/cargo"
    sh_space_need 900 home || return 1
    sh_space_need "$(tc_rust_exec_mb)" exec || return 1
    mkdir -p "$sh_ri_rustup" "$sh_ri_cargo" 2>/dev/null || return 1

    # # NOTE: AN EXISTING WORKING RUSTUP IS THE FASTEST INSTALL. If the machine already
    # has rustup, it is asked to place the toolchain under this root rather than a
    # second copy of the installer being fetched.
    sh_ri_host_rustup=''
    if sh_have rustup; then
        sh_ri_host_rustup=$(command -v rustup 2>/dev/null)
    fi
    if [ -n "$sh_ri_host_rustup" ]; then
        if RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
           rustup toolchain install stable --profile minimal \
           -c rustfmt -c clippy --no-self-update >/dev/null 2>&1; then
            sh_step "installed the stable toolchain into the home ($sh_ri_rustup); its executables mirror to the exec root"
            sh_toolchain_rust_proxies "$sh_ri_cargo" "$sh_ri_rustup" "$sh_ri_host_rustup"
            # Extra targets requested via SANDHOME_RUST_TARGETS or --target.
            if [ -n "${SH_RUST_TARGETS:-}" ]; then
                for sh_ri_t in $(sh_split_on ',' "$SH_RUST_TARGETS"); do
                    [ -n "$sh_ri_t" ] || continue
                    RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
                        rustup target add --toolchain stable "$sh_ri_t" >/dev/null 2>&1 || \
                        sh_warn "rustup could not add target $sh_ri_t"
                done
            fi
            return 0
        fi
        sh_warn 'the rustup on PATH could not install into the sandhome home root; falling back to rustup-init'
    fi

    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)
            if [ "${SH_LIBC:-unknown}" = musl ]; then
                sh_ri_triple='x86_64-unknown-linux-musl'
            else
                sh_ri_triple='x86_64-unknown-linux-gnu'
            fi ;;
        Linux:aarch64|Linux:arm64)
            if [ "${SH_LIBC:-unknown}" = musl ]; then
                sh_ri_triple='aarch64-unknown-linux-musl'
            else
                sh_ri_triple='aarch64-unknown-linux-gnu'
            fi ;;
        Linux:i386|Linux:i686) sh_ri_triple='i686-unknown-linux-gnu' ;;
        Darwin:x86_64)         sh_ri_triple='x86_64-apple-darwin' ;;
        Darwin:arm64)          sh_ri_triple='aarch64-apple-darwin' ;;
        *) sh_warn "no rustup-init for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_ri_url="https://static.rust-lang.org/rustup/dist/${sh_ri_triple}/rustup-init"
    # The installer is executed, so it is fetched onto the EXEC root and not into
    # SH_HOME_TMP: on a noexec home the download completes, chmod +x succeeds and
    # the execve that follows is refused, which reads as "rustup-init could not
    # install the toolchain" over a file that was never run.
    sh_ri_init="${SH_EXEC:-/tmp}/rustup-init.$$"
    if ! sh_fetch_verified "$sh_ri_url" "$sh_ri_init" "$(sh_pin_for "$sh_ri_url" rust)"; then
        return 1
    fi
    chmod 0755 "$sh_ri_init" 2>/dev/null || true
    if ! RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
         "$sh_ri_init" -y --no-modify-path --profile minimal \
         --default-toolchain stable -c rustfmt -c clippy >/dev/null 2>&1; then
        sh_warn 'rustup-init could not install the toolchain'
        rm -f "$sh_ri_init" 2>/dev/null
        return 1
    fi
    rm -f "$sh_ri_init" 2>/dev/null
    # rustup-init writes its own proxies, but the ensure is cheap and keeps
    # both install paths under the same guarantee.
    sh_toolchain_rust_proxies "$sh_ri_cargo" "$sh_ri_rustup" "$sh_ri_host_rustup"
    if [ -n "${SH_RUST_TARGETS:-}" ]; then
        for sh_ri_t in $(sh_split_on ',' "$SH_RUST_TARGETS"); do
            [ -n "$sh_ri_t" ] || continue
            RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
                "$sh_ri_cargo/bin/rustup" target add --toolchain stable "$sh_ri_t" >/dev/null 2>&1 || \
                sh_warn "rustup could not add target $sh_ri_t"
        done
    fi
    return 0
}

# tc_rust_sysroot_wrapper VIEW_BIN HOME_BIN SYSROOT LD_DIRS -> write the
# wrapper for one of rustc, rustdoc or clippy-driver into VIEW_BIN.
#
# A WRAPPER PASSES --sysroot, BECAUSE DETECTION CANNOT BE REDIRECTED. rustc
# derives its sysroot from the directory containing the librustc_driver.so it
# loaded, and in the view that file is a symlink back to the noexec home, so
# `rustc --print sysroot` answers with the home and the link then spawns
# <home>/.../gcc-ld/ld.lld, which cannot be exec'd:
#   collect2: fatal error: posix_spawnp: Permission denied
# No environment variable moves that sysroot (SYSROOT, RUSTC_SYSROOT and
# RUST_SYSROOT were all measured and ignored); --sysroot on the command line
# is the one spelling that works. The memfd runner does not change this: the
# driver still loads from the home path, so the wrapper is needed in launch
# mode and in copy mode alike.
#
# In launch mode the wrapper runs the home binary through sandhome-memexec;
# in copy mode it execs the real binary kept beside it as <name>.real.
tc_rust_sysroot_wrapper() {
    sh_rw_view=$1
    sh_rw_home=$2
    sh_rw_sysroot=$3
    sh_rw_ld=$4
    sh_rw_name=${sh_rw_view##*/}
    # The live-target sync needs both rustlib dirs baked in: the view one
    # this wrapper already names as its sysroot, and the home one beside
    # the home binary it runs. Derived here, once, so every build pays no
    # lookup for what install time already knew. The home argument is a
    # binary path (.../bin/rustc), so two levels come off, not one.
    sh_rw_home_sysroot=${sh_rw_home%/bin/*}
    case "$sh_rw_home_sysroot" in "$sh_rw_home") sh_rw_home_sysroot=${sh_rw_home%/*}; sh_rw_home_sysroot=${sh_rw_home_sysroot%/*} ;; esac
    sh_rw_view_rustlib="$sh_rw_sysroot/lib/rustlib"
    sh_rw_home_rustlib="$sh_rw_home_sysroot/lib/rustlib"
    # The per-build sync block, emitted into every wrapper below. A raw
    # `rustup target add NEW` lands in the HOME only, after the last
    # promote; without this the next `cargo build --target NEW` fails E0463
    # pointing back at the command just run (issue #115). The wrapper runs
    # before every rustc, so the missing view entry is linked here, at use
    # time, with no repair round-trip. Best-effort and silent: a read-only
    # view, a missing home, or a target carrying executables (left mirrored
    # by the install-time pass) simply skips. Dangling view links whose home
    # target was removed are dropped, so `target remove` converges too.
    sh_rw_sync=$(cat <<SYNCEOF
# sandhome: live-target sync (issue #115). Home-only targets appear here.
if [ -d "$sh_rw_home_rustlib" ] && [ -d "$sh_rw_view_rustlib" ]; then
    for sh_lts_d in "$sh_rw_home_rustlib"/*; do
        [ -d "\$sh_lts_d" ] || continue
        sh_lts_b=\${sh_lts_d##*/}
        [ -e "$sh_rw_view_rustlib/\$sh_lts_b" ] || [ -L "$sh_rw_view_rustlib/\$sh_lts_b" ] || {
            [ -d "\$sh_lts_d/bin" ] || ln -sfn "\$sh_lts_d" "$sh_rw_view_rustlib/\$sh_lts_b" 2>/dev/null || true
        }
    done
    for sh_lts_v in "$sh_rw_view_rustlib"/*; do
        [ -L "\$sh_lts_v" ] || continue
        [ -e "\$sh_lts_v" ] || rm -f "\$sh_lts_v" 2>/dev/null || true
    done
fi
SYNCEOF
)
    if [ "${SH_VIEW_MODE:-copy}" = launch ] && sh_memexec_built; then
        sh_rw_run="$(sh_memexec_bin)"
        sh_rw_target=$sh_rw_home
    else
        # # STOP: A DAMAGED .real IS REBUILT, NOT PRESERVED. The guard was "the
        # file is missing", so a `.real` that exists but is not the compiler
        # survived every repair, and the wrapper then exec'd itself:
        #   rustc.real: 19: exec: .../bin/rustc.real: Argument list too long
        # which reads as a kernel limit and is neither (measured on a view a
        # launch-mode fixture had stamped over; the same rig compiled and ran a
        # program once the pair was rebuilt). The test is CONTENT, not
        # existence: a real compiler is an ELF image, and a sysroot wrapper is a
        # #! script, so the first two bytes decide. The home copy is the source
        # of truth and it is a real binary on the home in every mode.
        sh_rw_bad=no
        if [ -f "$sh_rw_view.real" ]; then
            sh_rw_head=$(sed -n '1p' "$sh_rw_view.real" 2>/dev/null | cut -c1-2)
            case "$sh_rw_head" in
                '#!') sh_rw_bad=yes ;;
            esac
        else
            sh_rw_bad=yes
        fi
        if [ "$sh_rw_bad" = yes ]; then
            # The home binary is the real one; the view copy is the wrapper we
            # are about to write. Anything already at sh_rw_view that is NOT a
            # wrapper script is kept as the .real, which is what a promote that
            # already mirrored the ELF leaves here.
            if sh_is_script "$sh_rw_view" 2>/dev/null; then
                rm -f "$sh_rw_view.real" 2>/dev/null
                cp -f "$sh_rw_home" "$sh_rw_view.real" 2>/dev/null || return 1
            else
                mv -f "$sh_rw_view" "$sh_rw_view.real" 2>/dev/null || return 1
            fi
        fi
        sh_rw_run=''
        sh_rw_target="$sh_rw_view.real"
    fi
    if [ "$sh_rw_name" = clippy-driver ]; then
        # clippy IS DRIVEN THROUGH RUSTC_WORKSPACE_WRAPPER, WHICH CALLS
        # `clippy-driver <path-to-rustc> <rustc args>`. The rustc path is
        # argv[1] and has to stay first, so --sysroot goes after it. Putting
        # --sysroot first made the driver read the rustc path and then `-`
        # as two input files:
        #   error: multiple input filenames provided (first two filenames
        #   are .../bin/rustc and -)
        {
            printf '#!/bin/sh\n'
            printf '# sandhome: sysroot wrapper\n'
            if [ -n "$sh_rw_ld" ]; then
                printf 'LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$sh_rw_ld"
                printf 'export LD_LIBRARY_PATH\n'
            fi
            printf '%s\n' "$sh_rw_sync"
            printf 'if [ -n "${1:-}" ] && [ -x "$1" ]; then\n'
            printf '    sh_rw_w="$1"; shift\n'
            if [ -n "$sh_rw_run" ]; then
                printf '    exec "%s" "%s" "$sh_rw_w" --sysroot "%s" "$@"\n' \
                    "$sh_rw_run" "$sh_rw_target" "$sh_rw_sysroot"
            else
                printf '    exec "%s" "$sh_rw_w" --sysroot "%s" "$@"\n' \
                    "$sh_rw_target" "$sh_rw_sysroot"
            fi
            printf 'fi\n'
            if [ -n "$sh_rw_run" ]; then
                printf 'exec "%s" "%s" --sysroot "%s" "$@"\n' \
                    "$sh_rw_run" "$sh_rw_target" "$sh_rw_sysroot"
            else
                printf 'exec "%s" --sysroot "%s" "$@"\n' \
                    "$sh_rw_target" "$sh_rw_sysroot"
            fi
        } > "$sh_rw_view" 2>/dev/null || return 1
    else
        {
            printf '#!/bin/sh\n'
            printf '# sandhome: sysroot wrapper\n'
            if [ -n "$sh_rw_ld" ]; then
                printf 'LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$sh_rw_ld"
                printf 'export LD_LIBRARY_PATH\n'
            fi
            printf '%s\n' "$sh_rw_sync"
            if [ -n "$sh_rw_run" ]; then
                printf 'exec "%s" "%s" --sysroot "%s" "$@"\n' \
                    "$sh_rw_run" "$sh_rw_target" "$sh_rw_sysroot"
            else
                printf 'exec "%s" --sysroot "%s" "$@"\n' \
                    "$sh_rw_target" "$sh_rw_sysroot"
            fi
        } > "$sh_rw_view" 2>/dev/null || return 1
    fi
    chmod 0755 "$sh_rw_view" 2>/dev/null || true
    return 0
}

# tc_rust_lib_dirs -> the toolchain lib directories that exist, colon
# separated, or nothing. A rustc run from memory cannot resolve its sibling
# librustc_driver through $ORIGIN (its exe is a memfd), so the loader needs
# these on LD_LIBRARY_PATH. Only directories under this toolchain are named:
# a global library path would leak this toolchain's libraries into every
# other tool's link.
tc_rust_lib_dirs() {
    sh_rld_root=$(sh_toolchain_root rust)
    sh_rld_out=''
    for sh_rld_d in "$sh_rld_root"/rustup/toolchains/*/lib; do
        [ -d "$sh_rld_d" ] || continue
        if [ -z "$sh_rld_out" ]; then
            sh_rld_out=$sh_rld_d
        else
            sh_rld_out="$sh_rld_out:$sh_rld_d"
        fi
    done
    printf '%s' "$sh_rld_out"
}

# tc_rust_copy_bins -> the executables that must be REAL copies in the view
# even in launch mode, space separated, relative to the toolchain root.
# rustc links by spawning <sysroot>/lib/rustlib/<host>/bin/gcc-ld/ld.lld
# through the system cc, and that wrapper locates its siblings exe-relative:
# a launcher copy runs from a memfd image with no stable directory and dies
# with `lld-wrapper: parent directory could not be determined`, while a real
# copy of the same file links fine. The same holds for cargo-clippy, which
# execs `clippy-driver` from beside its own executable: from a memfd image
# that dirname is empty and cargo dies with `` could not execute `/clippy-driver` ``.
# cargo-fmt fails the same way finding rustfmt (`Could not run rustfmt`).
# rust-lld is spawned the same way. The
# triple is globbed because it is only known once the toolchain is here.
# Measured: ~4MB (rust-lld plus the four gcc-ld wrappers).
tc_rust_copy_bins() {
    sh_rcb_root=$(sh_toolchain_root rust)
    for sh_rcb_b in "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/ld.lld \
                     "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/ld64.lld \
                     "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/lld-link \
                     "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/wasm-ld \
                     "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/rust-lld \
                     "$sh_rcb_root"/rustup/toolchains/*/bin/cargo-clippy \
                     "$sh_rcb_root"/rustup/toolchains/*/bin/cargo-fmt; do
        [ -f "$sh_rcb_b" ] || continue
        printf '%s ' "${sh_rcb_b#"$sh_rcb_root"/}"
    done
}

# tc_rust_link_data_targets VIEW HOME -> make each installed target's rustlib
# in the view a link to the HOME tree when that target runs nothing, so a raw
# `rustup target add <triple>` is visible to the next build instead of waiting
# for a promote that may never come (issue #115). The target snapshot is taken
# at promote time, so adding `aarch64-unknown-linux-musl` printed success and
# then `cargo build --target` failed with "can't find crate for std". The HOST
# target keeps its mirrored copy: it holds the gcc-ld linkers rustc spawns, and
# a link into a noexec home would make them unrunnable. A cross target is
# rlibs, objects and crt archives the linker reads, so a link is both safe and
# current by construction. A target that holds an executable on either side is
# left mirrored.
#
# REDUNDANCY: TWO DIRECTIONS, NOT ONE. The first loop links view dirs that
# already exist; the second loop creates view links for home dirs that have no
# view entry at all. Without the second loop a target added AFTER the promote
# (the exact raw `rustup target add` path this exists for) has no view dir to
# convert, so the next build still fails E0463. Both loops share the same
# executable check, so a target that grows a linker later stays mirrored.
tc_rust_link_data_targets() {
    sh_rld_view=$1
    sh_rld_home=$2
    if [ -z "$sh_rld_view" ] || [ -z "$sh_rld_home" ]; then
        return 0
    fi
    [ -d "$sh_rld_view/rustup/toolchains" ] || return 0
    for sh_rld_tc in "$sh_rld_view"/rustup/toolchains/*; do
        [ -d "$sh_rld_tc" ] || continue
        sh_rld_rel=${sh_rld_tc#"$sh_rld_view"/}
        for sh_rld_t in "$sh_rld_tc"/lib/rustlib/*; do
            [ -d "$sh_rld_t" ] || continue
            [ -L "$sh_rld_t" ] && continue
            sh_rld_home_t="$sh_rld_home/$sh_rld_rel/lib/rustlib/${sh_rld_t##*/}"
            sh_rld_bad=no
            for sh_rld_side in "$sh_rld_t" "$sh_rld_home_t"; do
                for sh_rld_f in "$sh_rld_side"/bin/* "$sh_rld_side"/bin/*/*; do
                    if [ -f "$sh_rld_f" ] && sh_is_exec_file "$sh_rld_f"; then
                        sh_rld_bad=yes
                        break
                    fi
                done
                [ "$sh_rld_bad" = no ] || break
            done
            [ "$sh_rld_bad" = no ] || continue
            [ -d "$sh_rld_home_t" ] || continue
            rm -rf "$sh_rld_t" 2>/dev/null || continue
            ln -sfn "$sh_rld_home_t" "$sh_rld_t" 2>/dev/null || true
        done
        # Second direction: a home target with no view entry at all. This is
        # the raw-add path: `rustup target add NEW` lands in HOME only, and
        # the view has nothing to convert. Link it in so the next build sees
        # it without a repair. Host-named dirs are still checked for
        # executables first; a missing home dir is not an error.
        for sh_rld_ht in "$sh_rld_home/$sh_rld_rel"/lib/rustlib/*; do
            [ -d "$sh_rld_ht" ] || continue
            sh_rld_vt="$sh_rld_tc/lib/rustlib/${sh_rld_ht##*/}"
            [ -e "$sh_rld_vt" ] && continue
            sh_rld_bad=no
            for sh_rld_f in "$sh_rld_ht"/bin/* "$sh_rld_ht"/bin/*/*; do
                if [ -f "$sh_rld_f" ] && sh_is_exec_file "$sh_rld_f"; then
                    sh_rld_bad=yes
                    break
                fi
            done
            [ "$sh_rld_bad" = no ] || continue
            ln -sfn "$sh_rld_ht" "$sh_rld_vt" 2>/dev/null || true
        done
    done
    return 0
}

# tc_rust_sync_targets VIEW HOME -> the repair-time entry point for the same
# invariant. A view rebuilt from an older home (or a home that gained targets
# while the view sat stale) converges in one call: existing view dirs become
# links where safe, and home-only targets appear as links. Returns 0 always;
# a caller that needs the count reads the disk, not this status.
tc_rust_sync_targets() {
    tc_rust_link_data_targets "$1" "$2" || true
    return 0
}

# tc_rust_ld_fragment FILE DIRS -> append the LD_LIBRARY_PATH block for DIRS
# to FILE. Split out so the heredoc is testable under `set -u`: an unquoted
# heredoc expands every `$`, and one bare `$ORIGIN` in a comment aborted the
# whole env write mid-fragment on the repair path (which runs under `set -u`)
# while every test passed (they run without it). The fragment then carried no
# LD_LIBRARY_PATH and no RUSTC, and every launcher died on its missing driver.
tc_rust_ld_fragment() {
    if [ -z "${2:-}" ]; then
        return 0
    fi
    cat >> "$1" <<EOF
# A rustc run from memory cannot resolve its sibling librustc_driver through
# \$ORIGIN (its exe is a memfd), so the toolchain lib rides LD_LIBRARY_PATH.
# Only this toolchain's own lib is named: nothing else's link may see it.
LD_LIBRARY_PATH="$2\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
EOF
}

# tc_rust_ensure_targets [RUSTUP_BIN [RUSTUP_HOME]] -> add every target in
# SH_RUST_TARGETS the toolchain does not already have. Present targets are
# skipped, so re-runs are no-ops; missing ones are added and named. Without
# a rustup the request is named rather than silently dropped. RUSTUP_BIN
# defaults to the rustup on PATH (the adopted toolchain's own); a managed
# tree passes its proxy with its RUSTUP_HOME scoped, so the add lands in the
# sandhome home and never in the operator's own rustup home.
#
# STOP: PROBE-GREEN NEVER RUNS tc_rust_install, ON ANY PATH. The adopt branch
# was fixed first (issue #80), and a naive consumer run then showed the same
# hole one level deeper: a MANAGED tree asked for a new --target answered
# "adopting it" in 0.8s and added nothing, and the wasm build died on a
# missing std. Requested targets are owed on every path that skips the
# install, so both call this.
tc_rust_ensure_targets() {
    [ -n "${SH_RUST_TARGETS:-}" ] || return 0
    sh_ret_bin=${1:-rustup}
    sh_ret_home=${2:-}
    if [ -n "${1:-}" ]; then
        if [ ! -x "$sh_ret_bin" ]; then
            sh_warn "--target was requested ($SH_RUST_TARGETS) but $sh_ret_bin is not executable"
            return 0
        fi
    elif ! sh_have rustup; then
        sh_warn "--target was requested ($SH_RUST_TARGETS) but no rustup answers here; run 'sandhome install --force rust --target $SH_RUST_TARGETS' for a managed toolchain"
        return 0
    fi
    if [ -n "$sh_ret_home" ]; then
        sh_ret_have=$(RUSTUP_HOME="$sh_ret_home" "$sh_ret_bin" target list --installed 2>/dev/null)
    else
        sh_ret_have=$("$sh_ret_bin" target list --installed 2>/dev/null)
    fi
    for sh_ret_t in $(sh_split_on ',' "$SH_RUST_TARGETS"); do
        [ -n "$sh_ret_t" ] || continue
        case "$sh_ret_have" in
            *"$sh_ret_t"*) continue ;;
        esac
        if [ -n "$sh_ret_home" ]; then
            if RUSTUP_HOME="$sh_ret_home" "$sh_ret_bin" target add "$sh_ret_t" >/dev/null 2>&1; then
                sh_step "added rust target $sh_ret_t"
                sh_ret_have="$sh_ret_have $sh_ret_t"
            else
                sh_warn "rustup could not add target $sh_ret_t"
            fi
        else
            if "$sh_ret_bin" target add "$sh_ret_t" >/dev/null 2>&1; then
                sh_step "added rust target $sh_ret_t"
                sh_ret_have="$sh_ret_have $sh_ret_t"
            else
                sh_warn "rustup could not add target $sh_ret_t"
            fi
        fi
    done
    return 0
}
# tc_rust_writable_rustup ADOPTED_HOME -> sets SH_RUST_WRITABLE_RUSTUP to a
# RUSTUP_HOME rustup can write, or to the adopted home when it already can.
#
# `rustup target add` stages under $RUSTUP_HOME/tmp and unpacks into
# $RUSTUP_HOME/toolchains/<tc>/lib/rustlib, so an adopted home on the
# read-only mount answers every target with "Read-only file system ... (os
# error 30)" and STILL exits 0: `rustup target add X && cargo build` proceeds
# and later dies with a missing-std error that names nothing (issue #159). The
# existing detection only asks whether the home has a default toolchain, which
# a read-only home answers perfectly. This asks whether it takes a write, by
# writing one, and when it does not it builds a home on the exec root with the
# adopted toolchains symlinked in and the settings copied, so every target has
# a writable root. No step output here: the caller is a command substitution's
# sibling, and a status line on stdout would become part of the value.
tc_rust_writable_rustup() {
    sh_rw_adopted=$1
    SH_RUST_WRITABLE_RUSTUP=''
    [ -n "$sh_rw_adopted" ] || return 1
    mkdir -p "$sh_rw_adopted/tmp" 2>/dev/null
    sh_rw_probe="$sh_rw_adopted/tmp/.sandhome-write.$$"
    if ( : > "$sh_rw_probe" ) 2>/dev/null; then
        rm -f "$sh_rw_probe" 2>/dev/null
        SH_RUST_WRITABLE_RUSTUP=$sh_rw_adopted
        return 0
    fi
    sh_rw_exec=${SANDHOME_EXEC:-${SH_EXEC:-}}/rustup
    case "${SANDHOME_EXEC:-${SH_EXEC:-}}" in '') return 1 ;; esac
    mkdir -p "$sh_rw_exec/toolchains" "$sh_rw_exec/tmp" 2>/dev/null || return 1
    for sh_rw_tc in "$sh_rw_adopted"/toolchains/*; do
        [ -e "$sh_rw_tc" ] || continue
        ln -sfn "$sh_rw_tc" "$sh_rw_exec/toolchains/${sh_rw_tc##*/}" 2>/dev/null || true
    done
    if [ -r "$sh_rw_adopted/settings.toml" ]; then
        cp -f "$sh_rw_adopted/settings.toml" "$sh_rw_exec/settings.toml" 2>/dev/null || true
    fi
    SH_RUST_WRITABLE_RUSTUP=$sh_rw_exec
    return 0
}

tc_rust_env() {
    : "${SH_RUST_TARGETS:=${SANDHOME_RUST_TARGETS:-}}"
    sh_re_root=$(sh_toolchain_root rust)
    sh_re_rustup="$sh_re_root/rustup"
    sh_re_cargo="$sh_re_root/cargo"
    sh_re_view=$(sh_toolchain_view rust)
    # Adopted system rustc: still write a fragment when the home is split, so
    # the linker workaround and rustup exposure apply. The toolchain bin that
    # answered the probe keeps winning on PATH; this only adds what was missing.
    sh_re_installed=no
    if [ -d "$sh_re_rustup/toolchains" ] || [ -d "$sh_re_cargo/bin" ]; then
        sh_re_installed=yes
    fi
    if [ "$sh_re_installed" = no ] && sh_toolchain_probe rust; then
        # Pure adoption: no sandhome tree. The toolchain bin that answered the
        # probe keeps winning on PATH, and CARGO_INSTALL_ROOT still points at
        # the exec root so `cargo install` puts a runnable binary somewhere it
        # can be run from.
        sh_re_which=$(sh_path_where rustc)
        sh_re_dir=${sh_re_which%/*}
        sh_env_write_fragment rust <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
CARGO_INSTALL_ROOT="\$SANDHOME_EXEC/cargo-install"
export CARGO_INSTALL_ROOT
case ":\$PATH:" in
  *":\$SANDHOME_EXEC/cargo-install/bin:"*) ;;
  *) PATH="\$SANDHOME_EXEC/cargo-install/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":$sh_re_dir:"*) ;;
  *) PATH="$sh_re_dir:\$PATH" ;;
esac
# # STOP: THE ADOPTED PATH GETS THE WRAPPER PREPEND TOO, AND IT HAS TO BE THE
# LAST PREPEND SO IT LANDS FIRST (issue #183). This branch writes its own
# fragment and it did not have the cargo-wrap prepend at all, so the wrapper
# this same function creates was on no PATH whatsoever: the directory existed,
# held a working wrapper, and was reached by nothing. The adopted toolchain bin
# above is prepended by this branch and it holds the real cargo, so the wrapper
# directory has to come after it in the text and before it on PATH.
case ":\$PATH:" in
  *":$SH_EXEC/cargo-wrap:"*) ;;
  *) PATH="$SH_EXEC/cargo-wrap:\$PATH" ;;
esac
export PATH
$(sh_rust_target_resolver)
EOF
        # # STOP: A BORROWED rustup IS USUALLY A SHIM, AND A SHIM NEEDS A
        # RUSTUP_HOME THAT HAS A DEFAULT TOOLCHAIN. A host that installs rust
        # through rustup has `rustc` as a symlink to the rustup binary, and that
        # binary resolves the toolchain through RUSTUP_HOME. With no such home, or
        # one whose settings.toml names no default, the shim answers:
        #   error: rustup could not choose a version of rustc to run, because one
        #   wasn't specified explicitly, and no default is configured.
        # which is a broken compiler wearing a working `rustc --version`.
        #
        # The question is NOT "is RUSTUP_HOME set". It was, in the run that found
        # this: the caller's environment exported it, so a guard on the variable
        # alone passed and nothing was written - and the consumer's shell, which
        # did not inherit it, got a shim with no toolchain. The question is
        # whether the home the shim will read has a default_toolchain in it, and
        # the answer is measured by looking, not by asking whether a name is set.
        # The list is the usual locations, plus the one already in the
        # environment, so a home elsewhere is not skipped.
        sh_re_rh_ok=no
        for sh_re_rh in ${RUSTUP_HOME:-} "$HOME/.rustup" "$HOME/.local/share/rustup" /usr/local/share/rustup; do
            [ -n "$sh_re_rh" ] || continue
            case "$(cat "$sh_re_rh/settings.toml" 2>/dev/null)" in
                *default_toolchain*) sh_re_rh_ok=$sh_re_rh; break ;;
            esac
        done
        if [ "$sh_re_rh_ok" = no ] && [ -x "$sh_re_dir/rustup" ]; then
            for sh_re_rh in "$HOME/.rustup" "$HOME/.local/share/rustup" /usr/local/share/rustup; do
                if [ -r "$sh_re_rh/settings.toml" ]; then
                    sh_re_rh_ok=$sh_re_rh
                    break
                fi
            done
        fi
        if [ "$sh_re_rh_ok" != no ]; then
            # A home that resolves a default toolchain can still refuse every
            # write, and rustup exits 0 while failing (issue #159). Point
            # RUSTUP_HOME at a root rustup can write before it is recorded.
            sh_re_rh_use=$sh_re_rh_ok
            if tc_rust_writable_rustup "$sh_re_rh_ok"; then
                sh_re_rh_use=$SH_RUST_WRITABLE_RUSTUP
            fi
            [ -n "$sh_re_rh_use" ] || sh_re_rh_use=$sh_re_rh_ok
            RUSTUP_HOME=$sh_re_rh_use
            export RUSTUP_HOME
            cat >> "$(sh_env_fragment rust)" <<SHIMEOF
# The rustc beside this rustup is a shim to it, and a shim needs a RUSTUP_HOME
# with a default toolchain: without one, "rustc --version" and a link both fail
# with "rustup could not choose a version of rustc to run". A home that cannot
# take a write is replaced by one on the exec root with the toolchains linked
# in, so rustup target add has somewhere to unpack (issue #159).
export RUSTUP_HOME="$sh_re_rh_use"
SHIMEOF
            if [ "$sh_re_rh_use" != "$sh_re_rh_ok" ]; then
                sh_step "the adopted RUSTUP_HOME $sh_re_rh_ok cannot take a write; using $sh_re_rh_use with the toolchains symlinked"
            else
                sh_step "the adopted rustc is a rustup shim; RUSTUP_HOME=$sh_re_rh_use"
            fi
        fi
        # # STOP: A BORROWED TOOLCHAIN THAT CANNOT LINK GETS A WORKING ONE
        # INSTALLED, NOT A LINKER FLAG. This branch used to write
        # RUSTFLAGS=-fuse-ld=bfd and return, and that cannot work: the sysroot of
        # a borrowed rustc is on the noexec home, the ld.lld inside it cannot be
        # exec'd, and rustc appends its own -fuse-ld=lld and -B<sysroot> after
        # any -C link-arg, so the flag is overridden and the noexec path returns
        # (issue #52). The repair that works is a toolchain whose sysroot is the
        # view, so that is what happens. A borrow that links fine is left alone,
        # so the common case costs one behavioural probe and no download.
        if [ "${SH_HOME_EXEC:-unknown}" != yes ] && ! tc_rust_behavioural >/dev/null 2>&1; then
            sh_warn "the rustc on PATH cannot link on this split root ($SH_HOME noexec); installing a toolchain on the home with an exec view instead of working around it"
            if sh_toolchain_ensure_rust_exec; then
                sh_re_installed=yes
            fi
        fi
        # STOP: AN ADOPTED RUST STILL OWES ITS REQUESTED TARGETS (issue #80).
        # `install rust --target T` on the adopt path used to exit 0 having
        # added nothing: tc_rust_install (which runs `rustup target add`)
        # never runs for a working copy that is already here. Against the
        # adopted toolchain's own rustup, which manages the adopted home.
        if [ "$sh_re_installed" = no ]; then
            tc_rust_ensure_targets
        fi
        # # STOP: AN ADOPTED RUST STILL OWES THE TARGET-DIR WRAPPER (issue
        # #183). sh_toolchain_rust_target_wrapper had exactly one call site in
        # the tree, and it was below the `return 0` this branch reaches, so
        # adoption never wrote it. Measured on a host that carries rust: the
        # setup adopted it, reported toolchain.rust=rustc 1.98.1 with a green
        # doctor, and left $SANDHOME_EXEC/bin/cargo and
        # $SANDHOME_EXEC/cargo-wrap absent, so a fresh hook-only shell found
        # no `cargo` at all while the report described a working toolchain.
        #
        # The wrapper is a property of the TOOLCHAIN, not of the way the
        # toolchain arrived, so it is written on both paths. This is the same
        # shape as issue #80 above, which is why the two are handled together:
        # an early return in tc_rust_env silently drops whatever the rest of
        # the function owes. The wrapper goes on the exec bin beside the
        # adopted cargo so the hook can serve it, and the same function drops
        # the $SH_EXEC/cargo-wrap entry the fragment prepends.
        sh_re_adopt_wrapper_done=yes
        if [ -n "${SH_EXEC_BIN:-}" ] && [ -n "${SH_EXEC:-}" ]; then
            for sh_re_aw in \
                "${SH_EXEC_BIN}/cargo" \
                "${SH_EXEC}/views/rust/cargo/bin/cargo" \
                "${SH_EXEC}/views/rust/rustup/toolchains"/*/bin/cargo
            do
                [ -x "$sh_re_aw" ] || continue
                sh_toolchain_rust_target_wrapper "$SH_EXEC_BIN" "$sh_re_aw"
                break
            done
        fi
        [ "$sh_re_installed" = yes ] || return 0
    fi
    # Proxies before the view search: a tree installed before they were
    # ensured has no CARGO_HOME/bin, and the framework's promote already ran
    # before this function, so newly created proxies are mirrored into the
    # view here, per the current mode, rather than a cycle late. This runs
    # only for an installed tree; pure adoption returns above and grows no
    # home directories.
    sh_re_host_rustup=''
    if sh_have rustup; then
        # The exec view is excluded: after an adopt cycle `command -v rustup`
        # answers the view's own link, and proxying the home to the view
        # builds a three-cycle (home -> exec -> view -> exec) that doctor
        # then reports as a broken exec link and `rustup` reports as too
        # many levels of symbolic links. sh_path_where skips SH_EXEC_BIN.
        if command -v sh_path_where >/dev/null 2>&1; then
            sh_re_host_rustup=$(sh_path_where rustup 2>/dev/null)
        else
            sh_re_host_rustup=$(command -v rustup 2>/dev/null)
        fi
        case "$sh_re_host_rustup" in
            "${SH_EXEC:-/tmp}"/*) sh_re_host_rustup='' ;;
        esac
    fi
    # # STOP: THE REPAIR PATH PROXIES THE WHOLE DECLARED SET, NOT TWO NAMES. The
    # repair mirrored only cargo and rustup, so a repaired view healed the
    # commands it already knew and left rustc, rustdoc, cargo-clippy and
    # cargo-fmt off PATH until the next install cycle (issue #135). The set is
    # read from TC_rust_BINS, so the repair and the install cannot disagree
    # about which names are owed, and a name with no binary under the toolchain
    # is skipped rather than linked to nothing.
    sh_re_owed=''
    eval "sh_re_owed=\${TC_rust_BINS:-}"
    for sh_re_rel in $sh_re_owed; do
        sh_re_p=${sh_re_rel##*/}
        [ -f "$sh_re_cargo/bin/$sh_re_p" ] || continue
        sh_re_pv="$sh_re_view/cargo/bin/$sh_re_p"
        if [ ! -e "$sh_re_pv" ]; then
            mkdir -p "$sh_re_view/cargo/bin" 2>/dev/null || continue
            # A COPY-LISTED BINARY IS NEVER STAMPED, WHATEVER THE MODE. The
            # list exists because a memfd image has no stable directory, and
            # the promote step honoured that for the whole tree; the repair
            # stamped them anyway, which is how a repaired view could be less
            # faithful than an installed one. The resolver lives in the
            # library, which the repair path may not have sourced (the
            # isolated runner gives a module common.sh and the module only),
            # so its absence falls back to stamping: the old behaviour, and
            # never a silent no-copy.
            if [ "${SH_VIEW_MODE:-copy}" = launch ] && \
               { ! command -v sh_copy_only_set >/dev/null 2>&1 || ! sh_copy_only_set rust && ! sh_copy_listed "cargo/bin/$sh_re_p"; }; then
                sh_memexec_stamp "$sh_re_cargo/bin/$sh_re_p" "$sh_re_pv" || \
                    cp -f "$sh_re_cargo/bin/$sh_re_p" "$sh_re_pv" 2>/dev/null || true
            else
                rm -f "$sh_re_pv" 2>/dev/null
                cp -f "$sh_re_cargo/bin/$sh_re_p" "$sh_re_pv" 2>/dev/null || true
            fi
            [ -e "$sh_re_pv" ] && chmod 0755 "$sh_re_pv" 2>/dev/null || true
        fi
        # The framework's bin links ran inside the promote above, before these
        # entries existed, so link them here too: without this a repair heals
        # the view but leaves the command off PATH until the next cycle.
        if [ -e "$sh_re_pv" ]; then
            mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
            ln -sfn "$sh_re_pv" "$SH_EXEC_BIN/$sh_re_p" 2>/dev/null || true
        fi
    done
    # # STOP: THE PROXIES ARE REWRITTEN ON EVERY REPAIR, NOT ONLY WHEN A BINARY
    # IS MISSING. The guard used to be "cargo or rustup is not executable", and
    # rustup's own proxies answer that test: they are executable symlinks. So
    # the proxies that resolve the toolchain through the noexec HOME survived
    # every repair, and `cargo --version` from a fresh shell kept answering
    # "error: command failed: 'cargo': Permission denied (os error 13)" while
    # the same command worked in any sourced shell (issue #135, measured). The
    # writer is idempotent by construction - it leaves a link alone unless it
    # points at rustup - so calling it every time is cheap and cannot rewrite a
    # link that already works.
    sh_toolchain_rust_proxies "$sh_re_cargo" "$sh_re_rustup" "$sh_re_host_rustup"
    # THE VIEW CARRIES THE REAL BINARIES, NOT THE HOME's PROXIES. The promote
    # mirrors the home tree, and the home's cargo/bin/cargo is rustup's own
    # proxy (cargo -> rustup), so the view's exec-bin entries all become proxies
    # again and a fresh shell - which reaches them through the global hook -
    # fails with "command failed: 'cargo': Permission denied", because the
    # proxy resolves the toolchain under the noexec HOME. So after the proxies
    # are written in the home, the view's entries are REPOINTED at the real
    # binaries in the view's own toolchain dir. A sourced shell already works
    # (env.sh prepends that dir), so this makes the hook agree with it.
    sh_re_tc=''
    for sh_re_d in "$sh_re_view"/rustup/toolchains/*/bin; do
        [ -d "$sh_re_d" ] && sh_re_tc=$sh_re_d && break
    done
    if [ -n "$sh_re_tc" ]; then
        for sh_re_p in cargo rustc rustdoc cargo-clippy cargo-fmt; do
            [ -e "$sh_re_tc/$sh_re_p" ] || continue
            sh_re_pv="$sh_re_view/cargo/bin/$sh_re_p"
            mkdir -p "$sh_re_view/cargo/bin" 2>/dev/null || continue
            rm -f "$sh_re_pv" 2>/dev/null
            ln -sfn "$sh_re_tc/$sh_re_p" "$sh_re_pv" 2>/dev/null || \
                cp -f "$sh_re_tc/$sh_re_p" "$sh_re_pv" 2>/dev/null || true
        done
        # and the exec-bin links that reach them
        for sh_re_p in cargo rustc rustdoc cargo-clippy cargo-fmt; do
            [ -e "$sh_re_view/cargo/bin/$sh_re_p" ] || continue
            mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
            ln -sfn "$sh_re_view/cargo/bin/$sh_re_p" "$SH_EXEC_BIN/$sh_re_p" 2>/dev/null || true
        done
        # STOP: cargo GETS A WRAPPER ON THE EXEC BIN, NOT A LINK, AND THIS IS
        # THE WHOLE OF THE REMAINING #167 DEFECT.
        #
        # env.sh sets CARGO_TARGET_DIR once, when the shell starts, from the
        # $PWD at that moment. A login shell sources env.sh and THEN the
        # consumer cds into their project, so the variable names whichever
        # directory the shell happened to start in. Measured here, on main and
        # on this branch alike, through a real login shell:
        #   bash -lc 'cd /workspace/proof/a/dup && cargo run -q'  ->  PROJECT-A
        #   bash -lc 'cd /workspace/proof/b/dup && cargo run -q'  ->  PROJECT-A
        # with both reporting ctd=target-workspace-306203429: one target dir for
        # two crates, so the second is "fresh" and runs the first's binary.
        #
        # It cannot be fixed in the fragment. POSIX sh has no way to re-run code
        # on cd without a trap or a prompt command, and AGENTS.md rule 6 forbids
        # both in this profile ("defines no alias and no prompt"). A shell hook
        # would also break every consumer that is not interactive. So the
        # resolution moves to the one place that runs per COMMAND: the wrapper
        # below recomputes the id from the directory cargo is actually run in,
        # and only when the caller has not set the variable themselves.
        sh_toolchain_rust_target_wrapper "$SH_EXEC_BIN" "$sh_re_view/cargo/bin/cargo"
    fi
    # Requested targets are owed here too, against this tree's own rustup
    # with its home scoped: probe-green skips tc_rust_install on the managed
    # path exactly the way it skips it on the adopt path, and a bare rustup
    # here would manage the operator's own home instead of this tree's.
    if [ -x "$sh_re_cargo/bin/rustup" ]; then
        tc_rust_ensure_targets "$sh_re_cargo/bin/rustup" "$sh_re_rustup"
    elif [ -n "${SH_RUST_TARGETS:-}" ]; then
        tc_rust_ensure_targets
    fi
    # The view bin is searched first: on a split root it is the only copy that
    # can execve, and it is where the copied gcc-ld/ld.lld sits, so its sysroot
    # is the one the wrapper must name. The home copy is the fallback for a home
    # that already runs binaries, where the view and the home are the same tree.
    sh_re_bin=''
    for sh_re_d in "$sh_re_view"/rustup/toolchains/*/bin \
                   "$sh_re_root"/rustup/toolchains/*/bin; do
        if [ -x "$sh_re_d/rustc" ]; then
            sh_re_bin=$sh_re_d
            break
        fi
    done
    if [ -z "$sh_re_bin" ]; then
        sh_warn 'no rustc was found under the rustup root after install'
        return 1
    fi
    sh_re_sysroot=${sh_re_bin%/bin}
    sh_re_home_bin=${sh_re_bin#"$sh_re_view"}
    case "$sh_re_home_bin" in
        "$sh_re_bin") sh_re_home_bin=$sh_re_bin ;;
        *) sh_re_home_bin="$sh_re_root$sh_re_home_bin" ;;
    esac
    sh_re_ld=$(tc_rust_lib_dirs)
    if [ "${SH_HOME_EXEC:-unknown}" != yes ]; then
        # On a split root the view's rustc becomes the --sysroot wrapper: the
        # sysroot it names is the view, so every binary rustc execve's at link
        # time lives on a mount that runs it.
        for sh_re_w in rustc rustdoc clippy-driver; do
            [ -f "$sh_re_bin/$sh_re_w" ] || continue
            case "$sh_re_w" in
                rustc) sh_re_hw="$sh_re_home_bin/rustc" ;;
                rustdoc) sh_re_hw="$sh_re_home_bin/rustdoc" ;;
                *) sh_re_hw="$sh_re_home_bin/clippy-driver" ;;
            esac
            tc_rust_sysroot_wrapper "$sh_re_bin/$sh_re_w" "$sh_re_hw" \
                "$sh_re_sysroot" "$sh_re_ld" || \
                sh_warn "could not wrap $sh_re_w with --sysroot"
        done
        # Targets added after the promote are made visible without one (issue
        # #115). Runs after the wrappers so the view's rustc is already the
        # --sysroot wrapper; linking a target directory does not touch it.
        tc_rust_link_data_targets "$sh_re_view" "$sh_re_root" || true
    fi
    sh_env_write_fragment rust <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
RUSTUP_HOME="$sh_re_root/rustup"
CARGO_HOME="$sh_re_root/cargo"
CARGO_INSTALL_ROOT="\$SANDHOME_EXEC/cargo-install"
export RUSTUP_HOME CARGO_HOME CARGO_INSTALL_ROOT
# Listed least-wanted first: every block prepends, so the LAST block wins.
# The home cargo dir is the fallback (it cannot execve on a split root);
# the view toolchain bin wins outright.
case ":\$PATH:" in
  *":$sh_re_root/cargo/bin:"*) ;;
  *) PATH="$sh_re_root/cargo/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":\$SANDHOME_EXEC/cargo-install/bin:"*) ;;
  *) PATH="\$SANDHOME_EXEC/cargo-install/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":$sh_re_view/cargo/bin:"*) ;;
  *) PATH="$sh_re_view/cargo/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":$sh_re_bin:"*) ;;
  *) PATH="$sh_re_bin:\$PATH" ;;
esac
# # STOP: THE WRAPPER DIRECTORY IS MOVED TO THE FRONT, NOT MERELY ADDED. The
# prepend below used to be guarded on the directory not already being on PATH,
# the same guard as every other directory here. That is the wrong question for
# this one: the wrapper has to WIN over the toolchain's own cargo, and the
# toolchain bins are prepended above, so any shell that already carries
# $SH_EXEC/cargo-wrap skipped the prepend entirely, the toolchain bin became
# first, and cargo resolved to the real binary with the wrapper never
# executed. The global hook is what puts that directory on PATH: install and
# repair call sh_env_load before sh_global_install, so the hook was written
# INTO it and the very next session disabled the wrapper. Measured on an
# exec-capable root, two real same-basename crates from a hook-only login
# shell:
#   cargo-wrap NOT on PATH:      PROJECT-A, PROJECT-B   (two target dirs)
#   cargo-wrap already on PATH:  PROJECT-A, PROJECT-A   (one target dir)
# So the directory is REMOVED wherever it sits and prepended once, which makes
# the outcome a function of this file and not of the shell the fragment is
# read by. The walk runs in both cases, so the same code path both adds the
# directory when it is absent and lifts it above the toolchain bin when it is
# not, and one rule cannot be right while the other is wrong. Removing and
# re-prepending is idempotent, so a nested source or a second fragment read
# cannot leave two copies in PATH (issue #176, #184).
#
# THE WALK USES THE SAME ABSOLUTE PATH AS THE GUARD ABOVE, NOT $SH_EXEC. A
# first version guarded on the literal path and then walked on \$SH_EXEC, so a
# shell that sourced this fragment without that variable - which is exactly the
# shell ROUTE step 4 describes, an env -i with no environment at all - compared
# every entry against the empty string, kept them all, and prepended
# "/cargo-wrap" in front of the whole original PATH. A guard and the operation
# it guards have to be about the same string; when they are about different
# ones the second is a no-op with a side effect. The path is baked, so the
# fragment needs no variable to be correct.
case ":\$PATH:" in
  *":$SH_EXEC/cargo-wrap:"*) _sh_cw_fix=remove ;;
  *) _sh_cw_fix=prepend ;;
esac
if [ -n "\${_sh_cw_fix:-}" ]; then
  _sh_cw_new=
  _sh_cw_rest=\$PATH
  while [ -n "\$_sh_cw_rest" ]; do
    case "\$_sh_cw_rest" in
      *:*) _sh_cw_e=\${_sh_cw_rest%%:*}; _sh_cw_rest=\${_sh_cw_rest#*:} ;;
      *)   _sh_cw_e=\$_sh_cw_rest; _sh_cw_rest='' ;;
    esac
    [ "\$_sh_cw_e" = "$SH_EXEC/cargo-wrap" ] || _sh_cw_new="\$_sh_cw_new:\$_sh_cw_e"
  done
  PATH="$SH_EXEC/cargo-wrap\${_sh_cw_new}"
  unset _sh_cw_fix _sh_cw_new _sh_cw_rest _sh_cw_e
fi
export PATH
$(sh_rust_target_resolver)
EOF
    tc_rust_ld_fragment "$(sh_env_fragment rust)" "$sh_re_ld"
    if [ "${SH_HOME_EXEC:-unknown}" != yes ]; then
        # The wrapper above names this sysroot on its command line; RUSTC and
        # RUSTDOC name the wrappers so cargo never resolves the home paths,
        # which cannot execve here. Measured: without RUSTC, cargo drives the
        # toolchain's own bin/rustc and the link dies with
        #   collect2: fatal error: posix_spawnp: Permission denied
        # (issue #52).
        cat >> "$(sh_env_fragment rust)" <<EOF
export RUSTC="$sh_re_bin/rustc"
export RUSTDOC="$sh_re_bin/rustdoc"
EOF
    fi
    # # STOP: ADDING A TARGET IS NECESSARY BUT NOT ALWAYS SUFFICIENT. For most
    # cross targets a zig wrapper below is enough, because zig cc is the linker.
    # `wasm32-unknown-emscripten` is the exception: its linker is `emcc`, a
    # separate toolchain with its own LLVM/Binaryen and its own EM_CONFIG, so
    # `rustup target add` completes and `cargo build --target
    # wasm32-unknown-emscripten` then dies with `linker 'emcc' not found`
    # (issue #163). No wrapper here can supply it, and the error reads like a
    # broken PATH, so the fix is a real toolchain plus
    # CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=emcc, not a flag on this
    # one. The rust target list is therefore not a promise that the link works:
    # `sandhome doctor` prints `emscripten_linker` when a recorded target needs
    # emcc and there is none.
    # Zig cross wrappers, one per requested target, placed on the exec view.
    if sh_have zig 2>/dev/null || [ -x "$SH_EXEC_BIN/zig" ]; then
        for sh_re_t in $(sh_split_on ',' "${SH_RUST_TARGETS:-}"); do
            [ -n "$sh_re_t" ] || continue
            # STOP: EMSCRIPTEN IS NOT A ZIG TARGET, SO IT GETS NO ZIG WRAPPER
            # (issue #170). The paragraph above already says emcc is this
            # target's linker and that the fix is the variable, but the loop
            # wrote a wrapper for EVERY requested target and exported the
            # variable unconditionally, so the comment and the code disagreed.
            # Because env.d/rust.sh loads after env.d/emscripten.sh, the zig
            # wrapper won, and rustc handed emcc's -s settings to clang (zig
            # cc), which does not know them:
            #   error: linking with `.../rust-link-wasm32-unknown-emscripten` failed
            #   = note: error: Unknown Clang option: '-sABORTING_MALLOC=0'
            # Forcing the linker back proves the rest of the path is sound:
            #   CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=emcc cargo build --target wasm32-unknown-emscripten
            #     Finished dev profile, and node runs the output.
            # So the exclusion is by target name, and it covers wasm64 as well
            # as wasm32 because both are emscripten's linker and neither is
            # clang's. Leaving the emscripten fragment's emcc in place is the
            # fix; there is no wrapper here that could replace it.
            case "$sh_re_t" in
                *emscripten*) continue ;;
            esac
            sh_re_wrap="$SH_EXEC_BIN/rust-link-$sh_re_t"
            # # STOP: THE WRAPPER REWRITES THE TRIPLE AND DROPS RUSTC'S OWN
            # LINKER FLAGS. The previous one-line wrapper was
            #   exec zig cc -target $sh_re_t "$@"
            # and it failed on 6 of the 7 targets I tried, for four separate
            # reasons (issue #51):
            #   1. rustup spells <arch>-<vendor>-unknown-<os>; zig wants
            #      <arch>-<os>, so aarch64-unknown-linux-gnu is UnknownOperatingSystem
            #   2. 32-bit arch names are zig's to choose: x86 not i686, arm not
            #      armv7/thumb (zig 0.13 `zig targets` lists x86, x86_64, arm,
            #      armeb, thumb, thumbeb)
            #   3. rustc injects -m64, -B<sysroot>, -fuse-ld=lld and per-target
            #      -Wl, tuning flags such as --fix-cortex-a53-843419, which zig
            #      rejects ("unsupported linker arg")
            #   4. for a musl target rustc passes its own self-contained crt
            #      objects AND -nostartfiles while zig links its own musl, so
            #      _start and _init are defined twice
            #   5. rustc names its linker dialect first (`-flavor wasm` +
            #      value, or `-flavor=...` joined): zig cc is clang, and an
            #      lld `-flavor` is an "Unknown Clang option", so the pair
            #      goes together -- dropping the flag but keeping its value
            #      would hand zig a stray `wasm` to link. Measured on a
            #      wasm32-unknown-unknown build that died naming -flavor.
            #   6. `wasm32-unknown-unknown` is freestanding to zig: the generic
            #      `-unknown-` strip makes `wasm32-unknown`, which zig reads as
            #      an unknown OS. The wasm triples are rewritten first, before
            #      the generic strip runs. The wasm lld dialect (--export,
            #      -z, --no-entry and friends) is dropped in the wrapper
            #      itself, scoped to wasm triples so ELF keeps its flags.
            # The -B<sysroot> drop matters twice over: it is the flag that put
            # the noexec sysroot back on a link that otherwise would have worked.
            cat > "$sh_re_wrap" 2>/dev/null <<WRAP || continue
#!/bin/sh
# written by sandhome: rustc passes no target triple to its linker (argv[1] is
# -m64 on x86_64), so the target is baked in here and every host-shaped flag
# rustc adds is dropped in favour of zig's linker and libc.
triple=\$(printf '%s' '$sh_re_t' | sed \\
  -e 's/^wasm32-unknown-unknown$/wasm32-freestanding/' \\
  -e 's/^wasm64-unknown-unknown$/wasm64-freestanding/' \\
  -e 's/-unknown-/-/' \\
  -e 's/^i[3-6]86-/x86-/' \\
  -e 's/^armv7[a-z0-9]*-/arm-/' \\
  -e 's/^thumb[a-z0-9]*-/arm-/')
case "\$1" in -m64|-m32) shift ;; esac
# wasm32/wasm64 speak an lld dialect zig cc does not take: --export and -z
# carry a value each, the rest are bare. Dropping them lets zig link wasm
# its own way; keeping any one of them aborts the link on the first
# unknown option (measured: -flavor, then --export). Scoped to wasm so ELF
# targets keep their -z hardening flags.
case "\$triple" in wasm32-*|wasm64-*) wasm_lld=1 ;; *) wasm_lld=0 ;; esac
args=""
skip=0
pend=""
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  # A --export value arrives as the NEXT argument: it is rewritten onto the
  # one -Wl, form, not dropped, because the guest's entry point is the
  # export (measured: -Wl,--export,main links; dropping it links a module
  # with nothing to call).
  if [ -n "\$pend" ]; then
    args="\$args -Wl,--export,\$a"
    pend=""
    continue
  fi
  case "\$a" in
    -B*|-fuse-ld=*|-nodefaultlibs|-m64|-m32) continue ;;
    -Wl,--fix-cortex*|--fix-cortex*) continue ;;
    -nostartfiles) continue ;;
    -flavor) skip=1; continue ;;
    -flavor=*) continue ;;
    *self-contained/crt*.o|*self-contained/rcrt*.o) continue ;;
  esac
  if [ "\$wasm_lld" = 1 ]; then
    # NOTE: REWRITE, NOT DROP, FOR WHAT wasm-ld NEEDS. zig cc rejects the
    # bare lld spellings but forwards -Wl, forms (measured one by one):
    # --no-entry becomes -Wl,--no-entry, --export X becomes
    # -Wl,--export,X. Bare -z forwards untouched and is kept. Only what zig
    # names unknown AND carries nothing (--stack-first, --no-demangle,
    # --gc-sections: cosmetics and size) is dropped.
    case "\$a" in
      --export) pend=1; continue ;;
      --export=*) args="\$args -Wl,\$a"; continue ;;
      --no-entry) args="\$args -Wl,--no-entry"; continue ;;
      --stack-first|--no-demangle|--gc-sections) continue ;;
    esac
  fi
  args="\$args \$a"
done
exec zig cc -target "\$triple" \$args
WRAP
            chmod 0755 "$sh_re_wrap" 2>/dev/null || true
            sh_re_upper=$(sh_upper "$sh_re_t")
            # CARGO_TARGET_<TRIPLE>_LINKER with - and . as _
            sh_re_var=$(printf '%s' "$sh_re_upper" | {
                sh_re_o=''
                sh_re_r=$sh_re_upper
                while [ -n "$sh_re_r" ]; do
                    sh_re_c=${sh_re_r%"${sh_re_r#?}"}
                    sh_re_r=${sh_re_r#?}
                    case "$sh_re_c" in
                        -|.) sh_re_o="${sh_re_o}_" ;;
                        *) sh_re_o="${sh_re_o}$sh_re_c" ;;
                    esac
                done
                printf '%s' "$sh_re_o"
            })
            cat >> "$(sh_env_fragment rust)" <<EOF
CARGO_TARGET_${sh_re_var}_LINKER="$sh_re_wrap"
export CARGO_TARGET_${sh_re_var}_LINKER
EOF
        done
    fi
    # # STOP: NO BEHAVIOURAL CHECK HERE. It would run before sh_env_load, so the
    # shell still resolves `rustc` through the PATH it had before the wrapper
    # existed and the check reports a healthy install as broken:
    #   [!] rustc installed without an error and still does not link
    # on a toolchain that compiles two lines later in a fresh shell. The
    # framework owns the last word: it calls sh_env_load and only then runs
    # tc_rust_probe, which does the same compile with the fragment in effect.
    return 0
}

tc_rust_version() {
    sh_have rustc && sh_first_line rustc --version 2>/dev/null
}

# tc_rust_adopted -> directory of the answering rustc when adopted.
tc_rust_adopted() {
    # sh_path_where, not command -v: the exec view is on PATH by the time an
    # install runs, so command -v answers with the view this tool is being
    # linked INTO and the promote step then links the view onto itself (issue
    # #43). The exec view is not a working copy and is not consulted.
    sh_ra_which=$(sh_path_where rustc)
    [ -n "$sh_ra_which" ] || return 0
    sh_ra_dir=${sh_ra_which%/*}
    [ -n "$sh_ra_dir" ] || sh_ra_dir=.
    ( CDPATH='' cd -- "$sh_ra_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_ra_dir"
}
