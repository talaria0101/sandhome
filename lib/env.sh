#!/bin/sh
# env.sh - the environment sandhome owns, and the one file that states it.
# Sourced by bootstrap.sh and by bin/sandhome.
#
# NOTE: ONE FACT HAS ONE HOME. The values are written to $SH_HOME/env.sh and every
# caller sources that file; `sandhome env` prints the same bytes so a caller may
# `eval "$(sandhome env)"` in a shell that never ran the bootstrap. A second copy
# of the PATH line is the copy that goes stale.

# sh_path_prepend DIR -> put DIR at the front of PATH unless it is already
# anywhere in it. An empty element (which means the current directory) is left
# alone here; the profile fragment is what removes those.
sh_path_prepend() {
    sh_pp_dir=$1
    case ":$PATH:" in
        *":$sh_pp_dir:"*) ;;
        *) PATH="$sh_pp_dir:$PATH" ;;
    esac
    export PATH
}

# sh_env_fragment NAME -> the path of a toolchain's env fragment, creating the
# directory. Each toolchain writes its own; env.sh sources them all.
sh_env_fragment() {
    mkdir -p "$SH_HOME/env.d" 2>/dev/null || true
    printf '%s/env.d/%s.sh' "$SH_HOME" "$1"
}

# sh_env_write_fragment NAME <<EOF ... EOF -> write the fragment atomically.
sh_env_write_fragment() {
    sh_ewf_name=$1
    sh_ewf_file=$(sh_env_fragment "$sh_ewf_name")
    sh_ewf_tmp="$sh_ewf_file.tmp.$$"
    cat > "$sh_ewf_tmp" || return 1
    mv "$sh_ewf_tmp" "$sh_ewf_file" || return 1
    # # STOP: WRITING A FRAGMENT SAYS WHETHER THE ROOT IT POINTS AT HAS ROOM.
    # Every toolchain fragment names an exec-root path - GOCACHE, GOBIN,
    # CARGO_TARGET_DIR, NPM_CONFIG_PREFIX - and the next build fills that root.
    # The install is the last moment the operator is still choosing roots, so the
    # space is measured here and said out loud, while a choice can still be
    # made. Without it the only warning about a 36MB root arrives from a build
    # that has already failed, and sometimes with exit 0.
    if command -v sh_space_status >/dev/null 2>&1; then
        sh_space_advise "${SH_EXEC:-/tmp}"
    fi
    return 0
}

# sh_env_body -> print the env file's contents. It is printed rather than
# written by sh_env_write so `sandhome env` and the file cannot drift.
sh_env_body() {
    printf '# sandhome environment. Generated; edit by hand and it is regenerated.\n'
    printf 'SANDHOME_HOME=%s\n' "$(sh_sq_quote "$SH_HOME")"
    printf 'SANDHOME_EXEC=%s\n' "$(sh_sq_quote "$SH_EXEC")"
    printf 'export SANDHOME_HOME SANDHOME_EXEC\n'
    printf 'case ":$PATH:" in\n'
    printf '  *":$SANDHOME_EXEC/bin:"*) ;;\n'
    printf '  *) PATH="$SANDHOME_EXEC/bin:$PATH" ;;\n'
    printf 'esac\n'
    # # STOP: A DIRECTORY THIS TREE PUTS ON PATH IS MARKED, AND A MARKED
    # DIRECTORY CANNOT HOST THE GLOBAL HOOK (issues #184, #185). The hook is
    # what serves a shell that sourced nothing, so a hook directory is only
    # useful to a shell that ALREADY has it on PATH. A directory that only
    # appears on PATH after env.sh is read cannot do that job, and taking one
    # is worse than useless: the global hook installer reads this shell's PATH
    # after calling sh_env_load, so a directory a fragment has just prepended
    # looks like the best writable candidate on the machine and the hook is
    # written into it. It then serves nobody, because the next session does
    # not have it on PATH.
    #
    # That is measured, not hypothetical. PR #180 added $SANDHOME_EXEC/cargo-wrap
    # and the rust fragment prepends it; on the next run the hook was installed
    # into it ("global=on:/workspace/sandexec/cargo-wrap"), every tool the hook
    # advertises there became invisible to the next fresh shell, and the
    # fragment's own "already on PATH" guard then stopped prepending, so the
    # real cargo shadowed the wrapper and two same-basename crates shared one
    # target dir again.
    #
    # A MARKER FILE PER DIRECTORY rather than another name in this list,
    # because the list is exactly what went wrong: a directory created after
    # the list was written was taken by mistake. Each directory this tree puts
    # on PATH is marked inside itself, where the prepend that puts it there is
    # written, and this function reads the mark off the directory. A directory
    # this tree invents tomorrow is refused without anybody remembering to
    # add it, and a neutral directory under the exec root that this tree did
    # not create is still a candidate. The installer reads it from disk rather
    # than from a list, which is the same rule sh_global_hook_names already
    # follows for the same reason (issue #138): both change without this tree
    # running.
    #
    # Measured: PR #180 added $SANDHOME_EXEC/cargo-wrap, the rust fragment
    # prepends it, and the hook was installed into it on the next run
    # ("global=on:/workspace/sandexec/cargo-wrap"). Every tool the hook
    # advertises there then became invisible to the next fresh shell, and the
    # fragment's own "already on PATH" guard stopped prepending, so the real
    # cargo shadowed the wrapper. (Issues #184, #185.)
    printf 'if [ -d "$SANDHOME_EXEC" ] && [ ! -e "$SANDHOME_EXEC/bin/.sandhome-on-path" ]; then\n'
    printf '  if ( umask 022; : > "$SANDHOME_EXEC/bin/.sandhome-on-path" ) 2>/dev/null; then :; else\n'
    printf '    printf "%%s\\n" "$SANDHOME_EXEC/bin" >> "$SANDHOME_HOME/on-path.dirs" 2>/dev/null || true\n'
    printf '  fi\n'
    printf 'fi\n'
    # # NOTE: THE CHECKOUT'S bin IS NOT ON PATH, AND ITS COPY IS. `sandhome` is the
    # command every other line in every document tells a caller to run, and it
    # lives in the checkout - which is frequently on a root that refuses
    # execve, the very condition this tree exists for. A PATH entry pointing
    # there gives a command that answers `command -v` and then fails:
    #   measured, on a checkout under /workspace:
    #     $ sandhome version
    #     sh: sandhome: Permission denied
    # The bootstrap therefore COPIES `bin/sandhome` onto `$SANDHOME_EXEC/bin`,
    # which is already on PATH, and exports the checkout here so the copy can
    # find its library. Nothing is copied at shell start: a login file that
    # rewrites a file on every login is a login file that fails one day.
    printf 'export SANDHOME_REPO_DIR=${SANDHOME_REPO_DIR:-%s}\n' "$(sh_sq_quote "${SH_REPO_DIR:-}")"
    # # STOP: THE REQUESTED TOOLCHAINS ARE RECORDED, SO `doctor` CAN CHECK THEM.
    # doctor is the readiness gate ROUTE.md step 2 tells a session to trust, and
    # it could only check the toolchains named in INSTALLED or ADOPTED - which
    # are empty in a fresh process, because they are this run's variables and
    # not the file's. So on a host where the toolset could not be installed,
    # `bootstrap.sh --toolset languages` reported
    #   installed=      adopted=jq ripgrep fd python go
    #   toolchain.zig= toolchain.mold= toolchain.deno= toolchain.rust=
    #   failures=6
    # and `sandhome doctor` then answered `doctor_failures=0` and exited 0,
    # over five toolchains the setup had just said it could not install
    # (issue #38). A readiness gate that cannot see what was asked for is not a
    # readiness gate. The list is written once, as a space-separated value, and
    # doctor reads it the same way it reads every other fact in this file.
    # STOP: THE WANTED LIST IS MERGED, NOT REPLACED (issue #57). It was written
    # by the bootstrap and erased by any later write, because install and repair
    # wrote env.sh without holding the value: one routine command silently
    # disarmed the doctor readiness gate. When this process holds no list, the
    # one already in the file wins, so a repair or a failed install preserves
    # it; install merges the names it was asked for (see cmd_install).
    #
    # A caller that REPLACES the request instead of adding to it sets
    # SH_WANTED_REPLACE=1 (--only on install, and every bootstrap run, which
    # restates the request in full): then the file's list is not pulled back
    # in, so `install --only jq` can shrink the gate from `jq node` to `jq`,
    # and `install --without X` that empties the list really empties it. An
    # empty replaced list writes no line at all, and no line reads as an empty
    # list to the doctor gate.
    if [ "${SH_WANTED_REPLACE:-0}" != 1 ] && [ -z "${SH_WANTED_TOOLCHAINS:-}" ]; then
        SH_WANTED_TOOLCHAINS=$(sh_wanted_from_file)
    fi
    if [ -n "${SH_WANTED_TOOLCHAINS:-}" ]; then
        printf 'SANDHOME_WANTED_TOOLCHAINS=%s\n' "$(sh_sq_quote "$(sh_trim "$SH_WANTED_TOOLCHAINS")")"
        printf 'export SANDHOME_WANTED_TOOLCHAINS\n'
    fi
    # # STOP: A REQUESTED CROSS TARGET IS RECORDED, SO A LATER ROUTINE WRITE
    # DOES NOT DROP IT. `--target`/SANDHOME_RUST_TARGETS lived only in the
    # installing process; a later `install python` started a fresh request and
    # rewrote env.sh without it, and `resume` had no record either, so the
    # target silently vanished and doctor could not name the link that then
    # needs a toolchain which is not there (issue #163, the same class as
    # #153). Seeded from the file when this process holds nothing, exactly as
    # the wanted list is.
    if [ -z "${SH_RUST_TARGETS:-}" ]; then
        SH_RUST_TARGETS=$(sh_rust_targets_from_file)
    fi
    if [ -n "${SH_RUST_TARGETS:-}" ]; then
        printf 'SANDHOME_RUST_TARGETS=%s\n' "$(sh_sq_quote "$(sh_trim "$SH_RUST_TARGETS")")"
        printf 'export SANDHOME_RUST_TARGETS\n'
    fi
    # # STOP: AN EXPLICIT VIEW MODE IS PERSISTED, SO `resume` HONOURS IT. The
    # mode lived only in the installing process, so `sandhome resume`, which
    # rebuilds every view after a tmpfs wipe, silently reverted the trees to
    # launch (issue #113). Written as a guarded assignment so an operator can
    # still override it for one command, and only when it was explicitly set:
    # an absent variable leaves the file alone rather than pinning the
    # machine decision to whatever this run happened to compute.
    case "${SANDHOME_VIEW_MODE:-}" in
        ''|auto) ;;
        *)
            printf 'if [ -z "${SANDHOME_VIEW_MODE:-}" ]; then\n'
            printf '  SANDHOME_VIEW_MODE=%s\n' "$(sh_sq_quote "$SANDHOME_VIEW_MODE")"
            printf '  export SANDHOME_VIEW_MODE\n'
            printf 'fi\n' ;;
    esac
    printf 'export PATH\n'
    # # STOP: THE PROXY CONFIGURATION THE INSTALLING SHELL HAD IS A PROPERTY
    # OF THIS MACHINE, SO IT IS WRITTEN DOWN AND RE-APPLIED (issue #181).
    #
    # A sandbox that reaches the network only through a proxy named in the
    # environment loses the network the moment the environment is scrubbed, and
    # every form this project documents scrubs it: `env -i
    # $SANDHOME_EXEC/bin/sandhome doctor`, `sh -c 'eval "$(sandhome env)"'`, a
    # shell with no PATH at all sourcing entry.sh, and above all the global
    # hook, which exists precisely to serve a shell that sourced nothing. The
    # hook loads env.sh for the process it runs, so a tool invoked by name in a
    # fresh shell got the whole environment except the one thing that made the
    # network reachable.
    #
    # Measured on a host whose only egress is http://169.254.169.1:40295 with
    # direct UDP to its resolvers refused, from a fresh hook-only shell:
    #   curl  https://nodejs.org/dist/index.json        -> 000
    #   npm   install left-pad   -> getaddrinfo EAI_AGAIN registry.npmjs.org
    #   pip   install requests  -> "from versions: none"
    #   go    install .../@latest -> "operation not permitted" on the resolver
    # The same four commands with the variables carried through all succeed,
    # which is what isolates the scrub as the cause rather than the registries.
    # Worse, the setup run the same way reported "this sandbox has no working
    # resolver" and sent the reader to SANDHOME_DOH_URL, which cannot help on
    # a host whose refusal is a policy on direct UDP.
    #
    # Both halves of curl's rule are recorded, because a client reads either:
    # the lowercase names for curl and git, the uppercase names for wget and
    # everything written against them. Each is written as a guarded assignment,
    # so a shell that already has one keeps its own, exactly like
    # XDG_RUNTIME_DIR above.
    for sh_ep_v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY all_proxy ALL_PROXY; do
        eval "sh_ep_val=\${$sh_ep_v:-}"
        [ -n "$sh_ep_val" ] || continue
        printf 'if [ -z "${%s:-}" ]; then\n' "$sh_ep_v"
        printf '  %s=%s\n' "$sh_ep_v" "$(sh_sq_quote "$sh_ep_val")"
        printf '  export %s\n' "$sh_ep_v"
        printf 'fi\n'
    done
    unset sh_ep_v sh_ep_val
    # # STOP: A MISSING HOME IS NOT A REASON FOR THE TOOLCHAIN TO DIE
    # (issue #179). `env -i $SANDHOME_EXEC/bin/sandhome doctor` is documented
    # to work with no HOME, and it did not: npm's JS dies with
    # `uv_os_homedir returned ENOENT` and Deno refuses to resolve its global
    # cache, so two module doctor hooks reported healthy toolchains as broken.
    # A scratch home on the exec root is writable and runs, and HOME being
    # unset means there is no real one to shadow, so this yields to any HOME
    # the caller has.
    printf 'if [ -z "${HOME:-}" ]; then\n'
    printf '  HOME="$SANDHOME_EXEC/home"\n'
    printf '  export HOME\n'
    printf 'fi\n'
    printf 'if [ -n "${HOME:-}" ]; then mkdir -p "$HOME" 2>/dev/null || true; fi\n'
    # XDG_RUNTIME_DIR first: every headless GL/EGL/Wayland/pipewire tool
    # errors when it is unset, and the setup knows exactly where writable
    # scratch is (issue #95). Set only when no valid one exists, so an
    # operator's real runtime is never shadowed; ensured with 0700, which
    # the spec requires and several toolkits enforce.
    printf 'if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ]; then\n'
    printf '  XDG_RUNTIME_DIR="$SANDHOME_EXEC/xdg-runtime"\n'
    printf '  export XDG_RUNTIME_DIR\n'
    printf 'fi\n'
    printf 'if [ -n "${XDG_RUNTIME_DIR:-}" ]; then\n'
    printf '  mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null && chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true\n'
    printf 'fi\n'
    # # NOTE: TMPDIR MUST RUN A FILE. A temp file some tools write and then run
    # - a compiler's assembler stage, python's multiprocessing, a build that
    # re-execs itself - fails on a noexec mount exactly like any other binary,
    # and the sandbox that needs sandhome is the one whose home (and often
    # /tmp) is noexec. `sh_env_write` probes the ambient TMPDIR once and bakes
    # the decision: when it does not run a file, every shell points TMPDIR at
    # the exec root; when it does, an operator's own TMPDIR is kept and only an
    # unset one defaults to the exec root. This is what lets a consumer run
    # `python3 script.py` with no `TMPDIR=` and no `. env.sh` in front of it.
    if [ "${SH_ENV_TMPDIR_FORCE:-no}" = yes ]; then
        printf 'TMPDIR="$SANDHOME_EXEC/tmp"\n'
        printf 'export TMPDIR\n'
    else
        printf 'if [ -z "${TMPDIR:-}" ]; then\n'
        printf '  TMPDIR="$SANDHOME_EXEC/tmp"\n'
        printf '  export TMPDIR\n'
        printf 'fi\n'
    fi
    printf 'if [ -n "${TMPDIR:-}" ]; then mkdir -p "$TMPDIR" 2>/dev/null || true; fi\n'
    # # STOP: THE STANDARD CACHE ROOT IS AN EXECUTABLE ROOT FOR MANY TOOLS.
    # TMPDIR and XDG_RUNTIME_DIR were already moved onto the exec root, and
    # the browser caches were named one at a time (#143), but every other tool
    # that follows the XDG spec still defaulted to $HOME/.cache on the mount
    # that refuses execve. An executable a tool downloads there - worker-build's
    # emsdk node/emcc/binaryen and wasm-bindgen CLI, a uv-managed wheel's
    # console script, an AppImage unpack - writes fine and then cannot run
    # (issue #158). One guarded default covers the class. The directory is made
    # here so the first tool that wants it has a target, matching TMPDIR.
    printf 'if [ -z "${XDG_CACHE_HOME:-}" ]; then\n'
    printf '  XDG_CACHE_HOME="$SANDHOME_EXEC/cache"\n'
    printf '  export XDG_CACHE_HOME\n'
    printf 'fi\n'
    printf 'if [ -n "${XDG_CACHE_HOME:-}" ]; then mkdir -p "$XDG_CACHE_HOME" 2>/dev/null || true; fi\n'
    # # STOP: A THIRD-PARTY INSTALLER DOES NOT GO THROUGH sh_tar, SO THE TREE
    # FIXES ITS tar CALL BY ENVIRONMENT, NOT BY PATCHING IT. lib/fetch.sh already
    # unpacks as itself (sh_tar tries --no-same-owner first), because running as
    # uid 0 makes tar restore the archive uid/gid and a sandbox root without
    # CAP_CHOWN refuses that chown: every entry warns "Cannot change ownership"
    # and tar exits 2 after a good download. emsdk is the measured case
    # (issue #162): its single `tar -xf` carries uid 1000 and aborts with
    # "installation failed". GNU tar reads TAR_OPTIONS before argv, so one
    # guarded default repairs every installer that shells out to tar without
    # touching any of them. A caller who set TAR_OPTIONS keeps it; the append
    # arm covers a caller who set other tar flags without this one. Non-GNU
    # tar ignores the variable, which is why sh_tar stays the unpack path for
    # the tree's own fetches: two mechanisms, same invariant, neither assumes
    # the other.
    printf 'case "${TAR_OPTIONS:-}" in\n'
    printf '  *no-same-owner*) ;;\n'
    printf '  "") TAR_OPTIONS="--no-same-owner"; export TAR_OPTIONS ;;\n'
    printf '  *) TAR_OPTIONS="$TAR_OPTIONS --no-same-owner"; export TAR_OPTIONS ;;\n'
    printf 'esac\n'
    # # STOP: THE NAIVE `cargo build && ./target/debug/x` MUST LAND WHERE IT
    # CAN RUN. GOBIN, GOCACHE, CARGO_INSTALL_ROOT and NPM_CONFIG_PREFIX already
    # point at the exec root, but CARGO_TARGET_DIR does not, so the default
    # `cargo build` on a noexec work tree links fine and then dies with
    # Permission denied running ./target/debug/x (issue #156). One guarded
    # default closes the class: a caller who set CARGO_TARGET_DIR keeps it,
    # otherwise each project gets its own dir under the exec root named for the
    # work tree, so two checkouts do not share one target dir. The dir is made
    # here so the first build has a target, matching TMPDIR.
    # # STOP: THE ID MUST BE THE PROJECT'S, AND THE PROJECT IS CARGO'S NOT THE
    # SHELL'S. Two keys were wrong here and each was measured.
    #
    # The basename is wrong: `${PWD##*/}` gives `dup` for both /w/a/dup and
    # /w/b/dup, cargo treats one target dir as one project's, and the second
    # crate's build is "fresh" so the stale binary runs. Reproduced live here on
    # main with two real crates in sibling `dup` directories:
    #   A in /workspace/consume/a/dup -> CARGO_TARGET_DIR=.../target-consume, prints PROJECT-A
    #   B in /workspace/consume/b/dup -> CARGO_TARGET_DIR=.../target-consume, prints PROJECT-A
    # (issue #167).
    #
    # The absolute PATH is also wrong, and fixing only that is what a first cut
    # did: cargo resolves a project by walking UP to the nearest Cargo.toml, so
    # building the same crate from `proj/` and from `proj/src/` is one build.
    # Keyed on $PWD those are two target dirs, which means a full rebuild every
    # time you cd, and a target directory per subdirectory you ever built from.
    # Measured on that first cut:
    #   /workspace/consume/a/dup     -> target-dup-2176453656
    #   /workspace/consume/a/dup/src -> target-src-3462659862   <- same crate, two dirs
    # cargo's own answer is the authority and it agrees with the walk:
    #   $ cargo locate-project --workspace     {"root":"/workspace/consume/a/dup/Cargo.toml"}
    #
    # So the id is the nearest Cargo.toml ANCESTOR, which is unique per project
    # and stable across its subdirectories. A path with no manifest anywhere above
    # it falls back to $PWD, which is the honest answer there: nothing has claimed
    # the directory yet.
    #
    # The readable name is kept in front of a digest of the absolute path, so a
    # human can still see which project a target dir belongs to. `cksum` is POSIX
    # and leads; without it a pure-shell encoding walks the path byte by byte and
    # escapes the two characters that would otherwise collide (`/` and `%`), which
    # is injective and needs no tool at all.
    # STOP: THE REDIRECT IS A STARTUP DEFAULT, NOT THE FINAL ANSWER (issue
    # #190). On an exec-capable work tree a target dir under the exec root moved
    # every `target/` out of the project, so the path cargo documents -
    # `cargo build` then `./target/debug/<bin>` - was ENOENT. env.sh cannot
    # decide this without RUNNING a file in the current directory, and a shell
    # startup that writes a probe into whatever directory the user happens to be
    # in is a worse side effect than the one it fixes (a file watcher, or a
    # read-only checkout, would see it). The per-invocation cargo wrapper
    # therefore makes the call at the moment cargo is run: it probes exec in the
    # project directory and drops this default there when the project can run a
    # file, leaving the project-local target/ in place. A caller who set
    # CARGO_TARGET_DIR is untouched, and the wrapper still re-derives for the
    # project it runs in when this default is stale (#176).
    printf 'if [ -z "${CARGO_TARGET_DIR:-}" ]; then\n'
    printf '  _sh_ctd_p=$PWD\n'
    printf '  _sh_ctd_d=$_sh_ctd_p\n'
    printf '  while [ -n "$_sh_ctd_d" ] && [ "$_sh_ctd_d" != / ] && [ ! -f "$_sh_ctd_d/Cargo.toml" ]; do\n'
    printf '    case "$_sh_ctd_d" in */*) _sh_ctd_d=${_sh_ctd_d%%/*} ;; *) _sh_ctd_d=/ ;; esac\n'
    printf '  done\n'
    printf '  if [ -f "$_sh_ctd_d/Cargo.toml" ]; then _sh_ctd_p=$_sh_ctd_d; fi\n'
    printf '  _sh_ctd_w=""\n'
    printf '  _sh_ctd_t=$_sh_ctd_p\n'
    printf '  while [ -n "$_sh_ctd_t" ] && [ "$_sh_ctd_t" != / ]; do\n'
    printf '    [ -f "$_sh_ctd_t/Cargo.toml" ] || { case "$_sh_ctd_t" in */*) _sh_ctd_t=${_sh_ctd_t%%/*} ;; *) _sh_ctd_t=/ ;; esac; continue; }\n'
    printf "    _sh_ctd_k=''\n"
    printf '    while IFS= read -r _sh_ctd_l 2>/dev/null; do\n'
    printf '      case "$_sh_ctd_l" in\n'
    printf "        '[workspace]'*) _sh_ctd_k=\$_sh_ctd_t; break ;;\n"
    printf '      esac\n'
    printf '    done < "$_sh_ctd_t/Cargo.toml"\n'
    printf '    if [ -n "$_sh_ctd_k" ]; then\n'
    printf '      _sh_ctd_w=$_sh_ctd_t; break\n'
    printf '    fi\n'
    printf '    case "$_sh_ctd_t" in */*) _sh_ctd_t=${_sh_ctd_t%%/*} ;; *) _sh_ctd_t=/ ;; esac\n'
    printf '  done\n'
    printf '  [ -n "$_sh_ctd_w" ] && _sh_ctd_p=$_sh_ctd_w\n'
    printf '  _sh_ctd=${_sh_ctd_p##*/}; [ -n "$_sh_ctd" ] || _sh_ctd=work\n'
    printf '  if command -v cksum >/dev/null 2>&1; then\n'
    printf '    _sh_ctd_s=$(printf "%%s" "$_sh_ctd_p" | cksum)\n'
    # STOP: THE DIGEST IS THE FIRST FIELD, AND `${v%% *}` IS HOW YOU TAKE IT.
    # cksum prints `<crc> <bytes>`, so the split has to be on the space BETWEEN
    # them. The first version wrote `${_sh_ctd%% *}` and looked right; the bug
    # was in the SECOND version, which used `${_sh_ctd% }` - `%` removes the
    # SHORTEST trailing match, and the space here is internal, so nothing was
    # removed and the id kept both fields with a space in it. Measured on this
    # tree, with two same-basename crates:
    #   $ printf '/workspace/proof/a/dup' | cksum   ->  3720797075 22
    #   ${s% }   ->  "3720797075 22"   <- unchanged, and it contains a space
    #   ${s%% *} ->  "3720797075"      <- the CRC, which is what separates them
    # The id with a space in it is then word-split by every later use, so BOTH
    # crates resolved to the same directory again and `cargo run` in the second
    # printed the first crate's binary - the exact defect this was written to
    # fix, still present after the fix. The clause in
    # tests/regressions-167-174.sh builds a real two-crate tree and runs it, and
    # it is the only thing that caught this: every clause that only inspected
    # the string passed.
    # STOP: THIS IS A printf FORMAT, SO EVERY PERCENT IS DOUBLED TWICE. The
    # generated text has to contain the shell's `${v%% *}`, and `sh_env_body`
    # emits every line through printf, where `%%` means "one percent". So a
    # source of `%%` produces `%` in env.sh, and `% *` strips nothing because
    # the space is internal and `%` removes a TRAILING match:
    #   printf 'A%%%% *'  ->  A%% *      <- what the shell needs
    #   printf 'A%% *'    ->  A% *       <- what it used to emit
    # With `A% *` in env.sh the id keeps BOTH of cksum's fields joined by a
    # space, so the id contains a space, every later use word-splits it, and
    # two same-basename crates resolve to one target dir again:
    #   $ cksum   ->  3720797075 22
    #   ${v% }   ->  "3720797075 22"  (unchanged)
    #   ${v%% *} ->  "3720797075"
    # Measured live with the wrong form, on two real crates:
    #   A ctd=target-sandhome-443490593 -> PROJECT-A
    #   B ctd=target-sandhome-443490593 -> PROJECT-A
    # which is issue #167 unfixed. This is why the clause set has both a
    # string clause and a two-real-crates clause: the string clause could not
    # see this, because the string it compared was already correct.
    printf '    _sh_ctd="${_sh_ctd%%%% *}-${_sh_ctd_s%%%% *}"\n'
    printf '  else\n'
    printf '    _sh_ctd_o=$_sh_ctd; _sh_ctd_r=$_sh_ctd_p\n'
    printf '    while [ -n "$_sh_ctd_r" ]; do\n'
    printf '      _sh_ctd_c=${_sh_ctd_r%%%%"${_sh_ctd_r#?}"}\n'
    printf '      _sh_ctd_r=${_sh_ctd_r#?}\n'
    printf '      case "$_sh_ctd_c" in\n'
    printf '        /) _sh_ctd_o="${_sh_ctd_o}%%2f" ;;\n'
    printf '        %%) _sh_ctd_o="${_sh_ctd_o}%%25" ;;\n'
    printf '        *) _sh_ctd_o="${_sh_ctd_o}$_sh_ctd_c" ;;\n'
    printf '      esac\n'
    printf '    done\n'
    printf '    _sh_ctd=$_sh_ctd_o\n'
    printf '  fi\n'
    printf '  CARGO_TARGET_DIR="$SANDHOME_EXEC/target-${_sh_ctd}"\n'
    printf '  export CARGO_TARGET_DIR\n'
    # STOP: THE ENV.SH VALUE IS A DEFAULT, NOT A CALLER'S CHOICE (issue #176).
    # The cargo wrapper recomputes the project dir per invocation; it has to be
    # able to tell this value (derived from the $PWD at shell start, and stale
    # the moment the shell cds) from one an operator set on purpose. The marker
    # is the value env.sh wrote, so the wrapper overrides exactly that and
    # yields to anything else.
    printf '  SANDHOME_CARGO_TARGET_DEFAULT=$CARGO_TARGET_DIR\n'
    printf '  export SANDHOME_CARGO_TARGET_DEFAULT\n'
    printf '  unset _sh_ctd_p _sh_ctd_d _sh_ctd_s _sh_ctd_o _sh_ctd_r _sh_ctd_c _sh_ctd_w _sh_ctd_t _sh_ctd_k _sh_ctd_l\n'
    printf '  unset _sh_ctd\n'
    printf 'fi\n'
    printf 'if [ -n "${CARGO_TARGET_DIR:-}" ]; then mkdir -p "$CARGO_TARGET_DIR" 2>/dev/null || true; fi\n'
    # # STOP: LEAKSANITIZER NEEDS ptrace, AND THIS CAGE DENIES IT. An
    # `-fsanitize=address` build compiles and links, then loses every byte of
    # its own stdout and exits 1 at exit, because LSan stops threads with
    # ptrace and dies with `LeakSanitizer has encountered a fatal error ...
    # does not work under ptrace`. The programme's output is lost with it
    # (stdout is block-buffered and LSan calls _exit on its fatal path), so the
    # failure reads as "my binary produced nothing" (issue #144). The answer is
    # `detect_leaks=0`, measured on this tree and the shape dropssh's sanitizer
    # run settled on; ASan and UBSan keep working. Only written when the
    # measured ptrace answer says the leak checker cannot work, and written as
    # a guarded default so a caller who sets ASAN_OPTIONS keeps it.
    if [ -z "${SH_PTRACE:-}" ]; then
        SH_PTRACE=$(sh_ptrace_from_file)
    fi
    if [ -n "${SH_PTRACE:-}" ]; then
        printf 'SANDHOME_PTRACE=%s\n' "$(sh_sq_quote "$SH_PTRACE")"
        printf 'export SANDHOME_PTRACE\n'
    fi
    # # EVERY ANSWER THE PROBE CAN GIVE IS NAMED, BECAUSE `*` HIDES THE
    # MISSING ONE. The probe returns yes, no, partial (lib/detect.sh) or
    # `unknown` when there is neither python3 nor a C compiler to measure
    # with. Written as `''|yes) skip`, a host the probe never ran on silently
    # lost the workaround and #144 came back -- the same shape as the defect,
    # one level up. The workaround is the cheap side of the trade: it costs
    # leak detection, which cannot work without ptrace anyway, and its absence
    # costs the programme's entire stdout. So it is written for every answer
    # except a measured `yes`, and an unmeasured host is treated as needing
    # it. A caller who sets ASAN_OPTIONS or LSAN_OPTIONS keeps theirs; the
    # lines below are guarded defaults. SANDHOME_ASAN=off restores the
    # unmodified environment for a host where leak checking works.
    : "${SANDHOME_ASAN:=on}"
    case "$SANDHOME_ASAN:${SH_PTRACE:-}" in
        off:*) ;;
        *:yes) ;;
        *)
            printf 'ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"\n'
            printf 'LSAN_OPTIONS="${LSAN_OPTIONS:-detect_leaks=0}"\n'
            printf 'export ASAN_OPTIONS LSAN_OPTIONS\n' ;;
    esac
    printf 'if [ -d "$SANDHOME_HOME/env.d" ]; then\n'
    printf '  for _sh_env_f in "$SANDHOME_HOME"/env.d/*.sh; do\n'
    printf '    [ -r "$_sh_env_f" ] && . "$_sh_env_f"\n'
    printf '  done\n'
    printf '  unset _sh_env_f\n'
    printf 'fi\n'
    printf '# Toolchain data roots are readable on any mount; only the exec view\n'
    printf '# must be exec-capable, and that is what SANDHOME_EXEC is.\n'
    printf '#\n'
    printf '# Shims load ONLY when SANDHOME_SHIMS is set to something other than\n'
    printf '# 0. They are opt-in. fakepty reports the SESSION descriptors as a\n'
    printf '# terminal, which is what an interactive shell wants, and\n'
    printf '# SANDHOME_FAKEPTY_ID scopes that to them: a pipe a program opens later\n'
    printf '# is a new object and stays a pipe, so:\n'
    printf '#   SANDHOME_SHIMS=1; jq -n {ok:1} | cat   -> cat still reads JSON\n'
    printf '# Without the variable the interposer falls back to fds 0-2, which is\n'
    printf '# how the shim used to colourise a pipe. It is still opt-in because a\n'
    printf '# scoped session reports the operator channel as a terminal, which is a\n'
    printf '# real change for a script that reads it.\n'
    printf 'export SANDHOME_FAKEPTY=${SANDHOME_FAKEPTY:-%s}\n' "$(sh_sq_quote "$SH_HOME/shims/fakepty.so")"
    printf 'case "${SANDHOME_SHIMS:-}" in\n'
    printf '  ""|0|no|off|false) ;;\n'
    printf '  *)\n'
    printf '    if [ -d "$SANDHOME_HOME/shims" ]; then\n'
    printf '      if [ -r "$SANDHOME_HOME/shims/passwd" ]; then\n'
    printf '        SANDHOME_PASSWD="$SANDHOME_HOME/shims/passwd"\n'
    printf '        export SANDHOME_PASSWD\n'
    printf '      fi\n'
    printf '      for _sh_shim_f in "$SANDHOME_HOME"/shims/*.so; do\n'
    printf '        [ -r "$_sh_shim_f" ] || continue\n'
    printf '        case ":${LD_PRELOAD:-}:" in\n'
    printf '          *":$_sh_shim_f:"*) ;;\n'
    printf '          *) LD_PRELOAD="$_sh_shim_f${LD_PRELOAD:+ $LD_PRELOAD}" ;;\n'
    printf '        esac\n'
    printf '      done\n'
    printf '      unset _sh_shim_f\n'
    printf '      export LD_PRELOAD\n'
    printf '      # The identity of this shell descriptors, so the interposer\n'
    printf '      # fakes THESE and not a pipe opened later. /proc/<pid>/fd, not\n'
    printf '      # /proc/self/fd, because readlink runs as a child whose fd 1 is\n'
    printf '      # the command-substitution pipe.\n'
    printf '      if [ -z "${SANDHOME_FAKEPTY_ID:-}" ] && [ -d "/proc/$$/fd" ] && command -v readlink >/dev/null 2>&1; then\n'
    printf '        _sh_ids=\n'
    printf '        for _sh_fd in 0 1 2; do\n'
    printf '          _sh_id=$(readlink "/proc/$$/fd/$_sh_fd" 2>/dev/null || true)\n'
    printf '          [ -n "$_sh_id" ] && _sh_ids="$_sh_ids $_sh_id"\n'
    printf '        done\n'
    printf '        if [ -n "$_sh_ids" ]; then\n'
    printf '          SANDHOME_FAKEPTY_ID=${_sh_ids# }\n'
    printf '          export SANDHOME_FAKEPTY_ID\n'
    printf '        fi\n'
    printf '        unset _sh_ids _sh_fd _sh_id\n'
    printf '      fi\n'
    printf '    fi\n'
    printf '    ;;\n'
    printf 'esac\n'
    printf '# Recorded preferences (see sh_pref_set in lib/env.sh): read back on\n'
    printf '# every shell, kept beside this generated file so rewrites keep them.\n'
    printf 'if [ -r "$SANDHOME_HOME/prefs.sh" ]; then\n'
    printf '  . "$SANDHOME_HOME/prefs.sh"\n'
    printf 'fi\n'
}

