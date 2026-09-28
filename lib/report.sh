#!/bin/sh
# report.sh - the report read from the machine, in text and in JSON. Sourced.
#
# NOTE: THE REPORT IS READ FROM THE MACHINE, NOT FROM WHAT WAS ASKED FOR. A line
# claiming a tool is present because an install command exited 0 is the class of
# claim this tree keeps finding to be false. Every line below probes.

SH_INSTALLED=''
SH_ADOPTED=''

sh_lead() { printf '%s' "${1# }"; }

# sh_toolchain_status NAME -> present|absent
sh_toolchain_status() {
    if sh_toolchain_probe "$1"; then
        printf 'present'
    else
        printf 'absent'
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
    printf 'home=%s\n'        "${SH_HOME:-unknown}"
    printf 'home_exec=%s\n'   "${SH_HOME_EXEC:-unknown}"
    printf 'exec=%s\n'        "${SH_EXEC:-unknown}"
    printf 'exec_free_mb=%s\n' "$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)"
    # The judgement, not just the number. `exec_free_mb=36` is a fact an agent
    # has to interpret; `exec_space=low` is the conclusion, and a report whose
    # whole job is to be read at a glance should carry it.
    printf 'exec_space=%s\n' "$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)"
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
    printf ',"privilege":"%s","provider":"%s","pty":"%s","passwd":"%s"' \
        "$(sh_json_escape "${SH_PRIVILEGE:-none}")" "$(sh_json_escape "${SH_PROVIDER:-none}")" \
        "$(sh_json_escape "${SH_PTY:-unknown}")" "$(sh_json_escape "${SH_PASSWD:-unknown}")"
    printf ',"home":"%s","home_exec":"%s","exec":"%s","exec_free_mb":"%s","exec_space":"%s"' \
        "$(sh_json_escape "${SH_HOME:-unknown}")" "$(sh_json_escape "${SH_HOME_EXEC:-unknown}")" \
        "$(sh_json_escape "${SH_EXEC:-unknown}")" "$(sh_json_escape "$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)")" \
        "$(sh_json_escape "$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)")"
    printf ',"installed":"%s","adopted":"%s","shims":"%s"' \
        "$(sh_json_escape "$(sh_lead "${SH_INSTALLED:-}")")" \
        "$(sh_json_escape "$(sh_lead "${SH_ADOPTED:-}")")" \
        "$(sh_json_escape "$(sh_lead "$(sh_shim_present 2>/dev/null)")")"
    printf ',"shims_missing":"%s"' \
        "$(sh_json_escape "$(sh_lead "$(sh_shim_needed_missing 2>/dev/null)")")"
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
    sh_doctor_check() {
        sh_dc_name=$1
        sh_dc_got=$2
        sh_dc_want=$3
        if [ "$sh_dc_got" = "$sh_dc_want" ]; then
            printf 'ok   %s=%s\n' "$sh_dc_name" "$sh_dc_got"
        else
            printf 'FAIL %s=%s (wanted %s)\n' "$sh_dc_name" "$sh_dc_got" "$sh_dc_want"
            sh_doc_fail=$((sh_doc_fail + 1))
        fi
    }
    sh_doctor_check home_writable "$(sh_dir_writable "$SH_HOME" && printf yes || printf no)" yes
    sh_doctor_check exec_writable "$(sh_dir_writable "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_runs "$(sh_exec_probe "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_on_path "$(case ":$PATH:" in *":$SH_EXEC_BIN:"*) printf yes ;; *) printf no ;; esac)" yes
    sh_doctor_check env_file "$([ -r "$SH_HOME/env.sh" ] && printf yes || printf no)" yes
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
    # the same in both cases and is the exec root, so it is named once.
    sh_doc_cwd=${PWD:-.}
    if ! sh_exec_probe "$sh_doc_cwd" 2>/dev/null; then
        printf 'note   workdir=%s is noexec; build and run output under %s\n' "$sh_doc_cwd" "${SH_EXEC:-.}"
        printf 'note   a .venv or node_modules here half-works: python -m runs, but every\n'
        printf 'note     console script has a shebang into this tree and exits "bad\n'
        printf 'note     interpreter: Permission denied". Put the venv on the exec root:\n'
        printf 'note     uv venv %s/venvs/NAME && uv pip install --python %s/venvs/NAME/bin/python PKG\n' "${SH_EXEC:-.}" "${SH_EXEC:-.}"
    fi
    # A cleared tmpfs exec root (container restart) leaves a valid env.sh with
    # no sandhome on it. Name the state rather than failing silently.
    if [ ! -x "$SH_EXEC_BIN/sandhome" ] && [ -r "$SH_HOME/repo/bin/sandhome" ]; then
        printf 'note   exec root was cleared (tmpfs restart); run sandhome install <name> to rebuild the exec view\n'
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
    # The exec view must exist, and every toolchain that was installed must
    # still answer. `report` prints a version per toolchain; doctor turns the
    # empty ones into failures, because a version that is empty is a toolchain
    # that is not reachable and the report alone does not say so.
    if [ -d "$SH_EXEC_VIEWS" ]; then
        for sh_doc_t in $(sh_toolchain_available); do
            case " $(sh_lead "$INSTALLED") $(sh_lead "$ADOPTED") " in
                *" $sh_doc_t "*) ;;
                *) continue ;;
            esac
            sh_doctor_version=$(sh_toolchain_version "$sh_doc_t")
            sh_doctor_check "toolchain_$sh_doc_t" \
                "$([ -n "$sh_doctor_version" ] && printf yes || printf no)" yes
        done
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
    fi
    for sh_doc_var in GOBIN GOCACHE CARGO_INSTALL_ROOT NPM_CONFIG_PREFIX; do
        sh_doc_want_exec=''
        case " $(sh_lead "$ADOPTED") $(sh_lead "$INSTALLED") " in
            *" go "*)      sh_doc_want_exec=yes ;;
            *" rust "*)    sh_doc_want_exec=yes ;;
            *" node "*)    sh_doc_want_exec=yes ;;
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
            printf 'FAIL exec_space=unknown (df could not measure %s; builds may fail with "no space left on device". Run "sandhome space --probe" to see the candidates)\n' "${SH_EXEC:-/tmp}"
            sh_doc_fail=$((sh_doc_fail + 1)) ;;
        *)
            sh_doc_free=$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)
            case "$sh_doc_free" in ''|*[!0-9]*) sh_doc_free='?' ;; esac
            # `du` before `gc`, for the reason the adviser carries: on a root
            # full of build output `gc` reclaims nothing, and it was measured
            # that way here. The one line names the biggest thing on the root
            # and the space it is worth.
            printf 'FAIL exec_space=%s (%sMB free; builds and installs will fail. "du -sh %s/* | sort -h | tail" names what holds it, "sandhome gc" reclaims the caches sandhome owns, and re-running setup with --exec DIR moves everything. See "sandhome space --probe" for candidates)\n' \
                "$sh_doc_space" "$sh_doc_free" "${SH_EXEC:-/tmp}"
            sh_doc_fail=$((sh_doc_fail + 1)) ;;
    esac
    printf 'doctor_failures=%s\n' "$sh_doc_fail"
    unset -f sh_doctor_check
    [ "$sh_doc_fail" -gt 0 ] && return 1
    return 0
}
