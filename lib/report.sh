#!/bin/sh
# report.sh - the report read from the machine, in text and in JSON. Sourced.
#
# NOTE: THE REPORT IS READ FROM THE MACHINE, NOT FROM WHAT WAS ASKED FOR. A line
# claiming a tool is present because an install command exited 0 is the class of
# claim this tree keeps finding to be false. Every line below probes.

SH_INSTALLED=''
SH_ADOPTED=''

sh_lead() { printf '%s' "${1# }"; }

# sh_report_egress -> how this machine reaches the network, read from the file
# the hook will source. One word plus the variable names, or `direct` when
# nothing is recorded, or `unknown` when the file cannot be read (issue #181).
#
# A report that answers this from its own process answers the wrong question:
# the shells this project documents are scrubbed, so this process has no proxy
# and the machine does. The distinction between `direct` and `unknown` is kept
# because they are different claims: `direct` means this machine really has no
# proxy and a direct route, and `unknown` means nobody wrote the file down, so
# nobody knows.
sh_report_egress() {
    sh_re_f=''
    [ -n "${SH_HOME:-}" ] && sh_re_f="$SH_HOME/proxy.env"
    [ -n "$sh_re_f" ] || { printf 'unknown'; return 0; }
    if [ ! -r "$sh_re_f" ]; then
        printf 'unknown'
        return 0
    fi
    sh_re_n=''
    while IFS= read -r sh_re_l || [ -n "$sh_re_l" ]; do
        case "$sh_re_l" in
            export\ *) sh_re_l=${sh_re_l#export } ;;
            *=*) ;;
            *) continue ;;
        esac
        sh_re_v=${sh_re_l%%=*}
        [ -n "$sh_re_v" ] || continue
        # The file names each variable twice, once assigned and once exported,
        # and the counter is a second name that means nothing to a reader. Both
        # are dropped here, so the line is the list of variables a tool will
        # actually be given.
        case "$sh_re_v" in
            SANDHOME_*) continue ;;
        esac
        # A name already listed is not listed twice: the two spellings of one
        # rule are two rows, and a duplicate row reads as two settings.
        case ",$sh_re_n," in
            *",$sh_re_v,"*) continue ;;
        esac
        sh_re_n="$sh_re_n${sh_re_n:+,}$sh_re_v"
    done < "$sh_re_f"
    if [ -z "$sh_re_n" ]; then
        printf 'direct'
        return 0
    fi
    printf 'proxy:%s' "$sh_re_n"
    return 0
}

# sh_toolchain_status NAME -> present|absent
sh_toolchain_status() {
    if sh_toolchain_probe "$1"; then
        printf 'present'
    else
        printf 'absent'
    fi
}

# sh_report_view -> launch, copy or mixed for this machine, read-only. The
# mode is a fact about the machine (split home plus a helper that probes
# here), not a memory of what installed it: SH_VIEW_MODE lives only in the
# installing process, so a fresh report would otherwise always say copy.
# sh_memexec_mode never builds, so the report changes nothing by asking.
#
# STOP: THE VIEWS ON DISK OUTRANK THE MACHINE MODE. A tree repaired under an
# explicit SANDHOME_VIEW_MODE=copy is real bytes while the machine still
# probes launch; saying `launch` there described the plan, not the tree
# (issue #113). Every installed tree whose bins are already linked is
# measured, and disagreement is reported as `mixed` rather than papered over.
sh_report_view() {
    sh_rv_mode=''
    if command -v sh_memexec_mode >/dev/null 2>&1; then
        sh_rv_mode=$(sh_memexec_mode 2>/dev/null) || sh_rv_mode=''
    fi
    [ -n "$sh_rv_mode" ] || sh_rv_mode=${SH_VIEW_MODE:-copy}
    if command -v sh_toolchain_view_measured >/dev/null 2>&1; then
        sh_rv_seen=''
        for sh_rv_t in $(sh_toolchain_available 2>/dev/null); do
            sh_rv_k=$(sh_toolchain_view_measured "$sh_rv_t" 2>/dev/null)
            case "$sh_rv_k" in
                mixed)
                    printf 'mixed'
                    return 0 ;;
                launch|copy)
                    if [ -z "$sh_rv_seen" ]; then
                        sh_rv_seen=$sh_rv_k
                    elif [ "$sh_rv_seen" != "$sh_rv_k" ]; then
                        printf 'mixed'
                        return 0
                    fi ;;
            esac
        done
        if [ -n "$sh_rv_seen" ]; then
            printf '%s' "$sh_rv_seen"
            return 0
        fi
    fi
    printf '%s' "$sh_rv_mode"
}

# sh_report_views_json -> a JSON object mapping each installed toolchain to
# its measured view kind (launch/copy/mixed/direct), or {} when nothing is
# installed. The global `view` field stays the summary for old readers; this
# is the breakdown the summary folds (issue #113). Only identifiers reach
# the object, so no escaping beyond the names themselves is needed.
sh_report_views_json() {
    sh_rvj_first=1
    printf '{'
    if command -v sh_toolchain_view_measured >/dev/null 2>&1; then
        for sh_rvj_t in $(sh_toolchain_available 2>/dev/null); do
            [ -d "$(sh_toolchain_root "$sh_rvj_t" 2>/dev/null)" ] || continue
            sh_rvj_k=$(sh_toolchain_view_measured "$sh_rvj_t" 2>/dev/null)
            [ -n "$sh_rvj_k" ] || continue
            if [ "$sh_rvj_first" = 1 ]; then
                sh_rvj_first=0
            else
                printf ','
            fi
            printf '"%s":"%s"' "$(sh_json_escape "$sh_rvj_t")" "$(sh_json_escape "$sh_rvj_k")"
        done
    fi
    printf '}'
}

# sh_report_memexec -> the one line sh_memexec_report prints, or `unknown`
# when the module is not loaded. Same guard as sh_report_view: drivers that
# source the report without memexec get a word, not a raw shell error.
sh_report_memexec() {
    if command -v sh_memexec_report >/dev/null 2>&1; then
        sh_memexec_report 2>/dev/null
    else
        printf 'unknown'
    fi
}