# sh_wanted_from_file -> the SANDHOME_WANTED_TOOLCHAINS already in env.sh, or
# nothing. Read with the shell's own read, because the library may not use grep,
# the same way sh_space_recorded_exec reads the exec root and doctor reads the
# wanted list.
sh_wanted_from_file() {
    sh_wff_out=''
    [ -r "$SH_HOME/env.sh" ] || {
        printf ''
        return 0
    }
    sh_wff_cr=$(printf '\r')
    while IFS= read -r sh_wff_l || [ -n "$sh_wff_l" ]; do
        sh_wff_l=${sh_wff_l%"$sh_wff_cr"}
        case "$sh_wff_l" in
            SANDHOME_WANTED_TOOLCHAINS=*)
                sh_wff_out=${sh_wff_l#SANDHOME_WANTED_TOOLCHAINS=}
                sh_wff_out=${sh_wff_out#\'}
                sh_wff_out=${sh_wff_out%\'}
                sh_wff_out=${sh_wff_out#\"}
                sh_wff_out=${sh_wff_out%\"}
                ;;
        esac
    done < "$SH_HOME/env.sh"
    printf '%s' "$sh_wff_out"
}

# sh_rust_targets_from_file -> the SANDHOME_RUST_TARGETS recorded in env.sh, or
# nothing. Same shape and reason as sh_wanted_from_file: a requested cross
# target is a fact this process may not hold when it rewrites the file, and a
# routine write must not erase it (issue #163).
sh_rust_targets_from_file() {
    sh_rtf_out=''
    [ -r "$SH_HOME/env.sh" ] || {
        printf ''
        return 0
    }
    sh_rtf_cr=$(printf '\r')
    while IFS= read -r sh_rtf_l || [ -n "$sh_rtf_l" ]; do
        sh_rtf_l=${sh_rtf_l%"$sh_rtf_cr"}
        case "$sh_rtf_l" in
            SANDHOME_RUST_TARGETS=*)
                sh_rtf_out=${sh_rtf_l#SANDHOME_RUST_TARGETS=}
                sh_rtf_out=${sh_rtf_out#\'}
                sh_rtf_out=${sh_rtf_out%\'}
                sh_rtf_out=${sh_rtf_out#\"}
                sh_rtf_out=${sh_rtf_out%\"}
                ;;
        esac
    done < "$SH_HOME/env.sh"
    printf '%s' "$sh_rtf_out"
}

# sh_ptrace_from_file -> the ptrace answer recorded in env.sh, or nothing. The
# bootstrap measures it once; a later install or repair regenerates env.sh
# without having run the probe, so the recorded value is read back and
# rewritten rather than dropped. Same shape as sh_wanted_from_file, for the
# same reason: a fact this process does not hold must not be erased by a
# routine write.
sh_ptrace_from_file() {
    sh_pff_out=''
    [ -r "$SH_HOME/env.sh" ] || {
        printf ''
        return 0
    }
    sh_pff_cr=$(printf '\r')
    while IFS= read -r sh_pff_l || [ -n "$sh_pff_l" ]; do
        sh_pff_l=${sh_pff_l%"$sh_pff_cr"}
        case "$sh_pff_l" in
            SANDHOME_PTRACE=*)
                sh_pff_out=${sh_pff_l#SANDHOME_PTRACE=}
                sh_pff_out=${sh_pff_out#\'}
                sh_pff_out=${sh_pff_out%\'}
                sh_pff_out=${sh_pff_out#\"}
                sh_pff_out=${sh_pff_out%\"}
                ;;
        esac
    done < "$SH_HOME/env.sh"
    printf '%s' "$sh_pff_out"
}

# sh_wanted_merge NAMES... -> fold NAMES into SH_WANTED_TOOLCHAINS, each once.
# install records what it was asked for so the gate can see an unfulfilled
# request later; a failed install still records the name, because a toolchain
# that could not be installed is exactly the one doctor must name.
sh_wanted_merge() {
    if [ -z "${SH_WANTED_TOOLCHAINS:-}" ]; then
        SH_WANTED_TOOLCHAINS=$(sh_wanted_from_file)
    fi
    for sh_wm_n in "$@"; do
        [ -n "$sh_wm_n" ] || continue
        case " $SH_WANTED_TOOLCHAINS " in
            *" $sh_wm_n "*) ;;
            *)
                if [ -n "$SH_WANTED_TOOLCHAINS" ]; then
                    SH_WANTED_TOOLCHAINS="$SH_WANTED_TOOLCHAINS $sh_wm_n"
                else
                    SH_WANTED_TOOLCHAINS=$sh_wm_n
                fi
                ;;
        esac
    done
    SH_WANTED_TOOLCHAINS=$(sh_trim "$SH_WANTED_TOOLCHAINS")
    export SH_WANTED_TOOLCHAINS
}

# sh_wanted_drop NAMES... -> remove NAMES from the wanted list, the other
# half of the --without shape on `sandhome install` (issue #129). Like
# sh_wanted_merge it starts from what the file already holds, so a drop in a
# process that never held the list drops from THE list, not from nothing. The
# result is written by the replace path in sh_env_write: a drop must be able
# to empty the list, and the merge path would read the file back in and undo
# it. Failing to install a toolchain and then dropping it must not leave the
# gate checking a name nobody wants any more.
sh_wanted_drop() {
    if [ -z "${SH_WANTED_TOOLCHAINS:-}" ]; then
        SH_WANTED_TOOLCHAINS=$(sh_wanted_from_file)
    fi
    for sh_wdr_n in "$@"; do
        [ -n "$sh_wdr_n" ] || continue
        sh_wdr_kept=''
        for sh_wdr_w in $SH_WANTED_TOOLCHAINS; do
            [ "$sh_wdr_w" = "$sh_wdr_n" ] && continue
            if [ -n "$sh_wdr_kept" ]; then
                sh_wdr_kept="$sh_wdr_kept $sh_wdr_w"
            else
                sh_wdr_kept=$sh_wdr_w
            fi
        done
        SH_WANTED_TOOLCHAINS=$sh_wdr_kept
    done
    SH_WANTED_TOOLCHAINS=$(sh_trim "$SH_WANTED_TOOLCHAINS")
    SH_WANTED_REPLACE=1
    export SH_WANTED_TOOLCHAINS SH_WANTED_REPLACE
}

# sh_env_mark_onpath DIR -> mark DIR as a directory this tree put on PATH.
#
# A directory that only reaches PATH because a fragment or env.sh put it there
# cannot serve a shell that has not read the environment, so the global hook
# must not be installed into it (issue #185). The mark lives inside the
# directory and is written here, at the point the directory joins PATH, so the
# two cannot drift: a new directory is marked by construction rather than by
# somebody remembering to add a name to a list.
#
# The mark is a file, not a directory entry or a symlink, so nothing resolves
# through it, `sh_promote_tree` has nothing to mirror, and a read-only
# directory is a no-op rather than a failure. A toolchain view is never marked
# by this function; the view is refused by sh_global_skip_entry by its own path
# pattern, and marking a view would put a file inside a tree the promote step
# mirrors.
sh_env_mark_onpath() {
    [ -n "${1:-}" ] || return 0
    case "$1" in
        */*) ;;
        *) return 0 ;;
    esac
    [ -d "$1" ] || return 0
    if [ -n "${SH_EXEC:-}" ]; then
        case "$1" in
            "$SH_EXEC"/views|"$SH_EXEC"/views/*) return 0 ;;
        esac
    fi
    if [ -e "$1/.sandhome-on-path" ]; then
        return 0
    fi
    if ( umask 022; : > "$1/.sandhome-on-path" ) 2>/dev/null; then
        return 0
    fi
    # # STOP: A SECOND RECORD, BESIDE THE MARK, BECAUSE A MARK CANNOT ALWAYS BE
    # WRITTEN. A read-only exec root refuses the file, and a directory this tree
    # put on PATH that is then taken as a hook directory is the whole of issue
    # #185. The home is writable on every host this tree supports, because
    # env.sh itself lives there, so the same list is appended there and read back
    # by sh_global_is_onpath_dir. Two records rather than one because the two
    # failure modes are different: the mark is fast and needs no read, the list
    # works when the directory cannot be written at all. (Issue #185.)
    [ -n "${SH_HOME:-}" ] || return 0
    [ -d "$SH_HOME" ] || return 0
    while IFS= read -r sh_em_l || [ -n "$sh_em_l" ]; do
        [ "$sh_em_l" = "$1" ] && return 0
    done < "$SH_HOME/on-path.dirs" 2>/dev/null
    printf '%s\n' "$1" >> "$SH_HOME/on-path.dirs" 2>/dev/null || true
    return 0
}

# sh_env_write_proxy -> write $SH_HOME/proxy.env, the egress variables this
# machine was reached through, and remove the file when there are none.
#
# ONE FILE, READ BY TWO CONSUMERS. env.sh inlines the values (so a sourced
# shell has them) and the global hook dispatcher sources this file (so the
# process it dispatches has them). Both are written from the same block in
# sh_env_body, and this file is generated from the same variable list, so the
# two cannot disagree about what the machine had.
#
# The file is REMOVED when nothing is set, rather than written empty, so a
# machine that genuinely has no proxy leaves no artefact naming one, and a
# machine whose proxy went away stops exporting it on the next install.
# (Issue #181.)
sh_env_write_proxy() {
    [ -n "${SH_HOME:-}" ] || return 0
    sh_ewp_tmp="$SH_HOME/proxy.env.tmp.$$"
    sh_ewp_n=0
    {
        printf '%s\n' '# sandhome egress configuration. Generated; refresh with any'
        printf '%s\n' '# install or repair. Sourced by env.sh consumers and by the'
        printf '%s\n' '# global hook dispatcher, because a sandbox that reaches the'
        printf '%s\n' '# network through a proxy loses it the moment the environment'
        printf '%s\n' '# is scrubbed, and every documented cold path scrubs (issue #181).'
        for sh_ewp_v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY all_proxy ALL_PROXY; do
            eval "sh_ewp_val=\${$sh_ewp_v:-}"
            [ -n "$sh_ewp_val" ] || continue
            printf '%s=%s\n' "$sh_ewp_v" "$(sh_sq_quote "$sh_ewp_val")"
            printf 'export %s\n' "$sh_ewp_v"
            sh_ewp_n=$((sh_ewp_n + 1))
        done
        printf 'SANDHOME_PROXY_VARS=%s\n' "$sh_ewp_n"
    } > "$sh_ewp_tmp" 2>/dev/null || { rm -f "$sh_ewp_tmp" 2>/dev/null; return 0; }
    if [ "$sh_ewp_n" = 0 ]; then
        rm -f "$sh_ewp_tmp" 2>/dev/null || true
        rm -f "$SH_HOME/proxy.env" 2>/dev/null || true
        return 0
    fi
    mv -f "$sh_ewp_tmp" "$SH_HOME/proxy.env" 2>/dev/null || {
        rm -f "$sh_ewp_tmp" 2>/dev/null
        return 0
    }
    return 0
}

# sh_env_write -> write $SH_HOME/env.sh.
sh_env_write() {
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would write $SH_HOME/env.sh"
        return 0
    fi
    # # NOTE: THE TMPDIR DECISION IS PROBED ONCE, THEN BAKED. `sh_exec_probe`
    # writes a file and runs it, which is the only honest answer to "can this
    # directory hold an executable temp file" - a writable /tmp that is noexec
    # answers no, and mount flags do not say so. The answer goes into env.sh as
    # a forced assignment or a guarded default, so no shell pays for the probe.
    SH_ENV_TMPDIR_FORCE=no
    if [ -n "${SH_EXEC:-}" ]; then
        sh_ew_tmpdir="${TMPDIR:-/tmp}"
        if [ -z "$sh_ew_tmpdir" ] || [ ! -d "$sh_ew_tmpdir" ] || \
           ! sh_exec_probe "$sh_ew_tmpdir" 2>/dev/null; then
            SH_ENV_TMPDIR_FORCE=yes
        fi
    fi
    sh_ew_tmp="$SH_HOME/env.sh.tmp.$$"
    sh_env_body > "$sh_ew_tmp" || return 1
    mv "$sh_ew_tmp" "$SH_HOME/env.sh" || return 1
    sh_env_write_proxy || true
    # The exec root carries a pointer back to the home beside the installed
    # command, so a copy with no inherited environment (or one whose baked home
    # is stale) can still find env.sh and the recorded exec root. Best effort:
    # a read-only or absent exec root is not a reason to fail an env write.
    if [ -n "${SH_EXEC:-}" ]; then
        printf '%s\n' "$SH_HOME" > "$SH_EXEC/.sandhome-home" 2>/dev/null || true
    fi
    sh_step "wrote $SH_HOME/env.sh"
    return 0
}

# sh_env_print -> the same bytes on stdout.
sh_env_print() { sh_env_body; }

# sh_repo_persist -> copy the sourced tree under the home when it runs from a
# scratch fetch dir, and repoint SH_REPO_DIR there. Returns 0 whether or not
# it copied: a clone already survives, so only a TMPDIR scratch tree triggers.
# (issue #20: the pipe bootstrap pinned SANDHOME_REPO_DIR to /tmp.)
sh_repo_persist() {
    case "${SH_REPO_DIR:-}" in
        "${TMPDIR:-/tmp}"/*|/tmp/sandhome-bootstrap.*)
            sh_rp_durable="$SH_HOME/repo"
            # A preview changes nothing: every other write step says `would`
            # under --dry-run, and the durable copy is a write like the rest.
            # (issue #70: a dry run left 39 files in a fresh home.)
            if [ "${SH_DRY_RUN:-0}" = 1 ]; then
                sh_step "would install the durable library at $sh_rp_durable"
                return 0
            fi
            mkdir -p "$sh_rp_durable" 2>/dev/null || return 0
            # skills/ rides along so the step-3 table keeps resolving: its
            # rows name skills/... and docs/... relative paths, and a durable
            # tree without skills/ makes every such route dangle (issue #90).
            for sh_rp_d in lib tools shell bin docs shims skills; do
                if [ -e "$SH_REPO_DIR/$sh_rp_d" ]; then
                    rm -rf "$sh_rp_durable/$sh_rp_d" 2>/dev/null
                    cp -r "$SH_REPO_DIR/$sh_rp_d" "$sh_rp_durable/$sh_rp_d" 2>/dev/null || \
                        sh_warn "could not persist $sh_rp_d to $sh_rp_durable"
                fi
            done
            if [ -r "$sh_rp_durable/lib/common.sh" ]; then
                SH_REPO_DIR=$sh_rp_durable
                export SH_REPO_DIR
                sh_step "installed the durable library at $sh_rp_durable"
            fi
            ;;
    esac
    return 0
}

# --------------------------------------------------- preferences --
# A recorded preference that survives an upgrade (issue #17, kejilion
# persisted-consent shape). The mechanism is the persistence, not the prompt:
# a consent flag that lives only in the current shell is a prompt on every
# shell, and a flag written to a file the tool does not read back is a flag
# that does not exist. prefs.sh lives BESIDE the generated env.sh, never
# inside it, so every env rewrite and every upgrade keeps the recorded
# value; env.sh sources it back on every shell, so the value is read where
# it is used. sandhome collects no telemetry and prompts nowhere (the
# profile fragment's rule forbids it: nothing runs at shell start that can
# fail), so no consent gate is installed; this is the mechanism a future
# preference, including a consent gate, is recorded with, and it belongs in
# the bootstrap, which runs once, never in the login path.
#
# Names are closed to [A-Za-z0-9_], so no value is ever spliced into a
# command; the file holds `NAME='quoted'` lines written with sh_sq_quote.
sh_prefs_file() { printf '%s/prefs.sh' "$SH_HOME"; }

sh_pref_set() {
    sh_ps_name=$1
    sh_ps_value=${2:-}
    case "$sh_ps_name" in
        ''|*[!A-Za-z0-9_]*) sh_warn "refusing preference name '$sh_ps_name'"; return 1 ;;
    esac
    sh_ps_file=$(sh_prefs_file)
    mkdir -p "$SH_HOME" 2>/dev/null || return 1
    sh_ps_tmp="$sh_ps_file.tmp.$$"
    sh_ps_q=$(sh_sq_quote "$sh_ps_value")
    if [ -r "$sh_ps_file" ]; then
        sh_ps_kept=''
        while IFS= read -r sh_ps_line || [ -n "$sh_ps_line" ]; do
            case "$sh_ps_line" in
                "$sh_ps_name="*|"export $sh_ps_name="*) ;;
                *) sh_ps_kept="$sh_ps_kept$sh_ps_line
" ;;
            esac
        done < "$sh_ps_file"
        printf '%s' "$sh_ps_kept" > "$sh_ps_tmp" || return 1
    else
        : > "$sh_ps_tmp" || return 1
    fi
    # Exported on source, so children of the shell see the recorded value.
    printf 'export %s=%s\n' "$sh_ps_name" "$sh_ps_q" >> "$sh_ps_tmp" || return 1
    mv "$sh_ps_tmp" "$sh_ps_file" || return 1
    return 0
}

sh_pref_get() {
    sh_pg_name=$1
    case "$sh_pg_name" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    sh_pg_file=$(sh_prefs_file)
    [ -r "$sh_pg_file" ] || return 1
    sh_pg_val=''
    sh_pg_found=0
    while IFS= read -r sh_pg_line || [ -n "$sh_pg_line" ]; do
        # A hand-edited prefs.sh may carry CRLF endings; strip the carriage
        # return the same way read does not (issue #17, judge finding 17-A),
        # or the value reads back with a literal \r attached.
        sh_pg_cr=$(printf '\r')
        sh_pg_line=${sh_pg_line%"$sh_pg_cr"}
        case "$sh_pg_line" in
            "export $sh_pg_name="*)
                sh_pg_val=${sh_pg_line#"export $sh_pg_name="}
                sh_pg_found=1
                ;;
            "$sh_pg_name="*)
                sh_pg_val=${sh_pg_line#*=}
                sh_pg_found=1
                ;;
        esac
    done < "$sh_pg_file"
    [ "$sh_pg_found" = 1 ] || return 1
    # The stored form is a single-quoted shell word; re-read it the way a
    # shell would rather than stripping quotes by hand.
    # TRUST, stated plainly (judge finding 17-B): the value below is data read
    # off disk and spliced into a command line. It is safe for every value
    # sh_pref_set writes, because those are single-quoted by sh_sq_quote. A
    # HAND-WRITTEN unquoted line like `NAME=x; rm -rf ~` WOULD be executed by
    # this shell read; prefs.sh sits under $SH_HOME at 0644, so that is a
    # person editing their own file, not a privilege boundary - but it is the
    # one place in this tree where a file value becomes a command. Do not call
    # sh_pref_get on a prefs.sh you did not write.
    sh_pg_out=$(sh -c "printf '%s' $sh_pg_val" 2>/dev/null) || return 1
    printf '%s' "$sh_pg_out"
    return 0
}

# sh_profile_source_line -> the one line the login files carry. It guards its own
# read, because a login file is read by every shell this account starts and a
# line that errors once the profile is gone is a line that errors forever.
sh_profile_source_line() {
    sh_psl_p=$(sh_sq_quote "$SH_HOME/profile.sh")
    printf 'if [ -r %s ]; then . %s; fi' "$sh_psl_p" "$sh_psl_p"
}

# sh_install_profile PROFILE_SRC -> install the fragment under the home and read
# it from every file a shell reads. Returns 0 whether or not it changed anything.
sh_install_profile() {
    sh_ip_src=$1
    if [ ! -f "$sh_ip_src" ]; then
        sh_warn "no shell profile at $sh_ip_src; nothing installed"
        return 1
    fi
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_ip_src as $SH_HOME/profile.sh and read it from the login files"
        return 0
    fi
    cp -f "$sh_ip_src" "$SH_HOME/profile.sh" || { sh_fail "could not install $SH_HOME/profile.sh"; return 1; }
    chmod 0644 "$SH_HOME/profile.sh" 2>/dev/null || true
    sh_step "installed $SH_HOME/profile.sh"
    sh_pl_line=$(sh_profile_source_line)
    # A NARROW PREFIX, SO A HAND-WRITTEN LINE IS NEVER TAKEN FOR OURS (issue
    # #188). This call used the two-argument form, which matches the FIRST line
    # equal to the fragment line anywhere in the file and works; the PATH line
    # below used `export PATH="` as a prefix, which matches every line in the
    # file that starts an export PATH and DROPS all but the first - the user's
    # own PATH entries among them. That is the defect; this call is already
    # scoped to the exact line sh_profile_source_line writes.
    sh_append_login "$sh_pl_line" "$SH_HOME/profile.sh"
    sh_append_rc "$sh_pl_line" "$SH_HOME/profile.sh"
    return 0
}

# sh_bake_command SRC DST -> install the sandhome launcher at DST with the
# durable checkout and the home baked into it, and verify the result rather
# than announcing it.
#
# # STOP: THERE IS EXACTLY ONE WRITER OF THAT FILE, BECAUSE EVERY INSTALL AND
# REPAIR USED TO COPY THE UNBAKED TEMPLATE OVER THE BOOTSTRAP'S BAKE. The
# bootstrap baked, reported "baked ... into ...", and the next `sandhome
# install` or `sandhome repair` put the raw template back, so
#   env -i $SANDHOME_EXEC/bin/sandhome doctor
# exited 2 while the log still claimed a bake, and the promise the skill
# makes about a process with no inherited environment was true only until the
# first repair (issue #133). Measured here: 1 baked line after the bootstrap, 0
# after one `repair jq`, 0 after one `install jq`.
#
# WHY A VERIFY AND NOT A LOG LINE. The old bake printed a step when the read
# loop merely produced a file, and printed a different step when it did not, so
# both a working bake and a broken one were a line of prose. Here the baked
# values are read back out of the written file with the shell's own read and
# compared to what was asked for. A path containing a single quote is refused
# rather than half-baked, and a refused bake keeps the HOME lookup, which is
# the documented fallback.
sh_bake_command() {
    sh_bc_src=$1
    sh_bc_dst=$2
    [ -r "$sh_bc_src" ] && [ -n "$sh_bc_dst" ] || return 1
    if [ "$(sh_lex_normalize "$sh_bc_src")" = "$(sh_lex_normalize "$sh_bc_dst")" ]; then
        # Same file: the caller is already running the copy. It was baked when
        # it was written; re-baking it here would rewrite the file a running
        # shell is reading.
        return 0
    fi
    # # STOP: THE LAUNCHER IS BUILT FROM SRC THROUGH A TEMP FILE, NEVER BY
    # COPYING ONTO DST FIRST. `sandhome install` runs AS the copy on the exec
    # root, so sh_bc_dst is the very file the shell is reading; `cp -f src dst`
    # truncates it mid-execution and a shell that reads its next chunk from a
    # file being rewritten can be left with a half-written launcher. Measured:
    # a bake left a 8264-byte `sandhome` whose last line opened a quote, and the
    # next command died with `Syntax error: Unterminated quoted string`. A
    # complete temp file renamed into place replaces the name atomically and
    # leaves the running inode alone.
    sh_bc_tmp="$sh_bc_dst.bake.$$"
    sh_bc_ok=0
    case "${SH_REPO_DIR:-}:${SH_HOME:-}" in
        *\'*)
            # A quote in either path cannot be baked. Still install the raw
            # template (through the same atomic rename) so the command exists
            # and falls back to the conventional home lookup.
            if cp -f "$sh_bc_src" "$sh_bc_tmp" 2>/dev/null && \
               chmod 0755 "$sh_bc_tmp" 2>/dev/null && \
               mv -f "$sh_bc_tmp" "$sh_bc_dst" 2>/dev/null; then :; fi
            rm -f "$sh_bc_tmp" 2>/dev/null
            sh_warn "not baking the paths into $sh_bc_dst (a quote in $SH_REPO_DIR or $SH_HOME); a launch with no HOME falls back to the conventional home"
            return 0 ;;
    esac
    {
        while IFS= read -r sh_bc_l || [ -n "$sh_bc_l" ]; do
            case "$sh_bc_l" in
                SH_BAKED_REPO_DIR=*) printf "SH_BAKED_REPO_DIR='%s'\n" "$SH_REPO_DIR" ;;
                SH_BAKED_HOME=*)     printf "SH_BAKED_HOME='%s'\n" "$SH_HOME" ;;
                *) printf '%s\n' "$sh_bc_l" ;;
            esac
        done < "$sh_bc_src"
    } > "$sh_bc_tmp" 2>/dev/null && chmod 0755 "$sh_bc_tmp" 2>/dev/null && \
        mv -f "$sh_bc_tmp" "$sh_bc_dst" 2>/dev/null && sh_bc_ok=1
    rm -f "$sh_bc_tmp" 2>/dev/null
    if [ "$sh_bc_ok" != 1 ]; then
        sh_warn "could not bake the paths into $sh_bc_dst; a launch with no HOME falls back to the conventional home"
        return 0
    fi
    # Read the written file back and compare. sh_bake_value reads the line and
    # strips the quotes, so the comparison is against what a shell sourcing the
    # file would see, not against a guess about the format.
    sh_bc_r=$(sh_bake_value "$sh_bc_dst" SH_BAKED_REPO_DIR)
    sh_bc_h=$(sh_bake_value "$sh_bc_dst" SH_BAKED_HOME)
    # # STOP: THE BAKE IS VERIFIED WHOLE, NOT ONLY BY ITS TWO VALUES. A
    # truncated launcher kept both baked lines near the top and passed the old
    # check, then every command failed to parse. The shell's own parser is the
    # cheapest whole-file check and it needs nothing but the interpreter.
    # REDUNDANCY: SIZE IS THE SECOND WITNESS. A launcher that parses but lost
    # its tail (a here-doc body, a usage page) is still a broken command; the
    # baked file must carry at least the source's bytes, so a short file fails
    # even when its head parses.
    sh_bc_src_n=$(wc -c < "$sh_bc_src" 2>/dev/null)
    sh_bc_dst_n=$(wc -c < "$sh_bc_dst" 2>/dev/null)
    case "$sh_bc_src_n" in ''|*[!0-9]*) sh_bc_src_n=0 ;; esac
    case "$sh_bc_dst_n" in ''|*[!0-9]*) sh_bc_dst_n=0 ;; esac
    if [ "$sh_bc_r" = "$SH_REPO_DIR" ] && [ "$sh_bc_h" = "$SH_HOME" ] && sh -n "$sh_bc_dst" 2>/dev/null && [ "$sh_bc_dst_n" -ge "$sh_bc_src_n" ]; then
        sh_step "baked $SH_REPO_DIR and $SH_HOME into $sh_bc_dst"
    else
        sh_warn "the bake at $sh_bc_dst is incomplete (repo='$sh_bc_r' home='$sh_bc_h'); a launch with no HOME falls back to the conventional home"
    fi
    return 0
}

# sh_entry_write -> write the sourceable entry point beside the home.
#
# The entry point is the cold-shell fallback for a host whose PATH cannot carry
# the global hook. It is SOURCED, not executed, because the home may refuse
# execve. It defines a `sandhome` function with three fallbacks: the baked exec
# bin, the recorded exec bin, and the checkout's launcher read through `sh`.
#
# # STOP: THE FALLBACKS HAVE TO SURVIVE A WIPED EXEC ROOT, WHICH IS THE ONE
# STATE THIS FILE EXISTS FOR. The repo launcher is mode 0644 by design, so a
# `[ -x ]` test skipped it and the one copy that survives a tmpfs restart was
# dead code (issue #154). And a PATH fallback that tests `command -v sandhome`
# from inside a function named sandhome finds that function, then `command
# sandhome` bypasses functions and fails, so the designed diagnostic was
# replaced by `sandhome: not found` (issue #154). Both are fixed here, in one
# writer, so the bootstrap and resume cannot drift apart.
sh_entry_write() {
    [ -d "${SH_HOME:-}" ] || return 0
    [ -n "${SH_EXEC_BIN:-}" ] || return 0
    sh_ew_qhome=$(sh_sq_quote "$SH_HOME")
    sh_ew_qexec=$(sh_sq_quote "${SH_EXEC:-}")
    sh_ew_qbin=$(sh_sq_quote "$SH_EXEC_BIN/sandhome")
    # The home keeps its own copy of the checkout at $SH_HOME/repo, which is the
    # copy that survives a tmpfs restart; the resolved repo is the second
    # candidate. Both are mode 0644 by design, so each is read through `sh`.
    sh_ew_qhomerepo=$(sh_sq_quote "$SH_HOME/repo/bin/sandhome")
    if [ -n "${SH_REPO_DIR:-}" ]; then
        sh_ew_qrepo=$(sh_sq_quote "$SH_REPO_DIR/bin/sandhome")
    else
        sh_ew_qrepo="''"
    fi
    {
        printf '%s\n' '# sandhome entry point. Generated; sourced, not executed.'
        printf '%s\n' "# Written because a non-login shell has no PATH (issue #122)."
        printf '%s\n' "SANDHOME_HOME=\${SANDHOME_HOME:-$sh_ew_qhome}"
        printf '%s\n' "SANDHOME_EXEC=\${SANDHOME_EXEC:-$sh_ew_qexec}"
        printf '%s\n' 'export SANDHOME_HOME SANDHOME_EXEC'
        printf '%s\n' "_sandhome_baked=$sh_ew_qbin"
        printf '%s\n' "_sandhome_home_repo=$sh_ew_qhomerepo"
        printf '%s\n' "_sandhome_repo=$sh_ew_qrepo"
        printf '%s\n' 'sandhome() {'
        printf '%s\n' '  if [ -x "$_sandhome_baked" ]; then "$_sandhome_baked" "$@"; return $?; fi'
        printf '%s\n' '  if [ -n "${SANDHOME_EXEC:-}" ] && [ -x "$SANDHOME_EXEC/bin/sandhome" ]; then "$SANDHOME_EXEC/bin/sandhome" "$@"; return $?; fi'
        printf '%s\n' '  if [ -r "$_sandhome_home_repo" ]; then sh "$_sandhome_home_repo" "$@"; return $?; fi'
        printf '%s\n' '  if [ -n "${_sandhome_repo:-}" ] && [ -r "$_sandhome_repo" ]; then sh "$_sandhome_repo" "$@"; return $?; fi'
        printf '%s\n' '  _sandhome_ext=$(command -v sandhome 2>/dev/null)'
        printf '%s\n' '  case "$_sandhome_ext" in'
        printf '%s\n' '    /*|*/*) if [ -x "$_sandhome_ext" ]; then "$_sandhome_ext" "$@"; return $?; fi ;;'
        printf '%s\n' '  esac'
        printf '%s\n' '  printf "%s\\n" "sandhome: no working copy (baked $_sandhome_baked missing, SANDHOME_EXEC/bin/sandhome missing, repo/bin/sandhome missing, nothing on PATH; re-run the setup)" >&2; return 127'
        printf '%s\n' '}'
        printf '%s\n' "[ -r \"\$SANDHOME_HOME/env.sh\" ] && . \"\$SANDHOME_HOME/env.sh\""
    } > "$SH_HOME/entry.sh" 2>/dev/null
    # The entry point is sourced by shells that cannot run anything else; a
    # file with a syntax error there breaks every cold shell at once. Verify
    # with the shell's own parser before reporting success, and warn (not die:
    # the old file, if any, is already replaced) when it does not parse.
    if [ -r "$SH_HOME/entry.sh" ]; then
        if sh -n "$SH_HOME/entry.sh" 2>/dev/null; then
            :
        else
            sh_warn "the entry point at $SH_HOME/entry.sh does not parse; a cold shell cannot use it"
        fi
    fi
    unset sh_ew_qhome sh_ew_qexec sh_ew_qbin sh_ew_qhomerepo sh_ew_qrepo
    return 0
}

# sh_bake_value FILE NAME -> the value of NAME= in FILE, quotes stripped.
# The read is the same one every other reader of a generated file in this tree
# uses, because the library may not use grep and because a read that stops at
# the first match is all this needs.
sh_bake_value() {
    sh_bv_out=''
    [ -r "$1" ] || return 1
    while IFS= read -r sh_bv_l || [ -n "$sh_bv_l" ]; do
        case "$sh_bv_l" in
            "$2"=*)
                sh_bv_out=${sh_bv_l#*=}
                sh_bv_out=${sh_bv_out#\'}
                sh_bv_out=${sh_bv_out%\'}
                sh_bv_out=${sh_bv_out#\"}
                sh_bv_out=${sh_bv_out%\"}
                break ;;
        esac
    done < "$1"
    printf '%s' "$sh_bv_out"
    return 0
}

# sh_exec_mirror_library -> keep a private copy of lib/ and bin/ beside the
# installed launcher, so `env -i <exec>/bin/sandhome` works on a host whose
# checkout is gone. The launcher looks for it first (see bin/sandhome), which is
# the one route that cannot go stale: it lives beside the copy, so it moves when
# the copy moves and disappears when the copy does.
#
# COST, AND WHY IT IS NOT OPTIONAL. lib/ is about 400KB of text and bin/ one
# script; the mirror is written once per install and once per repair, never on
# a command, and it is replaced atomically per file so a running copy never
# reads a half-written library. The alternative is that the whole command
# depends on a checkout path staying valid for the life of the sandbox, which
# issue #88's bake was supposed to buy and issue #133 measured dying anyway.
# `--no-lib` and SANDHOME_MIRROR_LIB=0 turn it off for a host that would rather
# not hold a second copy; the bake and the pointers still run.
sh_exec_mirror_library() {
    # # THE ROOT IS READ THROUGH SANDHOME_EXEC, AS EVERY OTHER WRITER READS IT.
    # This took `${SH_EXEC:-}`, while bin/sandhome binds `SANDHOME_EXEC` from
    # `SH_EXEC` at each entry point and the dispatcher, env.sh and the plan
    # all work from `SANDHOME_EXEC`. A caller that holds only the bound name
    # -- a sourced env.sh, a fragment, a repair path -- got `sh_eml_exec=` and
    # an early `return 0`, so the mirror was silently not written. Measured:
    # the same call with SH_EXEC set refreshed the mirror, and without it
    # returned 0 having done nothing. SH_EXEC is still honoured, because the
    # bootstrap sets both.
    sh_eml_exec=${SANDHOME_EXEC:-${SH_EXEC:-}}
    sh_eml_repo=${SH_REPO_DIR:-}
    [ -n "$sh_eml_exec" ] || return 0
    [ -n "$sh_eml_repo" ] || return 0
    [ "${SH_DRY_RUN:-0}" = 1 ] && return 0
    case "${SANDHOME_MIRROR_LIB:-1}" in
        0|no|off|false) return 0 ;;
    esac
    sh_eml_dst=$sh_eml_exec/.sandhome-lib
    [ "$(sh_lex_normalize "$sh_eml_repo")" = "$(sh_lex_normalize "$sh_eml_dst")" ] && return 0
    sh_eml_tmp=$sh_eml_dst.new.$$
    rm -rf "$sh_eml_tmp" 2>/dev/null || true
    for sh_eml_rel in lib bin; do
        [ -d "$sh_eml_repo/$sh_eml_rel" ] || continue
        mkdir -p "$sh_eml_tmp/$sh_eml_rel" 2>/dev/null || return 0
        for sh_eml_f in "$sh_eml_repo/$sh_eml_rel"/*; do
            [ -f "$sh_eml_f" ] || continue
            cp -f "$sh_eml_f" "$sh_eml_tmp/$sh_eml_rel/${sh_eml_f##*/}" 2>/dev/null || true
        done
    done
    [ -r "$sh_eml_tmp/lib/common.sh" ] || { rm -rf "$sh_eml_tmp" 2>/dev/null; return 0; }
    # Per-file replace: the destination keeps serving a running command while
    # the new library lands, and a file that is not copied keeps its old bytes
    # rather than becoming an empty hole in a library.
    for sh_eml_rel in lib bin; do
        [ -d "$sh_eml_tmp/$sh_eml_rel" ] || continue
        mkdir -p "$sh_eml_dst/$sh_eml_rel" 2>/dev/null || continue
        for sh_eml_f in "$sh_eml_tmp/$sh_eml_rel"/*; do
            [ -f "$sh_eml_f" ] || continue
            cp -f "$sh_eml_f" "$sh_eml_dst/$sh_eml_rel/${sh_eml_f##*/}.new" 2>/dev/null || continue
            mv -f "$sh_eml_dst/$sh_eml_rel/${sh_eml_f##*/}.new" "$sh_eml_dst/$sh_eml_rel/${sh_eml_f##*/}" 2>/dev/null || \
                rm -f "$sh_eml_dst/$sh_eml_rel/${sh_eml_f##*/}.new" 2>/dev/null
        done
    done
    rm -rf "$sh_eml_tmp" 2>/dev/null
    unset sh_eml_exec sh_eml_repo sh_eml_dst sh_eml_tmp sh_eml_rel sh_eml_f
    return 0
}

# sh_exec_install_launchers -> put sandhome and errandsh on the chosen exec bin.
# STOP: ONLY THE BOOTSTRAP USED TO PLACE THE LAUNCHER. A create plan can move the
# exec root (a new box, a cleared tmpfs, a root that filled and was replaced),
# and `sandhome install` then rebuilt views on the new root while `sandhome`
# itself stayed on the old one: the next shell got `command not found` for the
# very command that had just run. Copying the two launchers here makes whichever
# root the plan chose self-contained, on the repair path as well as the first
# install (#41).
sh_exec_install_launchers() {
    # SANDHOME_EXEC first, as sh_exec_mirror_library and the plan do; SH_EXEC
    # is the bootstrap's spelling and both are set there. A caller holding
    # only the bound name still gets a self-contained root.
    sh_eil_bin=${SH_EXEC_BIN:-}
    if [ -z "$sh_eil_bin" ]; then
        case "${SANDHOME_EXEC:-${SH_EXEC:-}}" in
            '') : ;;
            *) sh_eil_bin=${SANDHOME_EXEC:-${SH_EXEC:-}}/bin ;;
        esac
    fi
    sh_eil_repo=${SH_REPO_DIR:-}
    [ -n "$sh_eil_bin" ] || return 0
    [ -n "$sh_eil_repo" ] || return 0
    [ "${SH_DRY_RUN:-0}" = 1 ] && return 0
    mkdir -p "$sh_eil_bin" 2>/dev/null || return 0
    sh_eil_src="$sh_eil_repo/bin/sandhome"
    # ONE WRITER, EVERY PATH. The bootstrap and this function used to bake and
    # copy respectively, which is how the bake survived until the first repair
    # and then died (issue #133).
    sh_bake_command "$sh_eil_src" "$sh_eil_bin/sandhome" || true
    # faketty as well as errandsh: errandsh finds it beside itself, so both
    # copies are needed for a full-screen program to work from the exec root.
    for sh_eil_rel in shell/errandsh shell/faketty; do
        sh_eil_src="$sh_eil_repo/$sh_eil_rel"
        sh_eil_dst="$sh_eil_bin/${sh_eil_rel##*/}"
        if [ -r "$sh_eil_src" ] && [ "$(sh_lex_normalize "$sh_eil_src")" != "$(sh_lex_normalize "$sh_eil_dst")" ]; then
            cp -f "$sh_eil_src" "$sh_eil_dst" 2>/dev/null && \
                chmod 0755 "$sh_eil_dst" 2>/dev/null || true
        fi
    done
    unset sh_eil_rel sh_eil_src sh_eil_dst
    sh_exec_mirror_library
    return 0
}

# sh_env_scratch_home -> give a HOME-less process the same scratch HOME a
# sourced shell gets from env.sh.
#
# # STOP: AN IN-PROCESS COMMAND MUST SEE THE SAME HOME A SOURCED SHELL DOES
# (issue #179). env.sh sets one when the caller has none, but doctor and the
# other commands that call sh_env_load never source it, so
#   env -i /tmp/bin/sandhome doctor
# ran the deno self-exec probe with no HOME and failed with "Could not resolve
# global Deno cache directory", and node's npm probe failed with
# "uv_os_homedir returned ENOENT", while both passed in a shell. A subprocess
# probe inherits this process's environment, so the default belongs here too.
#
# # STOP: THE VARIABLE IS SET AND THE DIRECTORY IS NOT CREATED, BECAUSE A
# READ-ONLY COMMAND MUST CREATE NOTHING. `sandhome report` and its siblings
# promise to touch no root when they only answer a question, and a `mkdir -p`
# for HOME/TMPDIR here made them create $SANDHOME_EXEC on the way to printing
# (measured by tests/space.sh: "sandhome report creates nothing" went from pass
# to fail). The probes that need the directory make it themselves - deno
# creates the cache root under HOME on first use - so setting the variable is
# the whole of the fix.
sh_env_scratch_home() {
    sh_esh_exec=${SANDHOME_EXEC:-${SH_EXEC:-}}
    [ -n "$sh_esh_exec" ] || return 0
    if [ -z "${HOME:-}" ]; then
        HOME="$sh_esh_exec/home"
        export HOME
    fi
    return 0
}

# sh_env_load -> make this shell match the written environment, so a run that
# installed a tool can then probe for it in the same process. Exported variables
# only; the exec view is on PATH.
#
# STOP: IT DEFAULTS BEFORE IT DEREFERENCES, BECAUSE IT SOURCES UNTRUSTED-BY-AGE
# FRAGMENTS UNDER `set -u`. A leftover `env.d/*.sh` referencing an unset
# `$SANDHOME_HOME` aborted every toolset on a re-run, and `$SH_EXEC_BIN` unset
# before any plan aborted the prepend itself. The plan owns the values; this
# adopts them when the caller did not set them, so no fragment can abort.
sh_env_load() {
    : "${SH_HOME:=}"
    : "${SH_EXEC:=}"
    : "${SH_EXEC_BIN:=}"
    : "${SANDHOME_HOME:=${SH_HOME:-}}"
    : "${SANDHOME_EXEC:=${SH_EXEC:-}}"
    export SANDHOME_HOME SANDHOME_EXEC
    # # STOP: THE RECORDED EGRESS IS RESTORED HERE, BECAUSE A COMMAND THAT
    # REBUILDS THE TREE RUNS WITH NO EGRESS (issue #181). `sandhome resume` is
    # exactly the cold path: a wiped exec root means no `sandhome` on PATH, so
    # the command is reached through entry.sh or by absolute path, both of which
    # start from an environment that has no proxy in it. It then rebuilds every
    # view and rewrites env.sh, and the egress file it rewrote had been wiped
    # with the rest of the home, so the machine came back with no route out and
    # `report` said `egress=unknown`. Measured here: after `mv exec exec.wiped`
    # and the documented `entry.sh; sandhome resume`, doctor was green with
    # doctor_failures=0 and every toolchain present, and egress=unknown.
    #
    # The file is read BEFORE anything else here, so a rebuild has the same
    # egress the install had. The file carries UNGUARDED assignments because
    # env.sh sources it the same way, and that is deliberate there: the file is
    # the machine's record and env.sh's own inline block is the guarded one.
    # Here the caller may already have an egress of its own - a shell that
    # exported one before running a command, or an operator who set it for one
    # build - so each name is read only when this process does not have it.
    # Overwriting here would silently break the very command that was working.
    if [ -n "${SH_HOME:-}" ] && [ -r "$SH_HOME/proxy.env" ]; then
        while IFS= read -r sh_el_pr || [ -n "$sh_el_pr" ]; do
            case "$sh_el_pr" in
                export\ *|*=*) ;;
                *) continue ;;
            esac
            sh_el_pv=${sh_el_pr#export }
            case "$sh_el_pv" in
                *http_proxy=*|*https_proxy=*|*no_proxy=*|*HTTP_PROXY=*|\
                *HTTPS_PROXY=*|*NO_PROXY=*|*all_proxy=*|*ALL_PROXY=*)
                    sh_el_pn=${sh_el_pv%%=*}
                    eval "[ -n \"\${$sh_el_pn:-}\" ]" && continue
                    eval "$sh_el_pv"
                    eval "export $sh_el_pn"
                    unset sh_el_pr sh_el_pv sh_el_pn
                    ;;
            esac
        done < "$SH_HOME/proxy.env"
    fi
    if [ -n "${SH_EXEC_BIN:-}" ]; then
        sh_path_prepend "$SH_EXEC_BIN"
    fi
    if [ -n "${SH_HOME:-}" ] && [ -r "$SH_HOME/prefs.sh" ]; then
        # shellcheck disable=SC1090
        . "$SH_HOME/prefs.sh"
    fi
    if [ -d "$SH_HOME/env.d" ]; then
        for sh_el_f in "$SH_HOME"/env.d/*.sh; do
            [ -r "$sh_el_f" ] || continue
            # shellcheck disable=SC1090
            . "$sh_el_f"
        done
    fi
    return 0
}

# sh_env_apply -> the environment for a child command, the SAME one a shell gets
# from reading env.sh. sh_env_load sets PATH but not the scratch roots; the
# global hook runs the copied `sandhome` directly rather than through the
# dispatcher, so without this `sandhome exec python3 script.py` would leave
# TMPDIR on a noexec /tmp and the child could not run a file it writes. Source
# the generated file when the home has one, and fall back to the in-process load
# for a home that was never written.
sh_env_apply() {
    if [ -n "${SH_HOME:-}" ] && [ -r "$SH_HOME/env.sh" ]; then
        # shellcheck disable=SC1090
        . "$SH_HOME/env.sh"
        return 0
    fi
    sh_env_load
}

# ------------------------------------------------------- the global hook --
# # STOP: A FRESH SHELL MUST NOT BE ASKED TO SOURCE ANYTHING. The environment was
# one file, `env.sh`, and every caller had to read it in every new shell: a tool
# harness that spawns a non-login shell per call ran
#   bash . "$HOME/.local/share/sandhome/env.sh" <cmd>
# in front of every command, and a caller told "setup once" watched it not be
# so (issue #127). The snippet beside the home (`entry.sh`) made the one line
# short, not absent, and the docs carried the per-call cost as a fact of life.
#
# This is the userspace route. The sandbox fixes the environment of each spawned
# shell, so the only thing a fresh shell consults on its own is `PATH`. A
# `PATH` entry is usable in one of two ways, and both are handled:
#
#   1. The directory runs binaries and is writable. The hook is written into
#      it directly. This is the ordinary case on a host whose home is exec.
#   2. The directory is on a root that refuses `execve` (this tree's subject),
#      but its PARENT is writable. The entry becomes a SYMLINK to a directory
#      under the exec root, which runs. Measured on the sandbox this was built
#      for: /state/home is noexec, yet
#         /state/home/.pi/agent/bin -> /workspace/.sandhome/exec/global
#      and `command -v` then `exec` of a file under the link succeed, because
#      the kernel resolves the link and permits exec on the resolved root. A
#      noexec *mount* is a wall; a path through a symlink is a door in it.
#
# REDUNDANCY: THE HOOK IS INSTALLED INTO EVERY QUALIFYING PATH ENTRY, NOT ONLY
# THE FIRST. Different shells on one machine inherit different PATHs (a harness
# that rebuilds PATH, a login shell that drops entries, `env -i` with a subset),
# and a hook only in the first-choice directory is invisible to a shell that
# does not carry it. Each qualifying entry gets the same dispatcher, so any one
# of them serving a shell is enough. The set is bounded (SH_GI_MAX_DIRS) so a
# pathological PATH cannot turn one install into dozens of writes.
#
# VERIFICATION: AN INSTALLED HOOK IS PROBED FROM OUTSIDE BEFORE IT IS REPORTED
# AS ON. Writing the files proves nothing about whether a fresh shell can use
# them, so `sh_global_probe` runs the dispatcher itself in a fresh `env -i`
# shell and reads back a marker that only appears after `env.sh` was sourced
# with both roots set. `sandhome report` and `doctor` read that probe, so a
# hook that was installed and later broke says `stale:` instead of repeating
# what an install once claimed, and `doctor` fails on it: a recorded hook that
# no longer answers is exactly the #127 failure coming back. A host with no
# hook at all still reports `none` and doctor stays green: a host's layout is
# not an install error.
#
# SAFETY: REMOVE RESTORES WHAT INSTALL FOUND, and never deletes a file the
# install did not create. Every PATH entry's original state is recorded at
# install time (`absent`, `dir`, or `link:<target>`): `--remove` puts it back.
# A live symlink that does not point into the exec root is never replaced, a
# non-empty directory is never replaced, and a regular file at a PATH entry is
# never touched; each of those entries is skipped and the scan moves on. In a
# shared (case 1) directory, a name that already exists is left alone and
# recorded as a clash rather than shadowed.
#
# STOP: THE HOOK IS DISCOVERED, NOT ASSUMED. No directory name is hard-coded:
# candidates are read from THIS shell's `PATH`, which is the same list every
# fresh shell in this sandbox inherits, and the choice is recorded so `remove`
# and the report can name it. A host with no writable candidate says so in one
# sentence and keeps `entry.sh` as the documented fallback.

# SH_GI_MAX_DIRS: one hook per qualifying PATH entry, capped so a hostile or
# degenerate PATH (dozens of writable entries) cannot turn one install into
# dozens of host directories. Six is above every PATH seen on the sandboxes
# this tree targets (two or three qualify there).
SH_GI_MAX_DIRS=6

sh_global_state_dir() { printf '%s/global' "${SH_HOME:-}"; }

# sh_global_read FIELD -> the field's first line, or nothing. Scalar fields
# live at the top of the record; `link` and `command` are mirrors of the first
# hooked directory so a single-directory reader (status, tests) keeps one answer.
sh_global_read() {
    sh_gr_out=''
    sh_gr_f="$(sh_global_state_dir)/$1"
    if [ -r "$sh_gr_f" ]; then
        IFS= read -r sh_gr_out < "$sh_gr_f" || sh_gr_out=''
    fi
    printf '%s' "$sh_gr_out"
}

# sh_global_dirs -> the recorded hook directories, one per line, PATH order.
sh_global_dirs() {
    sh_gd_f="$(sh_global_state_dir)/dirs"
    [ -r "$sh_gd_f" ] || return 0
    while IFS= read -r sh_gd_line || [ -n "$sh_gd_line" ]; do
        [ -n "$sh_gd_line" ] && printf '%s\n' "$sh_gd_line"
    done < "$sh_gd_f"
    return 0
}

# sh_global_dir -> the first recorded directory, or nothing. The singular view
# of sh_global_dirs, kept because every single-directory reader wants it.
sh_global_dir() {
    sh_gdi_f="$(sh_global_state_dir)/dirs"
    sh_gdi_out=''
    if [ -r "$sh_gdi_f" ]; then
        IFS= read -r sh_gdi_out < "$sh_gdi_f" || sh_gdi_out=''
    fi
    if [ -z "$sh_gdi_out" ]; then
        sh_gdi_out=$(sh_global_read dir)
    fi
    printf '%s' "$sh_gdi_out"
}

# sh_global_names -> the recorded tool names, one per line.
sh_global_names() {
    sh_gn_f="$(sh_global_state_dir)/names"
    [ -r "$sh_gn_f" ] || return 0
    while IFS= read -r sh_gn_line || [ -n "$sh_gn_line" ]; do
        [ -n "$sh_gn_line" ] && printf '%s\n' "$sh_gn_line"
    done < "$sh_gn_f"
    return 0
}

# sh_global_clashes -> names the hook wanted to expose but a host file in the
# directory already answers, so PATH serves the host copy to fresh shells.
sh_global_clashes() {
    sh_gl_f="$(sh_global_state_dir)/clashes"
    [ -r "$sh_gl_f" ] || return 0
    while IFS= read -r sh_gl_line || [ -n "$sh_gl_line" ]; do
        [ -n "$sh_gl_line" ] && printf '%s\n' "$sh_gl_line"
    done < "$sh_gl_f"
    return 0
}

# sh_global_forget -> drop the record without touching the filesystem. Used
# when a refresh installed nothing and no old record existed, so a run cannot
# leave half a record behind.
sh_global_forget() {
    rm -rf "$(sh_global_state_dir)" 2>/dev/null || true
    return 0
}

# sh_global_view_names -> every executable the exec view exposes, minus the
# command, the shell and the internal helper. These are the names a fresh shell
# should find: exactly the set `env.sh` would have put on PATH.
sh_global_view_names() {
    [ -n "${SH_EXEC_BIN:-}" ] && [ -d "$SH_EXEC_BIN" ] || return 0
    for sh_gv_f in "$SH_EXEC_BIN"/*; do
        [ -e "$sh_gv_f" ] || [ -L "$sh_gv_f" ] || continue
        sh_gv_n=${sh_gv_f##*/}
        case "$sh_gv_n" in
            sandhome|errandsh|faketty|sandhome-memexec) continue ;;
        esac
        # # STOP: A PATH HIT INSIDE THIS TREE IS NOT "PATH WILL SERVE IT". The
        # whole point of the hook is a shell that has NOT read env.sh, and
        # views/<name>/bin and npm-global/bin are on PATH only BECAUSE env.sh
        # put them there. `npm` and `npx` are symlinks to the node view's npm
        # cli scripts, so the old filter dropped both and a fresh shell had
        # node but no npm while `toolchains` advertised all three (issue #132).
        #
        # The test is the exec ROOT, not the view bin: everything under
        # $SH_EXEC is this tree's own indirection, so a hit there can only be
        # served by a shell that has already read the environment the hook
        # exists to make unnecessary. A hit OUTSIDE it is a real host copy and
        # PATH keeps serving the tool.
        if [ -L "$SH_EXEC_BIN/$sh_gv_n" ] && sh_is_script "$SH_EXEC_BIN/$sh_gv_n"; then
            sh_gv_hit=$(sh_path_where "$sh_gv_n" 2>/dev/null)
            if [ -n "$sh_gv_hit" ] && [ -n "${SH_EXEC:-}" ]; then
                case "$sh_gv_hit" in
                    "$SH_EXEC"|"$SH_EXEC"/*) sh_gv_hit='' ;;
                esac
            fi
            [ -n "$sh_gv_hit" ] && continue
        fi
        printf '%s\n' "$sh_gv_n"
    done
    return 0
}

# sh_global_sandbox_dirs -> every directory this tree may own under the exec
# root that another installer writes into, one per line. The list is a FUNCTION
# so a sandbox added later is named once and the three callers cannot disagree:
#
#   sh_global_is_sandbox   is this path one of them
#   sh_global_write_dispatch   put them on PATH for a fresh shell
#   sh_env_body (via the toolchain fragments)   the same order, at install time
#
# The names are relative to the exec root so the dispatcher bakes none of them:
# it prepends "$SANDHOME_EXEC/$rel", which is correct even when the exec root
# moves. Each one is a bin directory whose LINKS MAY BE RELATIVE, which is the
# whole reason it is refused: a redirect symlink resolves such a link against
# the wrong directory (issue #138).
sh_global_sandbox_dirs() {
    printf '%s\n' 'uv-bin'
    printf '%s\n' 'npm-global/bin'
    printf '%s\n' 'go-bin'
    printf '%s\n' 'cargo-install/bin'
    return 0
}

# sh_global_is_sandbox DIR -> 0 when DIR is a directory this tree created to
# hold executables of its own, inside the exec root and outside the view bin.
# These are the directories other installers WRITE INTO: the npm prefix bin, the
# uv tool bin, the go bin, the cargo install root. A hook must never take one,
# and the reason is measured rather than tidy: `npm install -g cowsay` writes
#
#     bin/cowsay -> ../lib/node_modules/cowsay/cli.js
#
# a RELATIVE link, resolved against the link's real directory. While `bin` was
# the hook (a symlink to $SH_EXEC/global), that link resolved to
# $SH_EXEC/lib/node_modules/... , which does not exist, so every `npm i -g` CLI
# was a dangling symlink while npm reported success (issue #138). One list, one
# test, used by the candidate scan, the install path and the record reader, so
# the three cannot disagree about what is a sandbox.
sh_global_is_sandbox() {
    sh_gis_d=$1
    [ -n "$sh_gis_d" ] || return 1
    [ -n "${SH_EXEC:-}" ] || return 1
    case "$sh_gis_d" in
        "$SH_EXEC"/*) ;;
        *) return 1 ;;
    esac
    # The view bin is not a sandbox: it holds this tree's links, which the hook
    # re-exposes, and a hook there would shadow the binary with itself.
    if [ -n "${SH_EXEC_BIN:-}" ]; then
        case "$sh_gis_d" in
            "$SH_EXEC_BIN"|"$SH_EXEC_BIN"/*) return 1 ;;
        esac
    fi
    # The list is consulted as a WORD, not as a prefix: a sandbox is a bin
    # directory, and `$SH_EXEC/npm-global/lib` is data that belongs to the
    # prefix, not a directory anything writes executables into. A prefix test
    # would refuse it, and then the hook could take the prefix's own lib
    # directory and strand a different set of relative links.
    for sh_gis_rel in $(sh_global_sandbox_dirs); do
        [ "$sh_gis_d" = "$SH_EXEC/$sh_gis_rel" ] && return 0
    done
    return 1
}

# sh_global_sandbox_names -> every executable the sandbox bin directories hold,
# one per line, basename only. These are the CLIs an operator installs AFTER
# the setup (`npm install -g`, `uv tool install`, `go install`, `cargo install`),
# and the hook is the only thing that makes a tool reachable in a shell that
# sourced nothing, so they are exposed through it.
#
# # STOP: THE LIST IS READ FROM DISK, NOT RECORDED, AND THAT IS THE POINT. It
# changes every time an operator installs something, so a recorded list would
# be stale the moment it was written and the only repair would be a manual
# `sandhome global` after every npm install. The directories are scanned at
# install time instead, so a refresh picks up what is there now, and the names
# are the basenames because that is what PATH resolves.
#
# The cost is bounded and named: one symlink per installed CLI in each hook
# directory, and the scan is bounded by the directories themselves (a prefix
# with a thousand CLIs is a thousand links, which is what a shell that had
# sourced env.sh would have searched anyway). A name that is NOT executable is
# skipped, so a half-written link from an interrupted install is not exposed.
sh_global_sandbox_names() {
    sh_gsn_exec=${SH_EXEC:-}
    [ -n "$sh_gsn_exec" ] || return 0
    sh_gsn_seen=' '
    for sh_gsn_rel in $(sh_global_sandbox_dirs); do
        sh_gsn_dir=$sh_gsn_exec/$sh_gsn_rel
        [ -d "$sh_gsn_dir" ] || continue
        for sh_gsn_f in "$sh_gsn_dir"/*; do
            [ -e "$sh_gsn_f" ] || [ -L "$sh_gsn_f" ] || continue
            [ -x "$sh_gsn_f" ] || continue
            sh_gsn_n=${sh_gsn_f##*/}
            case "$sh_gsn_seen" in
                *" $sh_gsn_n "*) continue ;;
            esac
            sh_gsn_seen="$sh_gsn_seen$sh_gsn_n "
            printf '%s\n' "$sh_gsn_n"
        done
    done
    unset sh_gsn_exec sh_gsn_seen sh_gsn_rel sh_gsn_dir sh_gsn_f sh_gsn_n
    return 0
}

# sh_global_is_onpath_dir DIR -> 0 when DIR is one this tree put on PATH, so a
# shell that sourced nothing cannot be served from it and the hook must not be
# written there (issue #185).
#
# THE MARK IS THE DIRECTORY, NOT THE ROOT. A first attempt marked the exec root
# and read the mark as "any child of it", which refused every neutral directory
# under the exec root, and tests/global.sh keeps $SH_EXEC/plain-bin a candidate
# for exactly this reason: a hook there is the only thing that can serve a
# shell that has not read the environment. So the mark is a marker FILE INSIDE
# each directory that goes on PATH, named by the directory itself, and the
# test is for that file and not for the parent.
#
# THE MARKER IS A LIST, NOT A FLAG. A single flag at the root would again mean
# a list maintained by hand, which is what went wrong before: $SANDHOME_EXEC/
# cargo-wrap was created after the skip list was written and was taken by
# mistake. The list is written next to the prepend that puts the directory on
# PATH, so a directory this tree invents is marked by construction, and
# sh_env_mark_onpath is the one function that writes one, so the writer and the
# reader cannot disagree.
#
# The reader is given the list rather than asked to re-derive it, because the
# same reasoning sh_global_hook_names already follows (issue #138): both change
# without this tree running, and a record is only as current as the last run.
sh_global_is_onpath_dir() {
    [ -n "$1" ] || return 1
    case "$1" in
        */*) ;;
        *) return 1 ;;
    esac
    [ -e "$1/.sandhome-on-path" ] && return 0
    # # STOP: A DIRECTORY THE TREE CANNOT MARK IS STILL REFUSED, AND THE MARK
    # IS NOT THE ONLY RECORD. A read-only or otherwise unwritable exec root
    # cannot take the marker file, and a directory this tree put on PATH that
    # then becomes a hook candidate is the defect #185 is about, so a mark that
    # could not be written has to leave a trace somewhere writable. The roots
    # themselves are refused by name two functions up, and the exec bin is one
    # of them, so the common case is already safe; this covers a directory
    # under the exec root that is NOT one of the named ones, which is exactly
    # the shape that broke.
    sh_gpd_root=${1%/*}
    case "$sh_gpd_root" in
        ''|.) sh_gpd_root=$1 ;;
    esac
    case "$sh_gpd_root" in
        "$SH_EXEC"|"$SH_EXEC"/*) ;;
        *) return 1 ;;
    esac
    [ -r "$SH_HOME/on-path.dirs" ] || return 1
    while IFS= read -r sh_gpd_l || [ -n "$sh_gpd_l" ]; do
        [ "$sh_gpd_l" = "$1" ] && return 0
    done < "$SH_HOME/on-path.dirs" 2>/dev/null
    return 1
}

# sh_global_skip_entry DIR -> 0 when DIR must never be taken as a hook
# candidate: the view itself (a hook inside it would shadow the binary with
# itself), the exec root (the hook belongs in `global/`, not at the top), the
# global dispatcher directory (a second hook there would collide with the first
# on every name), and every sandbox (issue #138, sh_global_is_sandbox).
sh_global_skip_entry() {
    [ -n "$1" ] || return 0
    sh_global_is_onpath_dir "$1" && return 0
    if [ -n "${SH_EXEC_BIN:-}" ]; then
        case "$1" in
            "$SH_EXEC_BIN"|"$SH_EXEC_BIN"/*) return 0 ;;
        esac
    fi
    if [ -n "${SH_EXEC:-}" ]; then
        case "$1" in
            "$SH_EXEC"|"$SH_EXEC/global") return 0 ;;
        esac
    fi
    # # STOP: A TOOLCHAIN VIEW BIN IS NOT A PATH ENTRY; A NEUTRAL DIRECTORY ON
    # THE EXEC ROOT STILL IS. The list refused $SH_EXEC_BIN and $SH_EXEC/global
    # and then everything else under the exec root was a candidate -- including
    # `$SH_EXEC/views/<name>/bin`, which is the SAME KIND of indirection as
    # $SH_EXEC_BIN: it is on PATH only because env.sh put it there, so a shell
    # that has not read the environment cannot be served by it. Measured on a
    # home that refuses execve, after the bootstrap (whose PATH already carried
    # the view bins, because sh_env_load ran first):
    #
    #   global record:  .../exec/views/node/bin  .../exec/views/python/bin
    #   clashes:        node npm npx uv uvx
    #   ls .../exec/views/python/bin/: .sandhome-dispatch, node -> .sandhome-dispatch,
    #     npm, npx, jq, rg, fd, AND the real uv/uvx ELF binaries beside them
    #   a sourced shell: command -v node -> .../exec/views/PYTHON/bin/node
    #
    # The hook wrote a dispatcher and node/npm/npx links into the python view,
    # under another view's names, and clashed with uv/uvx. It is the rule
    # sh_global_view_names already applies to NAMES ("a hit inside this tree is
    # not PATH will serve it"); this is the same rule for the DIRECTORIES the
    # hook is written into.
    #
    # The pattern is the view ROOT, not the whole exec root: `views` itself is
    # a directory this tree made to hold views, so nothing a consumer put there
    # is a PATH entry (tests/global.sh keeps `$SH_EXEC/plain-bin` a candidate,
    # which is the control that this must not become "everything is a skip").
    if [ -n "${SH_EXEC:-}" ]; then
        case "$1" in
            "$SH_EXEC"/views|"$SH_EXEC"/views/*) return 0 ;;
        esac
    fi
    # # STOP: A TOOLCHAIN-INTERNAL bin UNDER THE HOME IS THE SAME KIND OF
    # INDIRECTION (issue #195). The rust fragment prepends
    # $SANDHOME_HOME/toolchains/rust/cargo/bin ahead of the exec bin, so after
    # sh_env_load that directory is on PATH, writable and exec-capable and looks
    # like the best hook candidate on the machine. The hook was written into it
    # and the report read global=on:<...>/toolchains/rust/cargo/bin, which passes
    # the report's own probe (it puts the recorded directory on PATH) and serves
    # NOBODY: a non-login shell with the host PATH cannot reach the directory at
    # all, so every tool the hook advertised was invisible in exactly the shell
    # the hook exists for. Measured after a full setup:
    #   env -i PATH=/usr/local/bin:/usr/bin:/bin sh -c 'command -v deno' -> NOT FOUND
    # Every module may prepend its own bin under the toolchain root, and the
    # root is this tree's own store, not a PATH entry a consumer had before
    # setup, so the whole $SH_HOME/toolchains tree is refused. A neutral
    # directory under the HOME that this tree did not create is still a
    # candidate, which is the control that this must not become "everything
    # under HOME is a skip" (tests/global.sh keeps that case).
    if [ -n "${SH_HOME:-}" ]; then
        case "$1" in
            "$SH_HOME"/toolchains|"$SH_HOME"/toolchains/*) return 0 ;;
        esac
    fi
    sh_global_is_sandbox "$1" && return 0
    return 1
}

# sh_global_choose_dirs -> every `PATH` entry that can host the hook, one per
# line, PATH order, deduplicated, capped. Two passes so an already-working
# directory is always recorded before a directory that has to be redirected:
# a directory that runs binaries is never replaced by a symlink.
sh_global_choose_dirs() {
    sh_gcs_out=0
    sh_gcs_seen=' '
    # Pass 1: writable and runs a binary. Used in place.
    sh_gcs_rest=$PATH
    while [ -n "$sh_gcs_rest" ]; do
        case "$sh_gcs_rest" in
            *:*) sh_gcs_d=${sh_gcs_rest%%:*}; sh_gcs_rest=${sh_gcs_rest#*:} ;;
            *)   sh_gcs_d=$sh_gcs_rest; sh_gcs_rest='' ;;
        esac
        [ -n "$sh_gcs_d" ] || continue
        sh_global_skip_entry "$sh_gcs_d" && continue
        case "$sh_gcs_seen" in *" $sh_gcs_d "*) continue ;; esac
        if [ -d "$sh_gcs_d" ] && [ -w "$sh_gcs_d" ] && sh_exec_probe "$sh_gcs_d" 2>/dev/null; then
            sh_gcs_seen="$sh_gcs_seen$sh_gcs_d "
            printf '%s\n' "$sh_gcs_d"
            sh_gcs_out=$((sh_gcs_out + 1))
            [ "$sh_gcs_out" -ge "$SH_GI_MAX_DIRS" ] && return 0
        fi
    done
    # Pass 2: absent, empty, or dangling at its entry, with a writable parent.
    # Each of those can be replaced by a symlink into the exec root and put
    # back by `--remove`. A LIVE symlink is not taken (it points somewhere the
    # host chose), a NON-EMPTY directory is not taken (rmdir would fail and the
    # contents are not ours), and a regular file at the entry is not taken.
    sh_gcs_rest=$PATH
    while [ -n "$sh_gcs_rest" ]; do
        case "$sh_gcs_rest" in
            *:*) sh_gcs_d=${sh_gcs_rest%%:*}; sh_gcs_rest=${sh_gcs_rest#*:} ;;
            *)   sh_gcs_d=$sh_gcs_rest; sh_gcs_rest='' ;;
        esac
        [ -n "$sh_gcs_d" ] || continue
        sh_global_skip_entry "$sh_gcs_d" && continue
        case "$sh_gcs_seen" in *" $sh_gcs_d "*) continue ;; esac
        sh_gcs_parent=$(sh_dirname "$sh_gcs_d")
        case "$sh_gcs_parent" in ''|.|/) continue ;; esac
        [ -d "$sh_gcs_parent" ] && [ -w "$sh_gcs_parent" ] || continue
        sh_gcs_take=no
        if [ -L "$sh_gcs_d" ]; then
            # -e follows the link, so -L with !-e is a dangling entry: nothing
            # reachable is lost by replacing it, and `--remove` puts it back.
            [ -e "$sh_gcs_d" ] || sh_gcs_take=yes
        elif [ -e "$sh_gcs_d" ]; then
            if [ -d "$sh_gcs_d" ]; then
                sh_gcs_empty=1
                for sh_gcs_f in "$sh_gcs_d"/* "$sh_gcs_d"/.[!.]*; do
                    [ -e "$sh_gcs_f" ] || [ -L "$sh_gcs_f" ] || continue
                    sh_gcs_empty=0
                    break
                done
                [ "$sh_gcs_empty" = 1 ] && sh_gcs_take=yes
            fi
        else
            sh_gcs_take=yes
        fi
        if [ "$sh_gcs_take" = yes ]; then
            sh_gcs_seen="$sh_gcs_seen$sh_gcs_d "
            printf '%s\n' "$sh_gcs_d"
            sh_gcs_out=$((sh_gcs_out + 1))
            [ "$sh_gcs_out" -ge "$SH_GI_MAX_DIRS" ] && return 0
        fi
    done
    return 0
}

# sh_global_choose_dir -> the first qualifying entry, or nothing. The singular
# view of sh_global_choose_dirs, kept for callers and tests that ask for one.
# The read runs in the pipeline's own process, so this stays inside `set -u`
# without a heredoc and without an unquoted word split.
sh_global_choose_dir() {
    sh_global_choose_dirs | {
        IFS= read -r sh_gcd_l || sh_gcd_l=''
        printf '%s' "$sh_gcd_l"
    }
    return 0
}

# sh_global_write_dispatch FILE HOME VIEW -> write the dispatcher atomically.
# Keyed on `$0`, so one file serves every exposed name. The `loaded=` marker
# exists for `sh_global_probe`: it prints only after `env.sh` was sourced, and
# `exec=` carries the root `env.sh` set, so a probe that reads
# `loaded=yes exec=<path>` has proved the whole chain, not just file presence.
# `VIEW` is the baked exec bin, a fallback for a shell whose home lost env.sh
# while the view survived: a stale absolute path beats a dead command.
#
# # STOP: THE DISPATCHER PUTS THE PREFIX ON PATH, BECAUSE IT IS THE ONLY PATH A
# FRESH SHELL GETS. env.sh prepends the sandbox bin directories (the npm prefix
# bin, the uv tool bin, the go bin, the cargo install root), and a fresh shell
# reads env.sh only when a HOOKED COMMAND runs, which is after the shell already
# searched PATH. So every CLI an operator installs after the setup
# (`npm install -g`, `uv tool install`, `go install`, `cargo install`) is
# invisible to a fresh shell: measured, both before and after the issue #138
# fix, `command -v cowsay` in an `env -i` shell answered nothing while a
# sourced shell found it, and the whole promise of the hook ("a fresh shell
# needs to source nothing") was only true of the tools that shipped with the
# install. The dispatcher now prepends each sandbox bin it finds, which is the
# same list env.sh used, and it does so in ONE case statement so a new sandbox
# is named once.
#
# THE ORDER IS ENV.SH'S ORDER, because the prepend must not reverse it: each
# directory goes in front of the ones added so far, so the last prepended is
# the first on PATH. uv-bin is prepended after npm-global/bin, and PATH then
# reads views/... , uv-bin, npm-global/bin: exactly what env.sh produces. Adding
# the same directory twice is guarded, so PATH never grows on a nested run.
sh_global_write_dispatch() {
    sh_gwd_f=$1
    sh_gwd_tmp="$sh_gwd_f.tmp.$$"
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' '# sandhome global hook. Generated; refresh with `sandhome global`,'
        printf '%s\n' '# remove with `sandhome global --remove`.'
        printf '%s\n' '_sandhome_name=${0##*/}'
        printf '_sandhome_home=%s\n' "$(sh_sq_quote "$2")"
        printf '_sandhome_view=%s\n' "$(sh_sq_quote "$3")"
        printf '%s\n' '_sandhome_loaded=no'
        printf '%s\n' 'if [ -r "$_sandhome_home/env.sh" ]; then'
        printf '%s\n' '  . "$_sandhome_home/env.sh"'
        printf '%s\n' '  _sandhome_loaded=yes'
        printf '%s\n' 'fi'
        # # STOP: THE EGRESS VARIABLES ARE RE-APPLIED HERE, NOT ONLY IN env.SH
        # (issue #181). env.sh records the proxy configuration the installing
        # shell had, which covers every tree installed after this change. It
        # does not cover a tree installed before it, and the dispatcher is
        # rewritten on every install and repair anyway, so the same block is
        # emitted here and reads the same file. Two paths, one value, no drift:
        # the dispatcher sources env.sh first, so these are the values env.sh
        # decided on, not a second opinion.
        #
        # The reason it is not enough to rely on env.sh alone is the shape of
        # the hook: it loads the environment for the PROCESS it dispatches, and
        # a child cannot change its parent, so a shell that typed `npm install`
        # keeps an environment with no route out no matter what env.sh says.
        # Sourcing env.sh inside the dispatcher is what puts the variables in
        # that process. A fresh hook-only shell is the primary path this project
        # promises, and on a proxy-only host it reached no registry at all.
        printf '%s\n' 'if [ -r "$_sandhome_home/proxy.env" ]; then'
        printf '%s\n' '  . "$_sandhome_home/proxy.env"'
        printf '%s\n' 'fi'
        printf '%s\n' '# The toolchain sandbox bins, so a CLI installed after the setup is'
        printf '%s\n' '# reachable from a shell that sourced nothing. Same order as env.sh.'
        printf '%s\n' 'if [ -n "${SANDHOME_EXEC:-}" ]; then'
        # The list is written from sh_global_sandbox_dirs, REVERSED, because
        # each directory is prepended in turn and the last one prepended is the
        # first on PATH: the generated `for` walks the reversed list so PATH
        # reads exactly the order env.sh produces. env.sh prepends uv-bin after
        # npm-global/bin, so uv-bin must land last here.
        # The list is written from sh_global_sandbox_dirs, REVERSED, because
        # each directory is prepended in turn and the last one prepended is the
        # first on PATH: the generated `for` walks the reversed list so PATH
        # reads exactly the order env.sh produces. env.sh prepends uv-bin after
        # npm-global/bin, so uv-bin must land last here. The words are built
        # with the shell's own string work, because a `sed` in this generated
        # path is a silent failure: one wrong pattern and the dispatcher it
        # writes is `for x in \; do` - a file that fails to parse at every
        # shell start, which is exactly what the fresh-shell probe then reports
        # as a stale hook with no other clue.
        sh_gwd_words=''
        while IFS= read -r sh_gwd_line; do
            [ -n "$sh_gwd_line" ] || continue
            sh_gwd_words="$sh_gwd_line $sh_gwd_words"
        done <<_sh_gwd_end
$(sh_global_sandbox_dirs 2>/dev/null)
_sh_gwd_end
        # Each word is emitted as "$SANDHOME_EXEC/<rel>", the leading and the
        # trailing space removed by the two expansions: the string is built as
        # ' "$SANDHOME_EXEC/rel"' and the outer quotes are stripped once at each
        # end, which is why the final expansion is quoted inside a printf.
        sh_gwd_for=''
        for sh_gwd_rel in $sh_gwd_words; do
            if [ -z "$sh_gwd_for" ]; then
                sh_gwd_for='"$SANDHOME_EXEC/'"$sh_gwd_rel"'"'
            else
                sh_gwd_for="$sh_gwd_for"' "$SANDHOME_EXEC/'"$sh_gwd_rel"'"'
            fi
        done
        [ -n "$sh_gwd_for" ] || sh_gwd_for='"$SANDHOME_EXEC/.sandhome-none"'
        printf '  for _sandhome_sb in %s; do\n' "$sh_gwd_for"
        printf '%s\n' '    [ -d "$_sandhome_sb" ] || continue'
        printf '%s\n' '    case ":$PATH:" in'
        printf '%s\n' '      *":$_sandhome_sb:"*) continue ;;'
        printf '%s\n' '    esac'
        printf '%s\n' '    PATH="$_sandhome_sb:$PATH"'
        printf '%s\n' '  done'
        printf '%s\n' '  unset _sandhome_sb'
        printf '%s\n' '  export PATH'
        printf '%s\n' 'fi'
        printf '%s\n' 'if [ "$_sandhome_name" = .sandhome-dispatch ]; then'
        printf '%s\n' '  printf "sandhome-dispatch loaded=%s exec=%s\n" "$_sandhome_loaded" "${SANDHOME_EXEC:-unset}"'
        printf '%s\n' '  exit 0'
        printf '%s\n' 'fi'
        cat <<'_sandhome_installer_end'
# # STOP: A CLI INSTALLED AFTER THE SETUP IS REACHABLE IN THE NEXT FRESH
# SHELL. The hook's names are a fixed list written by `sandhome global`, so
# `npm install -g cowsay` left cowsay in npm-global/bin but not in the hook,
# and a later `cowsay` was "command not found" until the operator remembered
# to run `sandhome global` (issue #142). When the name is an installer, run it
# as a CHILD (never exec: there is no "after an exec"), then expose every new
# executable in the sandbox bins as a hook link beside this script. The four
# sandboxes are the same ones env.sh prepends; a name already exposed is left
# alone, and a failure to link never changes the installer's exit status.
case "$_sandhome_name" in
  npm|npx|pnpm|yarn|corepack|go|cargo|rustup|uv|uvx|pip|pip3|pipx) _sandhome_install=yes ;;
  *) _sandhome_install=no ;;
esac
if [ "$_sandhome_install" = yes ]; then
  _sandhome_rc=127
  _sandhome_ran=no
  for _sandhome_p in "${SANDHOME_EXEC:-/nonexistent}/bin/$_sandhome_name" "${_sandhome_view:-/nonexistent}/$_sandhome_name"; do
    [ -x "$_sandhome_p" ] || continue
    "$_sandhome_p" "$@"
    _sandhome_rc=$?
    _sandhome_ran=yes
    break
  done
  if [ "$_sandhome_ran" = yes ] && [ -n "${SANDHOME_EXEC:-}" ]; then
    for _sandhome_sb in uv-bin npm-global/bin go-bin cargo-install/bin; do
      [ -d "$SANDHOME_EXEC/$_sandhome_sb" ] || continue
      for _sandhome_x in "$SANDHOME_EXEC/$_sandhome_sb"/*; do
        [ -x "$_sandhome_x" ] || continue
        _sandhome_b=${_sandhome_x##*/}
        [ -e "${0%/*}/$_sandhome_b" ] && continue
        ln -sf .sandhome-dispatch "${0%/*}/$_sandhome_b" 2>/dev/null || true
      done
    done
    unset _sandhome_sb _sandhome_x _sandhome_b
  fi
  [ "$_sandhome_ran" = yes ] && exit "$_sandhome_rc"