# sh_report_text -> the human report on stdout. Everything else is stderr.
#
# STOP: EVERY PROBE-DERIVED FIELD DEFAULTS BEFORE IT IS FORMATTED (issue #8).
# A probe that fails answers nothing, and an empty expansion under `set -u`
# aborts the report mid-object: the yabs defects behind this were an empty
# score producing malformed JSON and a parser error interleaved into a human
# table. Nothing here reads an unset variable, nothing interleaves a parser
# diagnostic into the value (those go to stderr), and the failures count is
# numeric or zero, so the object always parses.
sh_report_text() {
    printf 'os=%s\n'          "${SH_OS_ID:-unknown}"
    printf 'kernel=%s\n'      "${SH_KERNEL:-unknown}"
    printf 'arch=%s\n'        "${SH_ARCH:-unknown}"
    printf 'libc=%s\n'        "${SH_LIBC:-unknown}"
    printf 'wsl=%s\n'         "${SH_WSL:-unknown}"
    printf 'privilege=%s\n'   "${SH_PRIVILEGE:-none}"
    printf 'provider=%s\n'    "${SH_PROVIDER:-none}"
    printf 'pty=%s\n'         "${SH_PTY:-unknown}"
    printf 'passwd=%s\n'      "${SH_PASSWD:-unknown}"
    printf 'ptrace=%s\n'      "${SH_PTRACE:-unknown}"
    printf 'bind=%s\n'        "${SH_BIND:-unknown}"
    # The per-file cap an agent will hit either downloading or writing one big
    # file. `ulimit -f` is in 512-byte blocks; a number an agent can plan around
    # is more useful than one discovered by killing a build (issue #164).
    sh_rt_fsize=$(ulimit -f 2>/dev/null)
    case "$sh_rt_fsize" in
        ''|unlimited|*[!0-9]*) sh_rt_fsize=unlimited ;;
        *) sh_rt_fsize=$((sh_rt_fsize * 512)) ;;
    esac
    printf 'file_size_limit=%s\n' "$sh_rt_fsize"
    printf 'home=%s\n'        "${SH_HOME:-unknown}"
    printf 'home_exec=%s\n'   "${SH_HOME_EXEC:-unknown}"
    printf 'exec=%s\n'        "${SH_EXEC:-unknown}"
    printf 'exec_free_mb=%s\n' "$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)"
    # The judgement, not just the number. `exec_free_mb=36` is a fact an agent
    # has to interpret; `exec_space=low` is the conclusion, and a report whose
    # whole job is to be read at a glance should carry it.
    printf 'exec_space=%s\n' "$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)"
    printf 'max_exec_free_mb=%s\n' "$(sh_space_max_exec_free 2>/dev/null)"
    printf 'exec_ceiling=%s\n' "$(sh_space_ceiling 2>/dev/null)"
    # The invoking shell, measured so a harness that spawns a non-login shell
    # per tool call sees what it needs: whether this shell is a login shell,
    # whether env.sh is already on this shell's PATH, and the exact one-liner
    # to load it. The operator otherwise discovers the asymmetry themselves
    # (issue #122). `login_shell` reads `shopt -q login_shell` under bash and
    # falls back to "unknown" elsewhere, because POSIX sh has no portable
    # login test and guessing would be the wrong answer.
    sh_rt_login=unknown
    if [ -n "${BASH_VERSION:-}" ]; then
        if shopt -q login_shell 2>/dev/null; then sh_rt_login=yes; else sh_rt_login=no; fi
    elif [ -n "${ZSH_VERSION:-}" ]; then
        case "${options[login]:-}" in on) sh_rt_login=yes ;; off) sh_rt_login=no ;; esac
    fi
    sh_rt_onpath=no
    case ":${PATH:-}:" in *":${SH_EXEC_BIN:-}:") sh_rt_onpath=yes ;; esac
    printf 'login_shell=%s\n' "$sh_rt_login"
    printf 'env_on_path=%s\n' "$sh_rt_onpath"
    printf 'entry=%s\n' "${SH_HOME:-unknown}/entry.sh"
    # The global hook: whether a fresh shell finds the environment with no
    # sourcing. Read from disk, so a report run after the exec root moved says
    # `stale:` rather than repeating what an install once claimed (issue #127).
    printf 'global=%s\n' "$(sh_global_report 2>/dev/null)"
    # # STOP: THE EGRESS LINE IS READ FROM THE DISK, NOT FROM THIS PROCESS.
    # A report is what a consumer runs to find out what the machine is, and the
    # question "can this thing reach the network" is the first one after
    # "does it have a compiler". Printing the value from this process would
    # answer with whatever the caller happened to export, which is exactly the
    # value that is missing in the scrubbed shells the project documents
    # (issue #181). The file is what the hook will actually source, so the file
    # is what gets reported.
    printf 'egress=%s\n' "$(sh_report_egress 2>/dev/null)"
    printf 'installed=%s\n'   "$(sh_lead "${SH_INSTALLED:-}")"
    printf 'adopted=%s\n'     "$(sh_lead "${SH_ADOPTED:-}")"
    # # STOP: THIS LINE PROBES THE DISK. It printed $SH_SHIMS_BUILT, which is
    # "built by this run", and so was empty on a second run (the .so was
    # already there), on a dry run (nothing was compiled, by design) and under
    # `sandhome report` (which never calls the builder). The two fields below
    # are the two different facts a reader needs, and neither of them is the
    # third one: what is present, and what this machine needs and does not have.
    printf 'shims=%s\n'       "$(sh_lead "$(sh_shim_present 2>/dev/null)")"
    printf 'shims_missing=%s\n' "$(sh_lead "$(sh_shim_needed_missing 2>/dev/null)")"
    printf 'shims_built_this_run=%s\n' "$(sh_lead "${SH_SHIMS_BUILT:-}")"
    printf 'view=%s\n' "$(sh_report_view 2>/dev/null)"
    printf 'memexec=%s\n' "$(sh_report_memexec 2>/dev/null)"
    # Per-toolchain measured views: the breakdown the global `view` folds.
    # A mixed tree names which entries are which without a second command.
    if command -v sh_toolchain_view_measured >/dev/null 2>&1; then
        for sh_rt_vt in $(sh_toolchain_available 2>/dev/null); do
            [ -d "$(sh_toolchain_root "$sh_rt_vt" 2>/dev/null)" ] || continue
            sh_rt_vk=$(sh_toolchain_view_measured "$sh_rt_vt" 2>/dev/null)
            [ -n "$sh_rt_vk" ] || continue
            printf 'view.%s=%s\n' "$sh_rt_vt" "$sh_rt_vk"
        done
    fi
    for sh_rt_name in $(sh_toolchain_available 2>/dev/null); do
        # TEXT ONLY, on purpose (judge finding 8-A): the JSON object carries no
        # toolchain map. A version is free text from the tool itself, and this
        # report is a key=value line format, so a hostile version can at worst
        # add lines here; the JSON side only ever carries escaped identifiers
        # and counts, so it deliberately excludes the one field that cannot be
        # constrained. A consumer who wants versions reads the text report or
        # runs `sandhome toolchains`.
        printf 'toolchain.%s=%s\n' "$sh_rt_name" "$(sh_toolchain_version "$sh_rt_name" 2>/dev/null)"
    done
    sh_rt_fail=${SH_FAILURES:-0}
    case "$sh_rt_fail" in
        ''|*[!0-9]*) sh_rt_fail=0 ;;
    esac
    printf 'failures=%s\n' "$sh_rt_fail"
}

# sh_report_json -> one JSON object. Only identifiers, names and counts reach
# it; every free-text message went to stderr.
sh_report_json() {
    sh_rj_fail=${SH_FAILURES:-0}
    case "$sh_rj_fail" in
        ''|*[!0-9]*) sh_rj_fail=0 ;;
    esac
    printf '{'
    printf '"schema":"sandhome/1"'
    printf ',"os":"%s","kernel":"%s","arch":"%s","libc":"%s","wsl":"%s"' \
        "$(sh_json_escape "${SH_OS_ID:-unknown}")" "$(sh_json_escape "${SH_KERNEL:-unknown}")" \
        "$(sh_json_escape "${SH_ARCH:-unknown}")" "$(sh_json_escape "${SH_LIBC:-unknown}")" \
        "$(sh_json_escape "${SH_WSL:-unknown}")"
    printf ',"privilege":"%s","provider":"%s","pty":"%s","passwd":"%s","ptrace":"%s","bind":"%s"' \
        "$(sh_json_escape "${SH_PRIVILEGE:-none}")" "$(sh_json_escape "${SH_PROVIDER:-none}")" \
        "$(sh_json_escape "${SH_PTY:-unknown}")" "$(sh_json_escape "${SH_PASSWD:-unknown}")" \
        "$(sh_json_escape "${SH_PTRACE:-unknown}")" "$(sh_json_escape "${SH_BIND:-unknown}")"
    printf ',"home":"%s","home_exec":"%s","exec":"%s","exec_free_mb":"%s","exec_space":"%s","max_exec_free_mb":"%s","exec_ceiling":"%s"' \
        "$(sh_json_escape "${SH_HOME:-unknown}")" "$(sh_json_escape "${SH_HOME_EXEC:-unknown}")" \
        "$(sh_json_escape "${SH_EXEC:-unknown}")" "$(sh_json_escape "$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)")" \
        "$(sh_json_escape "$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)")" \
        "$(sh_json_escape "$(sh_space_max_exec_free 2>/dev/null)")" \
        "$(sh_json_escape "$(sh_space_ceiling 2>/dev/null)")"
    printf ',"installed":"%s","adopted":"%s","shims":"%s"' \
        "$(sh_json_escape "$(sh_lead "${SH_INSTALLED:-}")")" \
        "$(sh_json_escape "$(sh_lead "${SH_ADOPTED:-}")")" \
        "$(sh_json_escape "$(sh_lead "$(sh_shim_present 2>/dev/null)")")"
    sh_rj_login=unknown
    if [ -n "${BASH_VERSION:-}" ]; then
        if shopt -q login_shell 2>/dev/null; then sh_rj_login=yes; else sh_rj_login=no; fi
    fi
    sh_rj_onpath=no
    case ":${PATH:-}:" in *":${SH_EXEC_BIN:-}:") sh_rj_onpath=yes ;; esac
    printf ',"login_shell":"%s","env_on_path":"%s","entry":"%s","global":"%s"' \
        "$(sh_json_escape "$sh_rj_login")" "$(sh_json_escape "$sh_rj_onpath")" \
        "$(sh_json_escape "${SH_HOME:-unknown}/entry.sh")" \
        "$(sh_json_escape "$(sh_global_report 2>/dev/null)")"
    # # STOP: THE JSON CARRIES THE EGRESS STATE TOO, BECAUSE THE TEXT LINE IS
    # NOT THE WHOLE SURFACE. A harness reads `report --json` and not the prose,
    # and "can this machine reach a registry" is the question it cannot answer
    # from a process whose environment was scrubbed - which is every cold path
    # this project documents. Adding it only to the text would leave the
    # machine-readable answer missing on exactly the hosts that need it
    # (issue #181).
    printf ',"egress":"%s"' "$(sh_json_escape "$(sh_report_egress 2>/dev/null)")"
    printf ',"shims_missing":"%s","view":"%s","memexec":"%s"' \
        "$(sh_json_escape "$(sh_lead "$(sh_shim_needed_missing 2>/dev/null)")")" \
        "$(sh_json_escape "$(sh_report_view 2>/dev/null)")" \
        "$(sh_json_escape "$(sh_report_memexec 2>/dev/null)")"
    # The per-toolchain breakdown beside the summary: old readers keep
    # reading `view`, new readers read `views` to see which entry is which.
    if command -v sh_report_views_json >/dev/null 2>&1; then
        printf ',"views":%s' "$(sh_report_views_json 2>/dev/null || printf '{}')"
    fi
    # The fields an agent needs before writing its first file (issue #88):
    # whether the current directory runs binaries, where build output must
    # go, and what to do next. next_action reads the exec-space state only;
    # readiness itself is doctor's job, not the report's.
    sh_rj_wd=${PWD:-.}
    sh_rj_wd_noexec=no
    sh_exec_probe "$sh_rj_wd" 2>/dev/null || sh_rj_wd_noexec=yes
    sh_rj_space=$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)
    case "$sh_rj_space" in
        ok) sh_rj_next="build under ${SH_EXEC:-.}" ;;
        unknown) sh_rj_next="run 'sandhome space --probe': the exec root cannot be measured" ;;
        *) sh_rj_next="run 'sandhome gc', then re-run the setup with '--exec DIR' on a roomy exec-capable path" ;;
    esac
    printf ',"workdir":"%s","workdir_noexec":"%s","build_root":"%s","next_action":"%s"' \
        "$(sh_json_escape "$sh_rj_wd")" "$sh_rj_wd_noexec" \
        "$(sh_json_escape "${SH_EXEC:-unknown}")" "$(sh_json_escape "$sh_rj_next")"
    printf ',"failures":%s}\n' "$sh_rj_fail"
}