fi
_sandhome_installer_end
        printf '%s\n' 'if [ -n "${SANDHOME_EXEC:-}" ] && [ -x "$SANDHOME_EXEC/bin/$_sandhome_name" ]; then'
        printf '%s\n' '  exec "$SANDHOME_EXEC/bin/$_sandhome_name" "$@"'
        printf '%s\n' 'fi'
        printf '%s\n' 'if [ -n "$_sandhome_view" ] && [ -x "$_sandhome_view/$_sandhome_name" ]; then'
        printf '%s\n' '  exec "$_sandhome_view/$_sandhome_name" "$@"'
        printf '%s\n' 'fi'
        printf '%s\n' '# A tool the hook does not name, in a directory the hook just put on PATH.'
        printf '%s\n' 'if [ -n "${SANDHOME_EXEC:-}" ]; then'
        # # STOP: THIS LIST IS THE SAME VARIABLE AS THE PREPEND ABOVE, BECAUSE
        # A HAND-WRITTEN COPY OF IT WAS WRONG. It named npm-global/bin, uv-bin
        # and go-bin and omitted cargo-install/bin, while the linker above it
        # links every directory -- so a `cargo install` CLI was linked into
        # the hook, `command -v` found it, and running it answered "not
        # installed; reinstall the CLI": the hook exposed a name it could not
        # resolve (issue #141's class, still live in the #142 feature).
        # Measured with a CLI in each of the four sandbox directories.
        # sh_gwd_for is built above from sh_global_sandbox_dirs, the one
        # function both halves call, so a fifth sandbox directory cannot be
        # added to one place and missed in the other. It is REVERSED to match
        # the resolution order above (npm-global/bin before uv-bin, the order
        # env.sh prepends), because a name in two prefixes must resolve to
        # the same one either way.
        printf '  for _sandhome_sb in %s; do\n' "$sh_gwd_for"
        printf '%s\n' '    if [ -x "$_sandhome_sb/$_sandhome_name" ]; then'
        printf '%s\n' '      exec "$_sandhome_sb/$_sandhome_name" "$@"'
        printf '%s\n' '    fi'
        printf '%s\n' '  done'
        printf '%s\n' '  unset _sandhome_sb'
        printf '%s\n' 'fi'
        # # STOP: THE REMEDY MUST FIT THE NAME. This said `sandhome install
        # $_sandhome_name` for every name, but the names the hook exposes are
        # not all toolchains: a `go install`ed CLI whose payload `gc` removed
        # got told to run `sandhome install stringer`, which answers "unknown
        # toolchain" and then still rewrote env.sh and the hook before exiting
        # 1 (issue #141). The message now names both real paths: reinstall the
        # CLI and refresh the hook, or install the toolchain by name.
        printf '%s\n' 'printf "%s\n" "sandhome: $_sandhome_name is not installed; run: reinstall the CLI then '\''sandhome global'\'', or, if it is a toolchain, '\''sandhome install $_sandhome_name'\''" >&2'
        printf '%s\n' 'exit 127'
    } > "$sh_gwd_tmp" 2>/dev/null || { rm -f "$sh_gwd_tmp" 2>/dev/null; return 1; }
    chmod 0755 "$sh_gwd_tmp" 2>/dev/null || true
    mv -f "$sh_gwd_tmp" "$sh_gwd_f" 2>/dev/null || { rm -f "$sh_gwd_tmp" 2>/dev/null; return 1; }
    return 0
}

# sh_global_old_field BASE DIR FIELD -> FIELD as recorded for DIR in an
# earlier record, or nothing. Looked up BY DIRECTORY, never by slot number: a
# refresh re-plans in the current PATH's order, so slot i of the old record is
# not slot i of the new one whenever an entry dropped off PATH.
sh_global_old_field() {
    sh_gof_base=$1
    sh_gof_want=$2
    sh_gof_field=$3
    sh_gof_out=''
    [ -r "$sh_gof_base/dirs" ] || { printf ''; return 0; }
    sh_gof_i=0
    while IFS= read -r sh_gof_d || [ -n "$sh_gof_d" ]; do
        [ -n "$sh_gof_d" ] || continue
        if [ "$sh_gof_d" = "$sh_gof_want" ]; then
            if [ -r "$sh_gof_base/d/$sh_gof_i/$sh_gof_field" ]; then
                IFS= read -r sh_gof_out < "$sh_gof_base/d/$sh_gof_i/$sh_gof_field" || sh_gof_out=''
            fi
            break
        fi
        sh_gof_i=$((sh_gof_i + 1))
    done < "$sh_gof_base/dirs"
    printf '%s' "$sh_gof_out"
}

# sh_global_old_orig BASE DIR -> the orig recorded for DIR in an earlier
# record, or nothing. Re-installing a hook we already own must not record our
# own symlink as the original state, or `--remove` would "restore" our link.
sh_global_old_orig() {
    sh_global_old_field "$1" "$2" orig
}