# sh_doctor -> probe the things a working sandhome must have and report. It
# never repairs; the bootstrap does that. It prints one line per invariant and
# ends with `doctor_failures=N`, and it EXITS NON-ZERO when N is not zero. It
# does not exit with N: an exit status is one byte, and a value above 125
# truncates, so a machine with 130 broken invariants would answer 5 and a caller
# that read the status as the count would under-report. The count is printed and
# the status is 0 or 1.
#
# NOTE: EVERY INVARIANT IS CHECKED, INCLUDING THE ONES THAT ARE OFF BY DEFAULT.
# The shim checks were guarded by `if [ "$SH_PTY" = no ]`: on a machine with a
# pty they are simply absent, which is right, but the check for a machine with
# a pty and no shim directory was never made, and the shim is only built when it
# is needed. A machine where the shim WAS needed and the build failed therefore
# showed a clean report. Every needed shim is now a hard invariant, and a
# shim that is present but was built for the wrong libc is named.
sh_doctor() {
    sh_doc_fail=0
    # # STOP: THE READINESS GATE'S SUBPROCESS PROBES NEED A HOME, AND ONLY IT
    # MAY SET ONE (issue #179). `env -i /tmp/bin/sandhome doctor` ran the deno
    # self-exec probe with no HOME and failed with "Could not resolve global
    # Deno cache directory", and npm with "uv_os_homedir returned ENOENT".
    # The default lives HERE and not in sh_env_load because every command calls
    # that, and a read-only command must create nothing: setting HOME for
    # `sandhome report` made its `go version` probe write telemetry under
    # $SANDHOME_EXEC (measured by tests/space.sh: "sandhome report creates
    # nothing" went from pass to fail). The gate is the caller that runs the
    # spawn probes, so the gate is where the scratch HOME belongs.
    sh_env_scratch_home
    # SH_DOCTOR_JSON=1 collects machine-readable members instead of prose:
    # each check appends "name":"got" to SH_DOCTOR_MEMBERS and each miss
    # appends its name to SH_DOCTOR_FAILED; the tail wraps the object.
    # Prose notes (workdir hints, restart hints) are human text: in JSON mode
    # they go to stderr, and their facts live in report --json fields instead.
    if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
        SH_DOCTOR_MEMBERS=''
        SH_DOCTOR_FAILED=''
        export SH_DOCTOR_MEMBERS SH_DOCTOR_FAILED
    fi
    sh_doctor_check() {
        sh_dc_name=$1
        sh_dc_got=$2
        sh_dc_want=$3
        if [ "$sh_dc_got" = "$sh_dc_want" ]; then
            if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
                SH_DOCTOR_MEMBERS="$SH_DOCTOR_MEMBERS,\"$sh_dc_name\":\"$(sh_json_escape "$sh_dc_got")\""
                export SH_DOCTOR_MEMBERS
            else
                printf 'ok   %s=%s\n' "$sh_dc_name" "$sh_dc_got"
            fi
        else
            if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
                SH_DOCTOR_MEMBERS="$SH_DOCTOR_MEMBERS,\"$sh_dc_name\":\"$(sh_json_escape "$sh_dc_got")\""
                SH_DOCTOR_FAILED="$SH_DOCTOR_FAILED,\"$sh_dc_name\""
                export SH_DOCTOR_MEMBERS SH_DOCTOR_FAILED
            else
                printf 'FAIL %s=%s (wanted %s)\n' "$sh_dc_name" "$sh_dc_got" "$sh_dc_want"
            fi
            sh_doc_fail=$((sh_doc_fail + 1))
        fi
    }
    sh_doctor_check home_writable "$(sh_dir_writable "$SH_HOME" && printf yes || printf no)" yes
    sh_doctor_check exec_writable "$(sh_dir_writable "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_runs "$(sh_exec_probe "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_on_path "$(case ":$PATH:" in *":$SH_EXEC_BIN:"*) printf yes ;; *) printf no ;; esac)" yes
    sh_doctor_check env_file "$([ -r "$SH_HOME/env.sh" ] && printf yes || printf no)" yes
    # # STOP: THE STANDARD CACHE ROOT IS A PLACE EXECUTABLES LAND. env.sh now
    # points XDG_CACHE_HOME at the exec root when the caller left it unset, so a
    # tool that downloads and runs something from there (worker-build's emsdk,
    # wasm-bindgen) works (issue #158). The gate writes a real file under the
    # effective cache root and EXECS it, because a writable directory that
    # refuses execve is the whole subject of this tree, and it also requires
    # env.sh to name the variable so the fragment cannot rot back to the home
    # default unnoticed. It is written for every root, not only a split one: the
    # probe answers the same question either way and costs one file.
    sh_doc_cache=${XDG_CACHE_HOME:-$SH_EXEC/cache}
    # A caller-set cache that refuses execve is the failure, not a reason to
    # check a different directory: the tools read the caller's value, so the
    # gate probes the effective root and fails loudly when it cannot run a
    # file there (issue #158). env.sh only defaults the variable when unset,
    # so a set-but-noexec value stays red until the caller unsets it or points
    # it at an exec-capable root.
    sh_doc_cache_decl=no
    sh_doc_rust_targets=''
    if [ -r "$SH_HOME/env.sh" ]; then
        while IFS= read -r sh_doc_cache_l || [ -n "$sh_doc_cache_l" ]; do
            case "$sh_doc_cache_l" in
                *XDG_CACHE_HOME=*) sh_doc_cache_decl=yes ;;
                SANDHOME_RUST_TARGETS=*)
                    sh_doc_rust_targets=${sh_doc_cache_l#SANDHOME_RUST_TARGETS=}
                    sh_doc_rust_targets=${sh_doc_rust_targets#\'}
                    sh_doc_rust_targets=${sh_doc_rust_targets%\'}
                    sh_doc_rust_targets=${sh_doc_rust_targets#\"}
                    sh_doc_rust_targets=${sh_doc_rust_targets%\"}
                    ;;
            esac
        done < "$SH_HOME/env.sh"
    fi
    sh_doc_cache_ok=no
    if [ "$sh_doc_cache_decl" = yes ] && mkdir -p "$sh_doc_cache" 2>/dev/null; then
        if sh_exec_probe "$sh_doc_cache" 2>/dev/null; then
            sh_doc_cache_ok=yes
        fi
    fi
    sh_doctor_check cache_dir_exec "$sh_doc_cache_ok" yes
    # # STOP: GNU tar READS TAR_OPTIONS, AND THE TREE SETS IT. A third-party
    # installer that shells out to `tar -xf` on an archive with a foreign uid
    # aborts with exit 2 when run as uid 0 without CAP_CHOWN (issue #162);
    # env.sh now exports TAR_OPTIONS=--no-same-owner as a guarded default so
    # those installers unpack as the caller without being patched. The gate
    # reads the declaration out of env.sh, not the live variable: doctor
    # itself runs without sourcing env.sh (the baked launcher carries only the
    # roots), while every installer the gate protects runs through the hook,
    # exec or a sourced shell, all of which apply env.sh. Gating the live
    # variable would red every sound home whose doctor was invoked directly.
    # A GNU tar is the only one that reads the variable; other tars are
    # exempt, and the tree's own fetches go through sh_tar either way.
    sh_doc_tar_decl=no
    if [ -r "$SH_HOME/env.sh" ]; then
        while IFS= read -r sh_doc_tar_l || [ -n "$sh_doc_tar_l" ]; do
            case "$sh_doc_tar_l" in
                *TAR_OPTIONS=*) sh_doc_tar_decl=yes ;;
            esac
        done < "$SH_HOME/env.sh"
    fi
    if tar --version 2>/dev/null | head -n 1 | grep -qi 'gnu'; then
        if [ "$sh_doc_tar_decl" = yes ]; then
            sh_doctor_check tar_no_same_owner yes yes
        else
            sh_doctor_check tar_no_same_owner "no; env.sh does not default TAR_OPTIONS to --no-same-owner, so a third-party tar -xf on a foreign-uid archive aborts with exit 2 (re-run the setup or repair to rewrite env.sh)" yes
        fi
    fi
    # # STOP: SOME TARGETS NEED A LINKER THAT IS NOT rustc'S OWN. Adding
    # wasm32-unknown-emscripten is necessary but not sufficient: the link runs
    # `emcc`, from a separate toolchain with its own EM_CONFIG, and without it
    # cargo dies with `linker 'emcc' not found`, which reads like a broken PATH
    # rather than a missing toolchain (issue #163). The gate names the state
    # only when the request actually asks for that target, so no other setup
    # pays for it.
    case " $sh_doc_rust_targets " in
        *wasm32-unknown-emscripten*|*wasm64-unknown-emscripten*)
            if sh_have emcc; then
                sh_doctor_check emscripten_linker yes yes
            else
                sh_doctor_check emscripten_linker \
                    "no; this target links with emcc: run sandhome install emscripten, then CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=emcc is set for you" yes
            fi ;;
    esac
    # The recorded root must be the root being judged. The plan re-ranks when
    # the recorded root is gone (a wiped tmpfs, a moved tree), which is right
    # for an install and wrong for a gate: doctor then answered about whatever
    # root it had re-picked while env.sh still named the missing one. Measured
    # on this tree, with the recorded root deleted after a bootstrap: doctor
    # silently judged a stale sibling root from an earlier run and printed
    # doctor_failures=0 about it, and nothing said the recorded root was gone.
    sh_doc_recorded=$(sh_space_recorded_exec 2>/dev/null)
    case "$sh_doc_recorded" in
        '') sh_doctor_check exec_root ok ok ;;
        *)
            if [ ! -d "$sh_doc_recorded" ]; then
                sh_doctor_check exec_root "recorded:$sh_doc_recorded is gone" 'present; run sandhome resume'
            elif [ "$sh_doc_recorded" != "$SH_EXEC" ]; then
                sh_doctor_check exec_root "recorded:$sh_doc_recorded judging:$SH_EXEC" 'present; run sandhome resume'
            else
                sh_doctor_check exec_root ok ok
            fi
            ;;
    esac
    # # A SPLIT THE CALLER ASKED FOR AND DID NOT GET IS AN INVARIANT. When
    # the exec root was explicitly named and differs from the home, every
    # installed payload must have its view on the exec root; a view collapsed
    # into the home means the next install aims hundreds of megabytes at the
    # root the caller named --exec to avoid (issue #149). Only a REAL payload
    # counts: an adopted toolchain leaves auxiliary data under the home (the
    # npm seed home/toolchains/node/npm that tc_node_ensure_npm fetches for
    # an adopted node) without any view, and that is by design, not a
    # collapse. The check runs only when the named root is writable and runs
    # files: a root that cannot be used is the plan's refusal, not this
    # gate's. The repair is the command that rebuilds views where the plan
    # says they belong.
    if [ "${SH_EXEC_CHOSEN_REASON:-}" = explicit ] && [ -n "${SH_EXEC:-}" ] && \
       [ "${SH_EXEC:-}" != "${SH_HOME:-}" ] && \
       sh_dir_writable "$SH_EXEC" 2>/dev/null && sh_exec_probe "$SH_EXEC" 2>/dev/null; then
        sh_doc_split_missing=''
        if [ -n "${SH_HOME_TOOLCHAINS:-}" ] && [ -d "$SH_HOME_TOOLCHAINS" ]; then
            for sh_doc_sd in "$SH_HOME_TOOLCHAINS"/*; do
                [ -d "$sh_doc_sd" ] || continue
                sh_doc_sn=${sh_doc_sd##*/}
                case "$sh_doc_sn" in .*|staging|tmp) continue ;; esac
                if command -v sh_toolchain_payload_present >/dev/null 2>&1; then
                    sh_toolchain_payload_present "$sh_doc_sn" 2>/dev/null || continue
                fi
                if [ ! -d "$SH_EXEC_VIEWS/$sh_doc_sn" ]; then
                    sh_doc_split_missing="$sh_doc_split_missing $sh_doc_sn"
                fi
            done
        fi
        sh_doc_split_missing=$(sh_lead "$sh_doc_split_missing")
        if [ -n "$sh_doc_split_missing" ]; then
            sh_doctor_check split_views "explicit:$SH_EXEC missing:$sh_doc_split_missing" 'views on the named exec root (repair: sandhome repair)'
        else
            sh_doctor_check split_views ok ok
        fi
        unset sh_doc_sd sh_doc_sn sh_doc_split_missing
    fi
    # The global hook is gated WHEN A RECORD EXISTS (issue #127). `sh_global_report`
    # does not repeat what an install once claimed: it runs each recorded
    # directory through a fresh `env -i` shell and reads back the dispatcher's
    # marker, so `stale:` means a hook that was installed and no longer answers
    # a fresh shell, which is exactly the #127 failure returning. `none` is a
    # host layout (nothing was recorded) and passes; the failure line names the
    # repair command through its `wanted` text.
    sh_doc_global=$(sh_global_report 2>/dev/null)
    # # EVERY ARM THAT NAMES A DIRECTORY IS CHECKED, NOT ONLY `on:`. A recorded
    # hook directory under the exec root is wrong whichever answer the probe
    # gave it: `on:` means it answers a fresh shell (the shadowing case) and
    # `stale:` means it does not answer any more, and both are a directory this
    # tree must not be installed into. Keying the check on `on:*` alone missed
    # the `stale:` half, measured by driving sh_doctor with a recorded view-bin
    # path whose dispatcher does not answer.
    sh_doc_hookdir=''
    case "$sh_doc_global" in
        on:*)    sh_doc_hookdir=${sh_doc_global#on:} ;;
        stale:*) sh_doc_hookdir=${sh_doc_global#stale:} ;;
    esac
    # # THE HOOK MAY LEGITIMATELY LIVE ON THE EXEC ROOT; IT MUST NOT LIVE IN A
    # DIRECTORY THIS TREE USES AS INDIRECTION. A `PATH` directory on the exec
    # root is a normal install target (the bootstrap puts the hook in
    # `$SH_EXEC/global` when the exec root is itself on PATH), but `views/<n>/bin`
    # and the exec `bin` are not PATH entries a consumer has: they are
    # advertised BY env.sh, so a hook there shadows that view's own tools with
    # another view's names. Measured: node/npm/npx written into the python view,
    # clashing with uv/uvx, so a sourced shell answered `command -v node` from
    # the python view (issue #149). The test is the indirection set, not the
    # exec root, because the exec root is a legitimate target.
    sh_doc_hook_bad=0
    if [ -n "$sh_doc_hookdir" ] && [ -n "${SH_EXEC:-}" ]; then
        case "$sh_doc_hookdir" in
            "$SH_EXEC"/views|$SH_EXEC/views/*) sh_doc_hook_bad=1 ;;
        esac
        if [ -n "${SH_EXEC_BIN:-}" ]; then
            case "$sh_doc_hookdir" in
                "$SH_EXEC_BIN"|"$SH_EXEC_BIN"/*) sh_doc_hook_bad=1 ;;
            esac
        fi
    fi
    if [ "$sh_doc_hook_bad" = 1 ]; then
        sh_doctor_check global_hook "inside-exec-root:$sh_doc_hookdir" 'a PATH directory outside the tree indirection (repair: sandhome global --remove, then sandhome global)'
    else
        # # THE PASS ARM COMPARES THE VALUE WITH ITSELF. `on:<dir>` is a
        # directory the probe answered, and any such directory outside the
        # indirection set is healthy; writing a literal want here made every
        # normal `on:<dir>` a failure, which the suite caught. Only `stale:`
        # names a wanted value, because there is a wanted value for it
        # (`on:<dir> or none`).
        case "$sh_doc_global" in
            stale:*) sh_doctor_check global_hook "$sh_doc_global" 'on:<dir> or none (repair: sandhome global)' ;;
            *)       sh_doctor_check global_hook "$sh_doc_global" "$sh_doc_global" ;;
        esac
    fi
    # The working tree may itself be noexec (issue #24): build output there
    # fails at run time with Permission denied, which reads as an install bug.
    # This is informational, never a failure: the fix is to build under
    # SANDHOME_EXEC, not to move the project.
    #
    # The note names the two shapes that read as a BROKEN INSTALL rather than a
    # noexec mount, because neither is obvious and both were measured (issue #42).
    # A per-project venv half-works: bin/python is a symlink to an exec-capable
    # system python, so `.venv/bin/python -m x` runs, while every console script
    # has an absolute shebang into the noexec tree and dies with
    #   .venv/bin/cowsay: .venv/bin/python: bad interpreter: Permission denied
    # The same for node: `npm install` exits 0, and ./node_modules/.bin/CLI dies
    # the same way while `node node_modules/CLI/index.js` works. The remedy is
    # one command, not two incantations: `sandhome project` puts the project
    # on the exec root with its venv inside it (where its shebangs resolve)
    # and links ./NAME back to it.
    sh_doc_cwd=${PWD:-.}
    # Notes stay prose-only: in JSON mode they are skipped, and their facts
    # (workdir noexec, cleared exec root) live in report --json fields.
    if [ "${SH_DOCTOR_JSON:-0}" != 1 ] && ! sh_exec_probe "$sh_doc_cwd" 2>/dev/null; then
        printf 'note   workdir=%s is noexec; build and run output under %s\n' "$sh_doc_cwd" "${SH_EXEC:-.}"
        printf 'note   a .venv or node_modules here half-works: python -m runs, but every\n'
        printf 'note     console script has a shebang into this tree and exits "bad\n'
        printf 'note     interpreter: Permission denied". One command does the dance:\n'
        printf 'note     sandhome project NAME [--python|--node]\n'
    fi
    # A cleared tmpfs exec root (container restart) leaves a valid env.sh with
    # no sandhome on it. Name the state rather than failing silently.
    # STOP: THE SECOND COMMAND IS REPAIR-IF-STILL-BROKEN, NEVER INSTALL (issue
    # #62). Re-running the setup rebuilds the view on its own (measured: 5s,
    # doctor 0, no follow-up), and `install <name>` re-runs the adopt path that
    # broke 8 views in 8 rounds (#49, #43).
    if [ "${SH_DOCTOR_JSON:-0}" != 1 ] && [ ! -x "$SH_EXEC_BIN/sandhome" ] && [ -r "$SH_HOME/repo/bin/sandhome" ]; then
        printf 'note   exec root was cleared (tmpfs restart); re-run the setup, then run sandhome repair only if doctor still fails\n'
    fi
    # The work tree names its own missing build tool, with the exact next
    # command, so a `cmake: command not found` after a green doctor never needs
    # knowing that `sandhome add --url` exists (issue #123). These are notes,
    # never failures: doctor gates what the setup asked for, and the work tree
    # is what the caller pasted after it. Each marker is checked against the
    # probe, not against the wanted list, because a `--toolset developer` run
    # in a CMake checkout wants cmake even though it never named it.
    if [ "${SH_DOCTOR_JSON:-0}" != 1 ]; then
        sh_doc_wd=${PWD:-.}
        if [ -e "$sh_doc_wd/CMakeLists.txt" ] || [ -e "$sh_doc_wd/CMakePresets.json" ]; then
            if ! sh_have cmake; then
                printf 'note   CMakeLists.txt here but cmake is not on PATH; run: sandhome install cmake\n'
            fi
        fi
        if [ -e "$sh_doc_wd/meson.build" ]; then
            if ! sh_have meson; then
                printf 'note   meson.build here but meson is not on PATH; run: sandhome install meson\n'
            fi
        fi
        if [ -e "$sh_doc_wd/configure.ac" ]; then
            if ! sh_have pkgconf && ! sh_have pkg-config; then
                printf 'note   configure.ac here but neither pkgconf nor pkg-config is on PATH; run: sandhome install pkgconf\n'
            fi
            if ! sh_have perl; then
                printf 'note   configure.ac here but perl is not on PATH; run: sandhome install perl\n'
            fi
        fi
        if [ -e "$sh_doc_wd/Makefile" ] || [ -e "$sh_doc_wd/makefile" ] || [ -e "$sh_doc_wd/GNUmakefile" ]; then
            if ! sh_have cmake && ([ -e "$sh_doc_wd/CMakeLists.txt" ] || [ -e "$sh_doc_wd/CMakePresets.json" ]); then
                printf 'note   build files here but cmake is not on PATH; run: sandhome install cmake\n'
            fi
        fi
    fi
    # A needed shim that is not there is a failure even when the machine looks
    # like it does not need it, because a shim built by an earlier run and a
    # shim needed by this run are the same directory.
    sh_doc_shim_dir=$(sh_shims_dir)
    if [ "${SH_PTY:-unknown}" = no ] || [ -f "$sh_doc_shim_dir/fakepty.so" ]; then
        sh_doctor_check fakepty_built \
            "$([ -f "$sh_doc_shim_dir/fakepty.so" ] && printf yes || printf no)" yes
    fi
    if [ "${SH_PASSWD:-unknown}" = no ] || [ -f "$sh_doc_shim_dir/fakepwd.so" ]; then
        sh_doctor_check fakepwd_built \
            "$([ -f "$sh_doc_shim_dir/fakepwd.so" ] && printf yes || printf no)" yes
        sh_doctor_check fakepwd_database \
            "$([ -r "$sh_doc_shim_dir/passwd" ] && printf yes || printf no)" yes
    fi
    # antiptrace is doctor-checked the same way: present when the machine denies
    # ptrace (wholly or partly), or when an earlier run built it here and the
    # file is the same one a program will load.
    if [ "${SH_PTRACE:-unknown}" = no ] || [ "${SH_PTRACE:-unknown}" = partial ] || [ -f "$sh_doc_shim_dir/antiptrace.so" ]; then
        sh_doctor_check antiptrace_built \
            "$([ -f "$sh_doc_shim_dir/antiptrace.so" ] && printf yes || printf no)" yes
    fi
    # The headless shims share one rule instead of four blocks: needed here,
    # or built by an earlier run, means present is required.
    for sh_doc_shim in fakedrm fakeinput fakexenv fakedisplay; do
        if [ "$(sh_shim_need "$sh_doc_shim")" = yes ] || [ -f "$sh_doc_shim_dir/$sh_doc_shim.so" ]; then
            sh_doctor_check "${sh_doc_shim}_built" \
                "$([ -f "$sh_doc_shim_dir/$sh_doc_shim.so" ] && printf yes || printf no)" yes
        fi
    done
    # The exec view must exist, and every toolchain that was installed must
    # still answer. `report` prints a version per toolchain; doctor turns the
    # empty ones into failures, because a version that is empty is a toolchain
    # that is not reachable and the report alone does not say so.
    if [ -d "$SH_EXEC_VIEWS" ]; then
        # # STOP: THE REQUESTED LIST IS READ FROM env.sh, NOT FROM THE
        # ENVIRONMENT. `sh_env_load` sources prefs.sh and env.d/ but not env.sh
        # - deliberately, because env.sh rewrites PATH and SANDHOME_* and
        # loading it from inside a command is how a value gets set twice. So a
        # fresh `sandhome doctor` has SANDHOME_WANTED_TOOLCHAINS unset even
        # though the file records it, and reading the variable was reading
        # nothing. It is read here with the shell's own read, the way
        # sh_space_recorded_exec reads the exec root, because the library may not
        # use grep and this is the same question: what does the file say.
        sh_doc_wanted_all=''
        sh_doc_cache_decl=no
        sh_doc_cr=$(printf '\r')
        if [ -r "$SH_HOME/env.sh" ]; then
            while IFS= read -r sh_doc_wl; do
                sh_doc_wl=${sh_doc_wl%"$sh_doc_cr"}
                case "$sh_doc_wl" in
                    SANDHOME_WANTED_TOOLCHAINS=*)
                        sh_doc_wanted_all=${sh_doc_wl#SANDHOME_WANTED_TOOLCHAINS=}
                        sh_doc_wanted_all=${sh_doc_wanted_all#\'}
                        sh_doc_wanted_all=${sh_doc_wanted_all%\'}
                        sh_doc_wanted_all=${sh_doc_wanted_all#\"}
                        sh_doc_wanted_all=${sh_doc_wanted_all%\"}
                        ;;
                    *XDG_CACHE_HOME=*) sh_doc_cache_decl=yes ;;
                esac
            done < "$SH_HOME/env.sh"
        fi
        for sh_doc_t in $(sh_toolchain_available); do
            sh_doc_wanted=no
            case " $sh_doc_wanted_all " in
                *" $sh_doc_t "*) sh_doc_wanted=yes ;;
            esac
            case " $(sh_lead "$INSTALLED") $(sh_lead "$ADOPTED") " in
                *" $sh_doc_t "*) sh_doc_wanted=yes ;;
            esac
            # A toolchain the setup ASKED FOR is checked even when neither
            # INSTALLED nor ADOPTED names it. Those two are this run's variables
            # and are empty in a fresh process, so the loop used to skip every
            # toolchain and report a green readiness gate over a setup that had
            # just said it could not install five of eleven (issue #38). A name
            # in neither list is still skipped, because `languages` being
            # installed says nothing about whether a consumer who never asked
            # for it wants clang.
            [ "$sh_doc_wanted" = yes ] || continue
            sh_doc_version=$(sh_toolchain_version "$sh_doc_t")
            # # STOP: A TOOLCHAIN THAT IS WANTED AND MISSING NAMES THE COMMAND
            # THAT CLEARS THE FAILURE (issue #191). A failed --only yq install
            # leaves yq in SANDHOME_WANTED_TOOLCHAINS, so doctor and status are
            # red on every later run and nothing in the output says how to get a
            # green sandbox back. The one command that does is
            # `sandhome install --without NAME`, which drops it from the request
            # and records only; the other is a forced reinstall of it.
            if [ -n "$sh_doc_version" ]; then
                sh_doctor_check "toolchain_$sh_doc_t" yes yes
            else
                sh_doctor_check "toolchain_$sh_doc_t" \
                    "no (drop it: sandhome install --without $sh_doc_t; retry: sandhome install --force $sh_doc_t)" \
                    yes
            fi
            # # STOP: A TOOLCHAIN CAN ANSWER A VERSION AND STILL BE UNUSABLE. A
            # launcher-view node prints `node --version` and then fails every
            # spawn, because process.execPath is an anonymous memfd: Playwright,
            # Puppeteer, webpack and every worker die with ENOENT while doctor
            # reported `toolchain_node=yes` and zero failures (issue #139). A
            # module that declares tc_<name>_doctor gets that check run here,
            # so the gate cannot be green over a runtime that cannot fork
            # itself, and the line names the one command that fixes it.
            if [ -n "$sh_doc_version" ] && sh_toolchain_has_doctor "$sh_doc_t"; then
                sh_doc_spawn=no
                if sh_toolchain_doctor "$sh_doc_t"; then
                    sh_doc_spawn=yes
                else
                    sh_doc_spawn="no; a runtime that cannot re-execute itself breaks Playwright, webpack and every worker (run: sandhome install --force $sh_doc_t)"
                fi
                sh_doctor_check "toolchain_${sh_doc_t}_spawn" "$sh_doc_spawn" yes
            fi
        done
    else
        # A root without its views is a wiped or half-built root. The loop
        # above would skip every toolchain and the gate would read green over
        # nothing, which is exactly what a fresh shell then hits: the tools
        # are gone and doctor had said ready. Failing here makes that state
        # impossible to mistake for health.
        sh_doctor_check exec_views missing 'present; run sandhome resume'
    fi
    # # STOP: EVERY BINARY THE REPORT ADVERTISES MUST BE THERE AND MUST RUN.
    # `doctor` is the readiness gate ROUTE.md step 2 tells a session to trust
    # ("when the check at the end of this step exits 0, the sandbox is ready:
    # do the task"), and it was answering that question about the two roots and
    # the shims only. On a host where the toolset was adopted it exited 0 while
    # GOBIN, GOCACHE, CARGO_INSTALL_ROOT and NPM_CONFIG_PREFIX were unset and
    # `go install` produced a binary that neither ran nor reached PATH, and it
    # stayed green while jq, rg and fd were self-symlinks in the exec view and
    # every one of them exited 126 (issues #43, #45, #47).
    #
    # The two loops below close both gaps. The first is the exec view: a link
    # that does not resolve, or resolves to itself, is a tool that is not there
    # however green the root checks are. The second is the env file: a variable
    # ROUTE.md step 4 says "already point[s] there" and does not is a promise
    # the consumer is told to rely on.
    if [ -d "$SH_EXEC_BIN" ]; then
        for sh_doc_link in "$SH_EXEC_BIN"/*; do
            [ -e "$sh_doc_link" ] || [ -L "$sh_doc_link" ] || continue
            sh_doc_name=${sh_doc_link##*/}
            sh_doc_real=$(sh_dirname "$sh_doc_link")
            sh_doc_target=$(readlink "$sh_doc_link" 2>/dev/null || printf '')
            # A symlink whose target is its own path is the defect in #43 and it
            # is invisible to [ -e ] on a shell that follows the link silently.
            if [ -n "$sh_doc_target" ] && [ "$sh_doc_target" = "$sh_doc_link" ]; then
                printf 'FAIL exec_link_%s=broken (links to itself)\n' "$sh_doc_name"
                sh_doc_fail=$((sh_doc_fail + 1))
                continue
            fi
            if [ ! -x "$sh_doc_link" ]; then
                printf 'FAIL exec_link_%s=broken (not executable)\n' "$sh_doc_name"
                sh_doc_fail=$((sh_doc_fail + 1))
            fi
        done
    else
        # Same state one level down: a root with no bin directory has no
        # `sandhome` in its view and no tool links, whatever the root checks
        # say about the directory itself.
        sh_doctor_check exec_bin missing 'present; run sandhome resume'
    fi
    for sh_doc_var in GOBIN GOCACHE CARGO_INSTALL_ROOT NPM_CONFIG_PREFIX; do
        sh_doc_want_exec=''
        # # THE WANTED LIST, NOT THIS RUN'S VARIABLES. INSTALLED and ADOPTED
        # are this process's and are empty in a fresh doctor, so this gate
        # never fired outside the install run itself: a fragment deleted
        # afterwards left GOBIN pointing at the noexec home while doctor
        # stayed green. The env.sh record the toolchain loop above already
        # reads is the same list this gate must use. Each variable belongs to
        # the toolchain that writes it: checking CARGO_INSTALL_ROOT on a tree
        # that never wanted rust is a false failure, not vigilance.
        case "$sh_doc_var" in
            GOBIN|GOCACHE) sh_doc_want_match=' go ' ;;
            CARGO_INSTALL_ROOT) sh_doc_want_match=' rust ' ;;
            NPM_CONFIG_PREFIX) sh_doc_want_match=' node ' ;;
        esac
        case " $(sh_lead "$ADOPTED") $(sh_lead "$INSTALLED") ${sh_doc_wanted_all:-} " in
            *"$sh_doc_want_match"*) sh_doc_want_exec=yes ;;
        esac
        [ -n "$sh_doc_want_exec" ] || continue
        sh_doc_got=$(eval "printf '%s' \"\${$sh_doc_var:-}\"")
        case "$sh_doc_got" in
            "$SH_EXEC"/*) : ;;
            *)
                printf 'FAIL %s=unset (expected under %s; run sandhome install --force <name>)\n' \
                    "$sh_doc_var" "$SH_EXEC"
                sh_doc_fail=$((sh_doc_fail + 1)) ;;
        esac
    done
    # # A DOWNLOADED BROWSER IS AN EXECUTABLE, SO DOCTOR CHECKS ITS CACHE.
    # Puppeteer defaults to $HOME/.cache/puppeteer and Playwright to
    # $HOME/.cache/ms-playwright, and the home is the mount that refuses
    # execve: the download succeeds and the launch dies with Permission denied
    # (issue #143). The node fragment points both at the exec root; this gate
    # fails when node is wanted and either variable does not point there, so
    # the fragment cannot rot back to the home default unnoticed. It reads the
    # wanted list from env.sh, the same list the toolchain loop above reads,
    # because a fresh doctor has no INSTALLED/ADOPTED in its environment. A
    # caller who set either to their own exec-capable path keeps it only when
    # it is under the exec root this run chose; otherwise the browser would
    # not run here.
    case " ${sh_doc_wanted_all:-} " in
        *" node "*)
            for sh_doc_var in PUPPETEER_CACHE_DIR PLAYWRIGHT_BROWSERS_PATH; do
                sh_doc_got=$(eval "printf '%s' \"\${$sh_doc_var:-}\"")
                case "$sh_doc_got" in
                    "$SH_EXEC"/*) : ;;
                    *)
                        printf 'FAIL %s=unset (expected under %s; run sandhome install --force node)\n' \
                            "$sh_doc_var" "$SH_EXEC"
                        sh_doc_fail=$((sh_doc_fail + 1)) ;;
                esac
            done ;;
    esac
    # # STOP: npm MUST STAY RUNNABLE AS JAVASCRIPT. The node view holds
    # bin/npm as a symlink into lib/node_modules/npm/bin/npm-cli.js, and
    # `node <dir-of-node>/npm` is a documented invocation a real build script
    # used. An earlier shell wrapper written at that .js path made it die with
    # `SyntaxError: Invalid or unexpected token` while `npm` itself worked, and
    # doctor was green throughout (issue #157). The probe runs the view's npm
    # through its own node, so the one observable that catches it is a failure.
    #
    # STOP: AND IT MUST ASK THE SAME QUESTION ON A MACHINE WITH NO NODE VIEW.
    # This probe asked for $SANDHOME_EXEC/views/node/bin/npm, which is a path
    # that only exists when node was INSTALLED into the home. An ADOPTED node
    # (the usual case: mise, nvm, a distro package, anything already on PATH)
    # has no home root and therefore no view by design - see
    # sh_toolchain_adopted_root - and the probe answered "no" every time. The
    # measured consequence on a clean setup here:
    #   $ sandhome doctor
    #   FAIL node_npm_js=no (wanted yes)
    #   doctor_failures=1
    #   $ sandhome status
    #   ready=no ... next=run 'sandhome doctor' for the failing invariant
    # so the setup refused to call itself ready on a machine where npm works
    # perfectly well (`sandhome exec npm --version` answered 12.2.0 in the same
    # shell that doctor was failing in). A green gate that lies and a red gate
    # that lies are the same defect; this one shipped red, and ROUTE.md tells a
    # consumer to treat a non-zero doctor as "the task not being ready".
    #
    # So the probe asks the same question of whatever npm actually is, and
    # tries three sources in the order that can answer it.
    #
    # STOP: IT MUST NOT DEPEND ON LOADING THE node MODULE. The obvious third
    # source is sh_toolchain_adopted_root, which loads tools/node.sh to ask it
    # where its working copy is. That is UNAVAILABLE where doctor runs, and
    # silently so: `doctor` is reached through the private mirror
    # $SANDHOME_EXEC/.sandhome-lib, and the mirror carries lib/ and bin/ only -
    # `ls .sandhome-lib` gives exactly those two. So sh_toolchain_load prints
    # "no module for toolchain node" to stderr and returns empty, and a probe
    # built on it answers "no" on every machine no matter what is installed.
    # Measured after the first version of this fix, which used it:
    #   sh_toolchain_adopted_root node  ->  []
    #   doctor                            ->  FAIL node_npm_js=no (wanted yes)
    # with `sandhome exec npm --version` answering 12.2.0 in the same shell.
    # A fix that reaches for a thing the calling context cannot provide is not
    # a fix, and the two-line change from a module to sh_path_where is the whole
    # difference between it working and not.
    #
    # The sources, in order:
    #   1. the installed node's view, which is what #157 was about;
    #   2. the javascript itself, found from whatever npm is on PATH.
    #
    # STOP: THE PROBE SUBJECT MUST BE JAVASCRIPT, NEVER A SHELL WRAPPER. There
    # were two wrong answers here and both were measured, and the first version
    # of this fix was the second one:
    #   (a) measuring $SANDHOME_EXEC/views/node/bin/npm, which does not exist for
    #       an ADOPTED node at all, so the check was red on every host that
    #       already had node;
    #   (b) falling back to $SH_EXEC_BIN/npm, which EXISTS and is a `#!/bin/sh`
    #       wrapper this tree writes ("the npm beside this node does not run
    #       here; exec node .../npm-cli.js"). Handing that to node is asking
    #       node to parse a shell script:
    #         $ node $SH_EXEC_BIN/npm --version
    #         /workspace/.sandhome/exec/bin/npm:2
    #         # written by sandhome: the npm beside this node does not run here
    #         ^
    #       so the probe answered no on a machine where `npm --version` printed
    #       12.2.0 in the same shell. That is the #157 regression reproduced in
    #       the very check meant to catch it.
    # The gate is therefore: take a candidate, and KEEP it only if the file it
    # names is real javascript. sh_is_script is already the tree's reader for
    # this (lib/common.sh), and a .js file that is not a script is exactly the
    # "still JavaScript" shape #157 wants, so the check accepts either and
    # rejects a `#!` that is not node's.
    case " ${sh_doc_wanted_all:-} " in
        *" node "*)
            sh_doc_npm_js=no
            sh_doc_node_probe=''
            sh_doc_node_view=$(sh_toolchain_view node 2>/dev/null)
            if [ -n "$sh_doc_node_view" ] && [ -e "$sh_doc_node_view/bin/npm" ]; then
                # `node <path>/npm` is the documented invocation, so the probe
                # is that invocation rather than the .js underneath it.
                sh_doc_node_probe=$sh_doc_node_view/bin/npm
            fi
            if [ -z "$sh_doc_node_probe" ]; then
                # The adopted case, and also the case where the view is absent
                # for any other reason. Find npm the way any shell finds it,
                # then walk from it to the javascript it is built from. A
                # wrapper this tree wrote NAMES npm-cli.js, so it is read for
                # that path rather than guessed at; the directory beside npm is
                # tried next, which is where mise, nvm, a distro package and
                # npm's own installer all put it.
                sh_doc_node_npm=$(sh_path_where npm 2>/dev/null)
                if [ -n "${SH_EXEC_BIN:-}" ] && [ -e "$SH_EXEC_BIN/npm" ]; then
                    sh_doc_node_npm=$SH_EXEC_BIN/npm
                fi
                if [ -n "$sh_doc_node_npm" ]; then
                    # The wrapper names its own payload, so read it rather than
                    # assume a layout. This is a text read of a file this tree
                    # wrote, and it is what makes the adopted case work at all:
                    # the wrapper's only content IS the path.
                    # STOP: THE SHEBANG IS NOT A REASON TO STOP LOOKING. The
                    # first version guarded the search behind
                    #   case "$first" in '#!'*) : ;; *) search ;; esac
                    # which is exactly backwards for this file: the wrapper IS a
                    # `#!/bin/sh` script, so the guard skipped the search on the
                    # one file that needs it. Measured on this tree, with the
                    # probe empty and the wrapper sitting right there naming the
                    # answer:
                    #   $ sandhome doctor            ->  FAIL node_npm_js=no (wanted yes)
                    #   $ sandhome exec npm --version ->  12.2.0
                    # The guard reads as "a script is already the thing we want",
                    # which is right for the view case and wrong here, where the
                    # script is a POINTER. Read every line and take the path.
                    sh_doc_node_named=''
                    while IFS= read -r sh_doc_node_l 2>/dev/null; do
                        case "$sh_doc_node_l" in
                            *npm-cli.js*)
                                for sh_doc_node_w in $sh_doc_node_l; do
                                    case "$sh_doc_node_w" in
                                        /*npm-cli.js) sh_doc_node_named=$sh_doc_node_w; break ;;
                                    esac
                                done
                                ;;
                        esac
                        [ -n "$sh_doc_node_named" ] && break
                    done < "$sh_doc_node_npm"
                    if [ -n "$sh_doc_node_named" ] && [ -r "$sh_doc_node_named" ]; then
                        sh_doc_node_probe=$sh_doc_node_named
                    else
                        sh_doc_node_npm_r=''
                        if sh_have readlink; then
                            sh_doc_node_npm_r=$(readlink -f "$sh_doc_node_npm" 2>/dev/null) || sh_doc_node_npm_r=''
                        fi
                        for sh_doc_node_d in \
                            "${sh_doc_node_npm%/*}" "${sh_doc_node_npm_r%/*}"; do
                            [ -n "$sh_doc_node_d" ] || continue
                            for sh_doc_node_c in \
                                "$sh_doc_node_d/npm/lib/node_modules/npm" \
                                "$sh_doc_node_d/npm" \
                                "$sh_doc_node_d/lib/node_modules/npm" \
                                "$sh_doc_node_d"; do
                                [ -r "$sh_doc_node_c/bin/npm-cli.js" ] || continue
                                sh_doc_node_probe=$sh_doc_node_c/bin/npm-cli.js
                                break
                            done
                            [ -n "$sh_doc_node_probe" ] && break
                        done
                    fi
                fi
            fi
            # THE LAST GATE, AND IT IS THE ONE THAT MATTERS: whatever was found
            # must be javascript node can read. A `#!/bin/sh` wrapper is the one
            # shape that must never be handed to node, and this check is the
            # cheap place to refuse it rather than after a SyntaxError.
            #
            # STOP: THE SHEBANG PATTERN IS `'#!'*` AND NOT `'#!'`, OR THIS GATE
            # IS A NO-OP THAT ALWAYS SAYS YES. A shebang line is `#!/bin/sh`,
            # so a pattern of exactly `#!` matches nothing and the case falls
            # through to the keep branch for every file the probe will ever be
            # offered. Measured, with the pattern as `'#!'`:
            #   /bin/npm          -> no-match-KEPT   <- the shell wrapper kept
            #   /bin/npm-cli.js   -> no-match-KEPT
            # and with `'#!'*`:
            #   /bin/npm          -> REFUSED
            #   /bin/npm-cli.js   -> no-shebang-KEPT <- javascript is kept
            # A gate whose failure mode is "passes everything" is worse than no
            # gate, because it reads as a check that passed. sh_is_script above
            # gets this right for the same reason: it matches `'#!'*`.
            if [ -n "$sh_doc_node_probe" ]; then
                sh_doc_node_head=''
                IFS= read -r sh_doc_node_head < "$sh_doc_node_probe" 2>/dev/null || :
                case "$sh_doc_node_head" in
                    '#!'*)
                        case "$sh_doc_node_head" in
                            *node*) : ;;
                            *) sh_doc_node_probe='' ;;
                        esac
                        ;;
                esac
            fi
            if [ -n "$sh_doc_node_probe" ] && node "$sh_doc_node_probe" --version >/dev/null 2>&1; then
                sh_doc_npm_js=yes
            fi
            sh_doctor_check node_npm_js "$sh_doc_npm_js" yes ;;
    esac
    # # STOP: rustup WRITES FOR EVERY TARGET, SO THE HOME MUST TAKE A WRITE.
    # An adopted RUSTUP_HOME that resolves a default toolchain but sits on the
    # read-only mount makes `rustup target add` print a filesystem error and
    # exit 0, so a build script proceeds and dies later on a missing std for a
    # target it believes it installed (issue #159). The gate writes a real file
    # under $RUSTUP_HOME/tmp, which is exactly the first thing rustup does; a
    # check of the variable or of settings.toml does not catch this state.
    case " ${sh_doc_wanted_all:-} " in
        *" rust "*)
            sh_doc_rustup_ok=no
            if [ -n "${RUSTUP_HOME:-}" ]; then
                mkdir -p "$RUSTUP_HOME/tmp" 2>/dev/null
                if ( : > "$RUSTUP_HOME/tmp/.sandhome-write.$$" ) 2>/dev/null; then
                    rm -f "$RUSTUP_HOME/tmp/.sandhome-write.$$" 2>/dev/null
                    sh_doc_rustup_ok=yes
                fi
            fi
            sh_doctor_check rustup_writable "$sh_doc_rustup_ok" yes ;;
    esac
    # # STOP: A ROOT THAT IS DRAINING IS A FAILURE, AND IT IS NAMED IN WORDS.
    # `doctor` is the command ROUTE.md step 2 makes a session run to decide
    # whether the sandbox is ready, so it is the only place an agent is
    # guaranteed to look. It printed exec_free_mb and said nothing about it, and
    # on this host at 86% full it printed `doctor_failures=0`:
    #   df: /dev/shm 245MB total, 36MB free
    #   go build -o $SANDHOME_EXEC/x .  ->  no space left on device, exit 0
    # The failure is not hypothetical and it is not rare: the exec root holds
    # GOCACHE, GOBIN, CARGO_*, NPM_* and every build artifact, so it is the
    # first thing a real project fills.
    #
    # low is a FAILURE too, not a note. A low root still works, and the point of
    # hearing about it is that it works NOW and does not after the next install.
    # A note is read and dismissed; a non-zero exit is read.
    sh_doc_space=$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)
    case "$sh_doc_space" in
        ok) ;;
        unknown)
            # # STOP: AN UNREADABLE ROOT IS A FINDING, NOT A PASS. `df` failing on
            # the exec root means nothing can be measured about the one place
            # every build artifact has to land, and the tree's own rule is that a
            # question the machine will not answer is reported rather than
            # assumed ("a read-only plan refuses by name rather than dying",
            # "an empty answer rather than a wrong one"). Treating it as ok is the
            # exact shape of the defect this change exists to remove: a silent
            # pass on the thing that was not measured.
            if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
                SH_DOCTOR_MEMBERS="$SH_DOCTOR_MEMBERS,\"exec_space\":\"unknown\""
                SH_DOCTOR_FAILED="$SH_DOCTOR_FAILED,\"exec_space\""
                export SH_DOCTOR_MEMBERS SH_DOCTOR_FAILED
            else
                printf 'FAIL exec_space=unknown (df could not measure %s; builds may fail with "no space left on device". Run "sandhome space --probe" to see the candidates)\n' "${SH_EXEC:-/tmp}"
            fi
            sh_doc_fail=$((sh_doc_fail + 1)) ;;
        *)
            sh_doc_free=$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)
            case "$sh_doc_free" in ''|*[!0-9]*) sh_doc_free='?' ;; esac
            # `du` before `gc`, for the reason the adviser carries: on a root
            # full of build output `gc` reclaims nothing, and it was measured
            # that way here. The one line names the biggest thing on the root
            # and the space it is worth.
            if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
                SH_DOCTOR_MEMBERS="$SH_DOCTOR_MEMBERS,\"exec_space\":\"$sh_doc_space\""
                SH_DOCTOR_FAILED="$SH_DOCTOR_FAILED,\"exec_space\""
                export SH_DOCTOR_MEMBERS SH_DOCTOR_FAILED
            else
                printf 'FAIL exec_space=%s (%sMB free; builds and installs will fail. "du -sh %s/* | sort -h | tail" names what holds it, "sandhome gc" reclaims the caches sandhome owns, and re-running setup with --exec DIR moves everything. See "sandhome space --probe" for candidates)\n' \
                    "$sh_doc_space" "$sh_doc_free" "${SH_EXEC:-/tmp}"
            fi
            sh_doc_fail=$((sh_doc_fail + 1)) ;;
    esac
    if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
        printf '{"failures":%s,"failed":[%s],"checks":{%s}}\n' \
            "$sh_doc_fail" "${SH_DOCTOR_FAILED#,}" "${SH_DOCTOR_MEMBERS#,}"
    else
        printf 'doctor_failures=%s\n' "$sh_doc_fail"
    fi
    unset -f sh_doctor_check
    [ "$sh_doc_fail" -gt 0 ] && return 1
    return 0
}