# sh_global_relocate_record OLDBASE DIR -> undo a hook an EARLIER install
# recorded inside a directory the sandbox list now refuses, and rescue what the
# redirect stranded. It runs on the refresh path, once per refused recorded
# entry, before the new plan is committed (issue #138).
#
# WHAT IT TOUCHES, PRECISELY. Only a directory that is (a) recorded, (b) now a
# sandbox, and (c) OUR OWN hook: a symlink pointing at the directory this tree
# writes its dispatcher into. A directory the host owns that happens to sit
# under the exec root is left exactly as it was, and a recorded directory that
# is no longer ours is reported and left alone rather than deleted.
#
# WHY THE RESCUE IS NEEDED. `npm install -g cowsay` writes
#     bin/cowsay -> ../lib/node_modules/cowsay/cli.js
# a RELATIVE link, which the kernel resolves against the link's REAL directory.
# While `bin` was a symlink to $SH_EXEC/global, that resolved to
# $SH_EXEC/lib/node_modules/... , which does not exist, so the CLI was dead
# while npm reported success. Restoring the directory and moving the stranded
# link back is the only thing that makes an install that already happened work;
# refusing the directory for the future would strand every CLI already there.
# The rescue is deliberately narrow: only a link that is currently DANGLING, in
# the dispatcher directory, that is not one of ours, and that is RELATIVE. A
# dangling hook link and a dangling host link are both left where they are,
# because moving either is a change this function cannot justify.
sh_global_relocate_record() {
    sh_grr_old=$1
    sh_grr_dir=$2
    [ -n "$sh_grr_old" ] && [ -n "$sh_grr_dir" ] || return 0
    [ -r "$sh_grr_old/dirs" ] || return 0
    sh_grr_i=0
    sh_grr_link=''
    sh_grr_orig=''
    sh_grr_target=''
    while IFS= read -r sh_grr_d || [ -n "$sh_grr_d" ]; do
        [ -n "$sh_grr_d" ] || continue
        if [ "$sh_grr_d" = "$sh_grr_dir" ]; then
            # NOT `A && read || C`: a read that succeeds with an empty value
            # would fall through to C anyway, and a read that fails must not
            # leave a stale variable from an earlier slot. Each field is read
            # only when its file exists, and the variable is cleared first.
            sh_grr_link=''; sh_grr_orig=''; sh_grr_target=''
            if [ -r "$sh_grr_old/d/$sh_grr_i/link" ]; then
                IFS= read -r sh_grr_link < "$sh_grr_old/d/$sh_grr_i/link" || sh_grr_link=''
            fi
            if [ -r "$sh_grr_old/d/$sh_grr_i/orig" ]; then
                IFS= read -r sh_grr_orig < "$sh_grr_old/d/$sh_grr_i/orig" || sh_grr_orig=''
            fi
            if [ -r "$sh_grr_old/d/$sh_grr_i/target" ]; then
                IFS= read -r sh_grr_target < "$sh_grr_old/d/$sh_grr_i/target" || sh_grr_target=''
            fi
            break
        fi
        sh_grr_i=$((sh_grr_i + 1))
    done < "$sh_grr_old/dirs"
    # # STOP: A HOOK WRITTEN IN PLACE INTO A DIRECTORY THE PLAN NOW REFUSES IS
    # STILL OURS TO REMOVE. The relocate path only handled a directory that had
    # been replaced by a SYMLINK (link=yes), so a hook written directly into a
    # bin directory -- the shape an exec-capable exec root produces, which is
    # how `$SH_EXEC/views/node/bin` was taken (see sh_global_skip_entry) -- kept
    # its `.sandhome-dispatch` and its name links after the rule changed, and a
    # repair refreshed everything around it while leaving the shadow in place.
    # The test is narrow: the directory is ours only when it sits under
    # $SH_EXEC AND carries our own dispatcher, so a host directory that happens
    # to live under the exec root is still never touched.
    if [ -n "${SH_EXEC:-}" ] && [ -n "$sh_grr_dir" ] && \
       [ ! -L "$sh_grr_dir" ] && [ -d "$sh_grr_dir" ] && [ -x "$sh_grr_dir/.sandhome-dispatch" ]; then
        case "$sh_grr_dir" in
            "$SH_EXEC"/*) ;;
            *) return 0 ;;
        esac
        sh_grr_cleaned=0
        for sh_grr_f in "$sh_grr_dir"/* "$sh_grr_dir"/.[!.]*; do
            [ -L "$sh_grr_f" ] || continue
            sh_grr_b=${sh_grr_f##*/}
            [ "$sh_grr_b" = '.sandhome-dispatch' ] && continue
            sh_grr_t=$(readlink "$sh_grr_f" 2>/dev/null) || continue
            [ "$sh_grr_t" = '.sandhome-dispatch' ] || continue
            rm -f "$sh_grr_f" 2>/dev/null && sh_grr_cleaned=$((sh_grr_cleaned + 1))
        done
        rm -f "$sh_grr_dir/.sandhome-dispatch" 2>/dev/null || true
        sh_warn "$sh_grr_dir carried an earlier global hook written in place; the dispatcher and its $sh_grr_cleaned link(s) were removed (the directory is inside the exec root, where env.sh already puts it on PATH)"
        return 0
    fi
    [ "$sh_grr_link" = yes ] || return 0
    [ -n "${SH_EXEC:-}" ] || return 0
    # Ours, or nothing: the link must be the one this tree writes.
    [ -n "$sh_grr_target" ] && [ "$sh_grr_target" = "$SH_EXEC/global" ] || return 0
    [ -L "$sh_grr_dir" ] || return 0
    sh_grr_cur=$(readlink "$sh_grr_dir" 2>/dev/null) || sh_grr_cur=''
    [ "$sh_grr_cur" = "$sh_grr_target" ] || return 0
    [ -d "$sh_grr_target" ] || return 0
    sh_grr_moved=0
    rm -f "$sh_grr_dir" 2>/dev/null || true
    # The directory comes back in the state the record says it had. A bin
    # directory an installer writes into has to be a directory whatever the
    # record says, because an absent entry was only absent because the hook
    # took it and npm will write into it either way; a host symlink the record
    # kept is put back as that symlink.
    case "$sh_grr_orig" in
        link:*)
            if ! ln -s "${sh_grr_orig#link:}" "$sh_grr_dir" 2>/dev/null; then
                mkdir -p "$sh_grr_dir" 2>/dev/null || true
            fi ;;
        *) mkdir -p "$sh_grr_dir" 2>/dev/null || true ;;
    esac
    [ -d "$sh_grr_dir" ] || return 0
    # The rescue: our dispatcher's stranded links, and nothing else.
    for sh_grr_f in "$sh_grr_target"/* "$sh_grr_target"/.[!.]*; do
        [ -L "$sh_grr_f" ] || continue
        case "${sh_grr_f##*/}" in sandhome|.sandhome-dispatch) continue ;; esac
        sh_grr_t=$(readlink "$sh_grr_f" 2>/dev/null) || continue
        [ "$sh_grr_t" = '.sandhome-dispatch' ] && continue
        # Only a relative link, and only while it is dangling: an absolute one
        # (uv tool install) resolves from anywhere and was never stranded.
        case "$sh_grr_t" in /*) continue ;; esac
        [ -e "$sh_grr_f" ] && continue
        [ -e "$sh_grr_dir/${sh_grr_f##*/}" ] && continue
        if mv "$sh_grr_f" "$sh_grr_dir/${sh_grr_f##*/}" 2>/dev/null; then
            sh_grr_moved=$((sh_grr_moved + 1))
        fi
    done
    sh_warn "$sh_grr_dir was a toolchain bin directory taken by an earlier global hook; the hook was moved out and the directory restored$([ "$sh_grr_moved" -gt 0 ] && printf ' (%s stranded CLI link(s) rescued)' "$sh_grr_moved") (issue #138)"
    return 0
}

# sh_global_hook_names -> every name the hook exposes: the view's executables
# PLUS every executable the sandbox bin directories hold (the CLIs an operator
# installed after the setup), so `npm install -g cowsay` then `cowsay` works in
# a shell that sourced nothing. Both lists are read from disk, never from a
# record, because both change without this tree running (issue #138). A name in
# the view and a name in a prefix that share a basename is one hook entry
# either way, and the de-dupe keeps the count honest.
sh_global_hook_names() {
    sh_ghn_seen=' '
    for sh_ghn_n in $(sh_global_view_names; sh_global_sandbox_names); do
        [ -n "$sh_ghn_n" ] || continue
        case "$sh_ghn_seen" in
            *" $sh_ghn_n "*) continue ;;
        esac
        sh_ghn_seen="$sh_ghn_seen$sh_ghn_n "
        printf '%s\n' "$sh_ghn_n"
    done
    return 0
}

# sh_global_install_one DIR IDX TMP OLDBASE -> install or refresh the hook at
# one PATH entry. IDX is the record slot (0-based, successes only), TMP the
# fresh record being built, OLDBASE the previous record (for orig carry-over).
# Returns 0 when the entry now carries the hook, 1 when it must be skipped.
# A skip is never fatal: the scan took other entries too, and a host layout is
# a fact, not an error.
sh_global_install_one() {
    sh_gio_dir=$1
    sh_gio_i=$2
    sh_gio_tmp=$3
    sh_gio_old=$4
    sh_gio_rec="$sh_gio_tmp/d/$sh_gio_i"
    mkdir -p "$sh_gio_rec" 2>/dev/null || return 1
    sh_gio_link=no
    sh_gio_orig=''
    sh_gio_target=''
    sh_gio_oldorig=''
    sh_gio_oldorig=$(sh_global_old_orig "$sh_gio_old" "$sh_gio_dir")

    if [ -L "$sh_gio_dir" ]; then
        sh_gio_cur=$(readlink "$sh_gio_dir" 2>/dev/null) || sh_gio_cur=''
        sh_gio_ours=no
        # Ours means it points at exactly the directory this install writes,
        # and that directory exists. The dispatcher file is deliberately not
        # part of the test: a link of ours whose dispatcher is missing (an
        # interrupted install, a partial wipe) must be refreshable, not
        # mistaken for a host symlink that install may never touch. A link
        # into any other path under the exec root stays the host's.
        case "$sh_gio_cur" in
            "$SH_EXEC/global")
                [ -d "$sh_gio_dir" ] && sh_gio_ours=yes ;;
        esac
        if [ "$sh_gio_ours" = yes ]; then
            # A hook of ours: refresh it in place, keeping the original state
            # recorded at first install.
            sh_gio_link=yes
            sh_gio_target=$sh_gio_cur
            sh_gio_orig=${sh_gio_oldorig:-absent}
        elif [ ! -e "$sh_gio_dir" ]; then
            # Dangling entry: nothing reachable is lost, replace and record
            # what was there so --remove can put it back.
            sh_gio_link=yes
            sh_gio_orig=${sh_gio_oldorig:-link:$sh_gio_cur}
        else
            # A live symlink the host chose. Never replaced.
            rmdir "$sh_gio_rec" 2>/dev/null || true
            return 1
        fi
    elif [ -e "$sh_gio_dir" ]; then
        if [ -d "$sh_gio_dir" ] && [ -w "$sh_gio_dir" ] && sh_exec_probe "$sh_gio_dir" 2>/dev/null; then
            # Case 1: runs binaries, write in place.
            sh_gio_target=$sh_gio_dir
            sh_gio_orig=${sh_gio_oldorig:-dir}
        elif [ -d "$sh_gio_dir" ]; then
            # On a root that refuses execve: only an empty directory may be
            # replaced, and only when the parent is writable.
            sh_gio_parent=$(sh_dirname "$sh_gio_dir")
            case "$sh_gio_parent" in ''|.|/) rmdir "$sh_gio_rec" 2>/dev/null; return 1 ;; esac
            [ -d "$sh_gio_parent" ] && [ -w "$sh_gio_parent" ] || { rmdir "$sh_gio_rec" 2>/dev/null; return 1; }
            sh_gio_empty=1
            for sh_gio_f in "$sh_gio_dir"/* "$sh_gio_dir"/.[!.]*; do
                [ -e "$sh_gio_f" ] || [ -L "$sh_gio_f" ] || continue
                sh_gio_empty=0
                break
            done
            [ "$sh_gio_empty" = 1 ] || { rmdir "$sh_gio_rec" 2>/dev/null; return 1; }
            sh_gio_orig=${sh_gio_oldorig:-dir}
            rmdir "$sh_gio_dir" 2>/dev/null || { rmdir "$sh_gio_rec" 2>/dev/null; return 1; }
            sh_gio_link=yes
        else
            # A regular file at the entry. Never clobbered.
            rmdir "$sh_gio_rec" 2>/dev/null || true
            return 1
        fi
    else
        # Absent entry with a writable parent.
        sh_gio_parent=$(sh_dirname "$sh_gio_dir")
        case "$sh_gio_parent" in ''|.|/) rmdir "$sh_gio_rec" 2>/dev/null; return 1 ;; esac
        [ -d "$sh_gio_parent" ] && [ -w "$sh_gio_parent" ] || { rmdir "$sh_gio_rec" 2>/dev/null; return 1; }
        sh_gio_orig=${sh_gio_oldorig:-absent}
        sh_gio_link=yes
    fi

    if [ "$sh_gio_link" = yes ]; then
        sh_gio_target="$SH_EXEC/global"
        mkdir -p "$sh_gio_target" 2>/dev/null || { rmdir "$sh_gio_rec" 2>/dev/null; return 1; }
        if ! sh_exec_probe "$sh_gio_target" 2>/dev/null; then
            rmdir "$sh_gio_rec" 2>/dev/null || true
            return 1
        fi
        if ! ln -sfn "$sh_gio_target" "$sh_gio_dir" 2>/dev/null; then
            rmdir "$sh_gio_rec" 2>/dev/null || true
            return 1
        fi
    else
        if ! sh_exec_probe "$sh_gio_target" 2>/dev/null; then
            rmdir "$sh_gio_rec" 2>/dev/null || true
            return 1
        fi
    fi

    if ! sh_global_write_dispatch "$sh_gio_target/.sandhome-dispatch" "$SH_HOME" "${SH_EXEC_BIN:-}"; then
        sh_warn "could not write the global dispatcher under $sh_gio_target; skipping $sh_gio_dir"
        rmdir "$sh_gio_rec" 2>/dev/null || true
        return 1
    fi

    # The command itself is copied, not dispatched: it must work with no
    # environment at all, and the baked copy already does. State machine for
    # $target/sandhome: absent -> copy; a symlink -> kept unless it dangles;
    # a real file -> our own previous copy (old record says cmd=yes) is
    # refreshed, anything else is a host file and is recorded as a clash.
    # Overwriting a host file is not an option.
    sh_gio_cmd=no
    sh_gio_dst="$sh_gio_target/sandhome"
    sh_gio_oldcmd=''
    sh_gio_oldcmd=$(sh_global_old_field "$sh_gio_old" "$sh_gio_dir" cmd)
    if [ -L "$sh_gio_dst" ]; then
        if [ ! -e "$sh_gio_dst" ]; then
            rm -f "$sh_gio_dst" 2>/dev/null || true
            if [ -r "$SH_EXEC_BIN/sandhome" ] && cp -f "$SH_EXEC_BIN/sandhome" "$sh_gio_dst" 2>/dev/null; then
                chmod 0755 "$sh_gio_dst" 2>/dev/null || true
                sh_gio_cmd=yes
            fi
        else
            printf 'sandhome\n' >> "$sh_gio_tmp/clashes.part" 2>/dev/null || true
        fi
    elif [ -e "$sh_gio_dst" ]; then
        if [ "$sh_gio_oldcmd" = yes ] || [ "$sh_gio_target" = "$SH_EXEC/global" ]; then
            if cp -f "$SH_EXEC_BIN/sandhome" "$sh_gio_dst" 2>/dev/null; then
                sh_gio_cmd=yes
            elif [ -f "$sh_gio_dst" ]; then
                sh_gio_cmd=yes
            fi
        else
            printf 'sandhome\n' >> "$sh_gio_tmp/clashes.part" 2>/dev/null || true
        fi
    else
        if [ -r "$SH_EXEC_BIN/sandhome" ] && cp -f "$SH_EXEC_BIN/sandhome" "$sh_gio_dst" 2>/dev/null; then
            chmod 0755 "$sh_gio_dst" 2>/dev/null || true
            sh_gio_cmd=yes
        fi
    fi

    # Stale names first: a tool removed from the view must lose its link, or
    # the dispatcher keeps answering for a binary that is gone.
    sh_gio_oldnames=''
    if [ -r "$sh_gio_old/names" ]; then
        sh_gio_oldnames=$(while IFS= read -r sh_gio_ol || [ -n "$sh_gio_ol" ]; do
            [ -n "$sh_gio_ol" ] && printf '%s ' "$sh_gio_ol"
        done < "$sh_gio_old/names")
    fi
    for sh_gio_o in $sh_gio_oldnames; do
        sh_gio_dst="$sh_gio_target/$sh_gio_o"
        if [ -L "$sh_gio_dst" ] && [ "$(readlink "$sh_gio_dst" 2>/dev/null)" = '.sandhome-dispatch' ]; then
            rm -f "$sh_gio_dst" 2>/dev/null || true
        fi
    done

    sh_global_hook_names | while IFS= read -r sh_gio_n || [ -n "$sh_gio_n" ]; do
        [ -n "$sh_gio_n" ] || continue
        sh_gio_dst="$sh_gio_target/$sh_gio_n"
        if [ -e "$sh_gio_dst" ] || [ -L "$sh_gio_dst" ]; then
            sh_gio_tgt=$(readlink "$sh_gio_dst" 2>/dev/null || printf '')
            [ "$sh_gio_tgt" = '.sandhome-dispatch' ] && continue
            # A host file already answers this name here. Left in place; the
            # clash line tells the operator why fresh shells see the host copy.
            printf '%s\n' "$sh_gio_n" >> "$sh_gio_tmp/clashes.part" 2>/dev/null || true
            continue
        fi
        ln -sfn '.sandhome-dispatch' "$sh_gio_dst" 2>/dev/null || \
            sh_warn "could not link $sh_gio_n into $sh_gio_dir"
    done

    printf '%s\n' "$sh_gio_dir" >> "$sh_gio_tmp/dirs" 2>/dev/null || { rmdir "$sh_gio_rec" 2>/dev/null; return 1; }
    printf '%s\n' "$sh_gio_dir" > "$sh_gio_rec/dir" 2>/dev/null || true
    printf '%s\n' "$sh_gio_link" > "$sh_gio_rec/link" 2>/dev/null || true
    printf '%s\n' "$sh_gio_orig" > "$sh_gio_rec/orig" 2>/dev/null || true
    printf '%s\n' "$sh_gio_cmd" > "$sh_gio_rec/cmd" 2>/dev/null || true
    printf '%s\n' "$sh_gio_target" > "$sh_gio_rec/target" 2>/dev/null || true
    return 0
}

# sh_global_install -> install or refresh the hook in every qualifying PATH
# entry. Returns 0 whether or not a candidate existed: no candidate is a fact
# about the host, not a failure to fix. A refresh never drops a recorded
# directory just because THIS shell's PATH did not carry it: recorded entries
# are re-planned, repaired in place, and only leave the record when they can no
# longer be made to work.
sh_global_install() {
    # The switch has to live here, not only in the bootstrap: `sandhome install`
    # and `sandhome repair` call this directly, and a suite that set
    # SANDHOME_GLOBAL=0 still had the hook written into the machine's real PATH
    # by those two commands (found by consuming the v1 hook, issue #127).
    case "${SANDHOME_GLOBAL:-}" in
        0|no|off|none) return 0 ;;
    esac
    if [ "${SH_DRY_RUN:-0}" = 1 ]; then
        sh_step "would install the global hook (a PATH directory that loads the environment)"
        return 0
    fi
    [ -n "${SH_HOME:-}" ] || return 0
    [ -n "${SH_EXEC:-}" ] || return 0
    [ -n "${SH_EXEC_BIN:-}" ] || return 0
    sh_gi_old="$(sh_global_state_dir)"
    sh_gi_tmp="$sh_gi_old.new.$$"
    rm -rf "$sh_gi_tmp" 2>/dev/null || true
    mkdir -p "$sh_gi_tmp/d" 2>/dev/null || {
        sh_warn "could not write the global hook record under $sh_gi_old; not installed"
        return 0
    }
    # Plan: every qualifying entry of THIS PATH, then every recorded entry a
    # different shell's PATH had taken (a refresh repairs those too).
    sh_global_choose_dirs > "$sh_gi_tmp/plan" 2>/dev/null || true
    if [ -r "$sh_gi_old/dirs" ]; then
        while IFS= read -r sh_gi_pd || [ -n "$sh_gi_pd" ]; do
            [ -n "$sh_gi_pd" ] || continue
            # # STOP: A DIRECTORY THE SANDBOX LIST NOW REFUSES IS REPAIRED ON THE
            # WAY OUT, NOT RE-PLANNED (issue #138). An earlier install took the
            # npm prefix bin as a hook directory, which made every `npm i -g`
            # CLI a dangling relative link. Leaving the old record alone would
            # keep the broken shape; re-planning it would fight the repair. It
            # is handed to sh_global_relocate_record, which moves our own
            # dispatcher out, restores the directory, and rescues the links the
            # redirect stranded. Only OUR hook is touched: a directory the host
            # owns that happens to sit under the exec root is left as it is.
            if sh_global_skip_entry "$sh_gi_pd"; then
                sh_global_relocate_record "$sh_gi_old" "$sh_gi_pd"
                continue
            fi
            sh_gi_dup=no
            while IFS= read -r sh_gi_pp || [ -n "$sh_gi_pp" ]; do
                [ "$sh_gi_pp" = "$sh_gi_pd" ] && { sh_gi_dup=yes; break; }
            done < "$sh_gi_tmp/plan"
            [ "$sh_gi_dup" = yes ] || printf '%s\n' "$sh_gi_pd" >> "$sh_gi_tmp/plan"
        done < "$sh_gi_old/dirs"
    fi
    if [ ! -s "$sh_gi_tmp/plan" ]; then
        rm -rf "$sh_gi_tmp" 2>/dev/null || true
        [ -s "$sh_gi_old/dirs" ] || sh_global_forget
        sh_step "no writable exec-capable directory on this PATH; the global hook is not installed (source entry.sh, or run a command as 'sandhome exec CMD')"
        return 0
    fi
    sh_gi_i=0
    sh_gi_ok=0
    while IFS= read -r sh_gi_dir || [ -n "$sh_gi_dir" ]; do
        [ -n "$sh_gi_dir" ] || continue
        if sh_global_install_one "$sh_gi_dir" "$sh_gi_i" "$sh_gi_tmp" "$sh_gi_old"; then
            sh_gi_i=$((sh_gi_i + 1))
            sh_gi_ok=$((sh_gi_ok + 1))
        fi
    done < "$sh_gi_tmp/plan"
    rm -f "$sh_gi_tmp/plan" 2>/dev/null || true
    if [ "$sh_gi_ok" -eq 0 ]; then
        rm -rf "$sh_gi_tmp" 2>/dev/null || true
        if [ -s "$sh_gi_old/dirs" ]; then
            sh_warn "the global hook could not be refreshed; the previous record is kept (run 'sandhome resume' or 'sandhome global' after checking the exec root)"
        else
            sh_step "no PATH entry on this host can carry the global hook; not installed (source entry.sh, or run a command as 'sandhome exec CMD')"
        fi
        return 0
    fi
    # The record: names actually exposed now, clashes found on the way, and
    # mirrors of the first entry so single-directory readers keep one answer.
    # The record is the union the hook actually installed, so `global --status`
    # and the readiness message count every name a fresh shell can reach, not
    # only the view's. Reading the view alone undercounted by exactly the CLIs
    # an operator installs after the setup, which is the case the hook exists
    # for (issue #138).
    sh_global_hook_names > "$sh_gi_tmp/names" 2>/dev/null || true
    if [ -f "$sh_gi_tmp/d/0/dir" ]; then
        cp -f "$sh_gi_tmp/d/0/dir" "$sh_gi_tmp/dir" 2>/dev/null || true
        cp -f "$sh_gi_tmp/d/0/link" "$sh_gi_tmp/link" 2>/dev/null || true
        cp -f "$sh_gi_tmp/d/0/cmd" "$sh_gi_tmp/command" 2>/dev/null || true
    fi
    if [ -f "$sh_gi_tmp/clashes.part" ]; then
        sh_gi_seen=' '
        : > "$sh_gi_tmp/clashes" 2>/dev/null || true
        while IFS= read -r sh_gi_c || [ -n "$sh_gi_c" ]; do
            [ -n "$sh_gi_c" ] || continue
            case "$sh_gi_seen" in *" $sh_gi_c "*) continue ;; esac
            sh_gi_seen="$sh_gi_seen$sh_gi_c "
            printf '%s\n' "$sh_gi_c" >> "$sh_gi_tmp/clashes"
        done < "$sh_gi_tmp/clashes.part"
        rm -f "$sh_gi_tmp/clashes.part" 2>/dev/null || true
    else
        : > "$sh_gi_tmp/clashes" 2>/dev/null || true
    fi
    rm -rf "$sh_gi_old" 2>/dev/null || true
    if ! mv "$sh_gi_tmp" "$sh_gi_old" 2>/dev/null; then
        sh_warn "could not commit the global hook record under $sh_gi_old"
        return 0
    fi
    # Verify from outside before claiming success: run every recorded
    # directory through a fresh `env -i` shell and require the dispatcher's
    # marker. A hook whose files landed but whose shell cannot answer is
    # reported, not advertised.
    sh_gi_verified=0
    sh_gi_broken=''
    sh_gi_recorded=0
    while IFS= read -r sh_gi_vd || [ -n "$sh_gi_vd" ]; do
        [ -n "$sh_gi_vd" ] || continue
        sh_gi_recorded=$((sh_gi_recorded + 1))
        if sh_global_probe "$sh_gi_vd"; then
            sh_gi_verified=$((sh_gi_verified + 1))
        else
            sh_gi_broken="$sh_gi_broken $sh_gi_vd"
        fi
    done < "$sh_gi_old/dirs"
    sh_gi_tools=0
    if [ -r "$sh_gi_old/names" ]; then
        while IFS= read -r sh_gi_tn || [ -n "$sh_gi_tn" ]; do
            [ -n "$sh_gi_tn" ] || continue
            sh_gi_tools=$((sh_gi_tools + 1))
        done < "$sh_gi_old/names"
    fi
    if [ "$sh_gi_verified" -eq 0 ]; then
        sh_warn "the global hook was written at $sh_gi_ok of $sh_gi_recorded planned director$( [ "$sh_gi_recorded" -eq 1 ] && printf y || printf ies ) but no fresh shell answered through it (run 'sandhome global --status')"
    else
        sh_step "installed the global hook at $sh_gi_verified of $sh_gi_recorded director$( [ "$sh_gi_recorded" -eq 1 ] && printf y || printf ies ), verified in a fresh shell ($sh_gi_tools commands; a fresh shell needs to source nothing)"
    fi
    for sh_gi_bd in $sh_gi_broken; do
        sh_warn "the global hook at $sh_gi_bd did not answer the fresh-shell probe (run 'sandhome global --status')"
    done
    return 0
}

# sh_global_probe DIR -> 0 when a fresh shell started through DIR loads the
# environment. This is the outside measurement: `env -i` with only PATH and
# HOME set, executing the dispatcher by its path through the entry, reading
# back the marker that appears only after env.sh sourced both roots. Bounded
# (SH_PROBE_TIMEOUT_SECS, default 5) so a wedged dispatcher cannot hang a
# report or a doctor run.
sh_global_probe() {
    sh_gp_dir=$1
    [ -n "$sh_gp_dir" ] || return 1
    [ -d "$sh_gp_dir" ] || return 1
    [ -x "$sh_gp_dir/.sandhome-dispatch" ] || return 1
    sh_gp_out=$(sh_run_bounded "${SH_PROBE_TIMEOUT_SECS:-5}" \
        env -i "PATH=$sh_gp_dir" "HOME=${HOME:-/nonexistent}" \
        "$sh_gp_dir/.sandhome-dispatch" 2>/dev/null)
    sh_gp_rc=$?
    [ "$sh_gp_rc" = 0 ] || return 1
    case "$sh_gp_out" in
        *'sandhome-dispatch loaded=yes exec=unset'|*'sandhome-dispatch loaded=no'*) return 1 ;;
        *'sandhome-dispatch loaded=yes exec='*) return 0 ;;
    esac
    return 1
}

# sh_global_report -> on:<first verified dir>, stale:<first recorded dir> or
# none, read from disk and PROBED, never from what an install once claimed.
sh_global_report() {
    sh_grp_first=''
    sh_grp_ok=''
    sh_grp_n=0
    sh_grp_f="$(sh_global_state_dir)/dirs"
    if [ -r "$sh_grp_f" ]; then
        while IFS= read -r sh_grp_d || [ -n "$sh_grp_d" ]; do
            [ -n "$sh_grp_d" ] || continue
            sh_grp_n=$((sh_grp_n + 1))
            [ -n "$sh_grp_first" ] || sh_grp_first=$sh_grp_d
            if [ -z "$sh_grp_ok" ] && sh_global_probe "$sh_grp_d"; then
                sh_grp_ok=$sh_grp_d
            fi
        done < "$sh_grp_f"
    fi
    if [ "$sh_grp_n" -eq 0 ]; then
        printf 'none'
    elif [ -n "$sh_grp_ok" ]; then
        printf 'on:%s' "$sh_grp_ok"
    else
        printf 'stale:%s' "$sh_grp_first"
    fi
    return 0
}

# sh_global_status -> the full record, one fact per line, for
# `sandhome global --status`. The first line is `global=` (the probe verdict);
# every other line carries its own key, so a reader that greps `^global=` gets
# exactly the verdict.
sh_global_status() {
    sh_gs_state=$(sh_global_report)
    printf 'global=%s\n' "$sh_gs_state"
    printf 'global_dir=%s\n' "$(sh_global_dir)"
    printf 'global_link=%s\n' "$(sh_global_read link)"
    printf 'global_command=%s\n' "$(sh_global_read command)"
    sh_gs_n=0
    sh_gs_ok=0
    sh_gs_bad=0
    sh_gs_f="$(sh_global_state_dir)/dirs"
    if [ -r "$sh_gs_f" ]; then
        while IFS= read -r sh_gs_d || [ -n "$sh_gs_d" ]; do
            [ -n "$sh_gs_d" ] || continue
            sh_gs_i=$sh_gs_n
            sh_gs_n=$((sh_gs_n + 1))
            sh_gs_link=$(sh_global_read "d/$sh_gs_i/link")
            if sh_global_probe "$sh_gs_d"; then
                sh_gs_ok=$((sh_gs_ok + 1))
                sh_gs_st=ok
            else
                sh_gs_bad=$((sh_gs_bad + 1))
                sh_gs_st=stale
            fi
            printf 'hook=%s state=%s link=%s\n' "$sh_gs_d" "$sh_gs_st" "$sh_gs_link"
        done < "$sh_gs_f"
    fi
    printf 'global_dirs=%s\n' "$sh_gs_n"
    printf 'global_ok=%s\n' "$sh_gs_ok"
    printf 'global_broken=%s\n' "$sh_gs_bad"
    sh_gs_tools=0
    sh_gs_list=''
    sh_gs_f="$(sh_global_state_dir)/names"
    if [ -r "$sh_gs_f" ]; then
        while IFS= read -r sh_gs_t || [ -n "$sh_gs_t" ]; do
            [ -n "$sh_gs_t" ] || continue
            sh_gs_tools=$((sh_gs_tools + 1))
            sh_gs_list="$sh_gs_list $sh_gs_t"
        done < "$sh_gs_f"
    fi
    printf 'global_tools=%s\n' "${sh_gs_list# }"
    sh_gs_clash=''
    sh_gs_list=''
    sh_gs_f="$(sh_global_state_dir)/clashes"
    if [ -r "$sh_gs_f" ]; then
        while IFS= read -r sh_gs_c || [ -n "$sh_gs_c" ]; do
            [ -n "$sh_gs_c" ] || continue
            sh_gs_list="$sh_gs_list $sh_gs_c"
        done < "$sh_gs_f"
    fi
    printf 'global_clashes=%s\n' "${sh_gs_list# }"
    return 0
}

# sh_global_remove -> undo what install wrote, in every recorded directory,
# and restore each PATH entry to the state install found. It never removes a
# file it did not create: a symlink must point at our dispatcher, the copied
# command is dropped only where this install copied it, and a PATH entry that
# the host has since replaced is left alone.
sh_global_remove() {
    sh_grr_base="$(sh_global_state_dir)"
    if [ ! -s "$sh_grr_base/dirs" ]; then
        sh_step "no global hook is recorded"
        sh_global_forget
        return 0
    fi
    sh_grr_i=0
    sh_grr_linked=no
    sh_grr_names=''
    if [ -r "$sh_grr_base/names" ]; then
        sh_grr_names=$(while IFS= read -r sh_grr_n || [ -n "$sh_grr_n" ]; do
            [ -n "$sh_grr_n" ] && printf '%s ' "$sh_grr_n"
        done < "$sh_grr_base/names")
    fi
    while IFS= read -r sh_grr_dir || [ -n "$sh_grr_dir" ]; do
        [ -n "$sh_grr_dir" ] || continue
        sh_grr_rec="$sh_grr_base/d/$sh_grr_i"
        sh_grr_i=$((sh_grr_i + 1))
        sh_grr_link=''
        sh_grr_orig=''
        sh_grr_cmd=''
        sh_grr_target=''
        [ -r "$sh_grr_rec/link" ] && IFS= read -r sh_grr_link < "$sh_grr_rec/link"
        [ -r "$sh_grr_rec/orig" ] && IFS= read -r sh_grr_orig < "$sh_grr_rec/orig"
        [ -r "$sh_grr_rec/cmd" ] && IFS= read -r sh_grr_cmd < "$sh_grr_rec/cmd"
        [ -r "$sh_grr_rec/target" ] && IFS= read -r sh_grr_target < "$sh_grr_rec/target"
        if [ -n "$sh_grr_target" ] && [ -d "$sh_grr_target" ]; then
            for sh_grr_n in $sh_grr_names; do
                sh_grr_f="$sh_grr_target/$sh_grr_n"
                if [ -L "$sh_grr_f" ] && [ "$(readlink "$sh_grr_f" 2>/dev/null)" = '.sandhome-dispatch' ]; then
                    rm -f "$sh_grr_f" 2>/dev/null || true
                fi
            done
            rm -f "$sh_grr_target/.sandhome-dispatch" 2>/dev/null || true
            if [ "$sh_grr_cmd" = yes ]; then
                rm -f "$sh_grr_target/sandhome" 2>/dev/null || true
            fi
        fi
        if [ "$sh_grr_link" = yes ]; then
            sh_grr_linked=yes
            # Only OUR symlink is removed: it must still point at the target
            # this install recorded (so a moved exec root does not strand our
            # old link) or under the current exec root. A link the host has
            # since replaced is the host's.
            if [ -L "$sh_grr_dir" ]; then
                sh_grr_cur=$(readlink "$sh_grr_dir" 2>/dev/null) || sh_grr_cur=''
                # Non-empty guard: a failed readlink must not match an empty
                # recorded target and rm a link this install never wrote.
                if [ -n "$sh_grr_cur" ]; then
                    case "$sh_grr_cur" in
                        "$sh_grr_target"|"$SH_EXEC"/*) rm -f "$sh_grr_dir" 2>/dev/null || true ;;
                    esac
                fi
            fi
            # Restore what install found: an empty directory that was there
            # comes back (a tool on this PATH may create files in it later),
            # a host link comes back, an absent entry stays absent.
            case "$sh_grr_orig" in
                dir) [ -d "$sh_grr_dir" ] || mkdir -p "$sh_grr_dir" 2>/dev/null || true ;;
                link:*)
                    if [ ! -e "$sh_grr_dir" ] && [ ! -L "$sh_grr_dir" ]; then
                        ln -s "${sh_grr_orig#link:}" "$sh_grr_dir" 2>/dev/null || true
                    fi ;;
                absent|'') ;;
            esac
        fi
    done < "$sh_grr_base/dirs"
    if [ "$sh_grr_linked" = yes ]; then
        rmdir "$SH_EXEC/global" 2>/dev/null || true
    fi
    sh_global_forget
    sh_step "removed the global hook (a fresh shell needs env.sh again)"
    return 0
}
