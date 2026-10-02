#!/bin/sh
# space.sh - where files may live, and where they may run. Sourced.
#
# THE MEASUREMENT THIS EXISTS FOR. A sandbox can mount a directory rw and still
# refuse execve(2) on it, while allowing mmap(PROT_EXEC) - so a shared library
# read from there loads, and a copied binary in it will not run. `mount` does not
# have to say noexec: the refusal can come from a sandbox policy that is invisible
# in /proc/mounts. The only reliable answer is to try it.
#
# WHAT THAT MEANS FOR A TOOLCHAIN. Data (stdlib, GOROOT, .rlib, .so) may live on
# the big read-only-in-effect home directory. Executables (rustc, cargo, go, node,
# the bundled linker) may not: they need an exec-capable mount, and so does every
# build script, proc-macro and test binary a build produces.
#
# So the plan is two roots:
#   SH_HOME  persistent data, exactly where it was asked for. May be noexec.
#   SH_EXEC  the exec-capable root. Small is fine; only executables and build
#            output are promoted here, everything else is symlinked back.
# When SH_HOME is itself exec-capable the two collapse and nothing is promoted.

# STOP: THE TUNABLE HAS ONE NAME AND THE OLD ONE STILL ANSWERS. The variable
# was SH_MIN_EXEC_MB while every document said SANDHOME_MIN_EXEC_MB, so a
# reader who set the documented name changed nothing and had no way to find
# out. The public name is now the one the documents carry, and the old name is
# still read so an existing script is not silently ignored.
: "${SANDHOME_MIN_EXEC_MB:=${SH_MIN_EXEC_MB:-128}}"
SH_MIN_EXEC_MB=$SANDHOME_MIN_EXEC_MB
: "${SH_MIN_HOME_MB:=256}"
SH_TAB=$(printf '\t')

# sh_dir_writable DIR -> 0 when a file can be created in DIR.
sh_dir_writable() {
    [ -d "$1" ] || return 1
    sh_dw_probe="$1/.sandhome.w.$$"
    if ( : > "$sh_dw_probe" ) 2>/dev/null; then
        rm -f "$sh_dw_probe" 2>/dev/null
        return 0
    fi
    rm -f "$sh_dw_probe" 2>/dev/null
    return 1
}

# sh_exec_probe DIR -> 0 when a binary can actually be executed from DIR.
# STOP: NOT A CHECK OF MOUNT OPTIONS. The probe is a real exec of a real file; a
# policy that refuses execve does not have to show up in /proc/mounts, and a
# mount that says noexec can still allow it on some kernels.
sh_exec_probe() {
    sh_ep_dir=$1
    [ -d "$sh_ep_dir" ] || return 1
    sh_ep_file="$sh_ep_dir/.sandhome.exec.$$"
    if ! printf '#!/bin/sh\nexit 0\n' > "$sh_ep_file" 2>/dev/null; then
        rm -f "$sh_ep_file" 2>/dev/null
        return 1
    fi
    chmod 0700 "$sh_ep_file" 2>/dev/null || true
    if "$sh_ep_file" >/dev/null 2>&1; then
        rm -f "$sh_ep_file" 2>/dev/null
        return 0
    fi
    rm -f "$sh_ep_file" 2>/dev/null
    return 1
}

# sh_mount_opts DIR -> the mount options for the filesystem holding DIR, or
# nothing. This is the cheap answer shown in the report; it is never the answer
# used to decide, because it can be wrong.
sh_mount_opts() {
    if [ -r /proc/mounts ]; then
        sh_mo_want=$1
        sh_mo_best=''
        sh_mo_len=0
        while read -r sh_mo_dev sh_mo_point sh_mo_fs sh_mo_opts sh_mo_a sh_mo_b; do
            case "$sh_mo_want" in
                "$sh_mo_point"|"$sh_mo_point"/*)
                    if [ "${#sh_mo_point}" -gt "$sh_mo_len" ]; then
                        sh_mo_len=${#sh_mo_point}
                        sh_mo_best=$sh_mo_opts
                    fi
                    ;;
            esac
        done < /proc/mounts
        if [ -n "$sh_mo_best" ]; then
            printf '%s' "$sh_mo_best"
            return 0
        fi
    fi
    printf ''
}

# sh_home_default -> the persistent root, honouring the environment. XDG first
# when it is set, then ~/.local/share, then a plain ~/.sandhome for a userland
# with no XDG convention at all.
sh_home_default() {
    if [ -n "${SANDHOME_HOME:-}" ]; then
        printf '%s' "$SANDHOME_HOME"
        return 0
    fi
    if [ -n "${XDG_DATA_HOME:-}" ]; then
        printf '%s/sandhome' "$XDG_DATA_HOME"
        return 0
    fi
    if [ -n "${HOME:-}" ]; then
        printf '%s/.local/share/sandhome' "$HOME"
        return 0
    fi
    printf '/tmp/sandhome'
}

# sh_exec_candidates -> the places tried for the exec root, best first. The
# environment override wins, then the home itself, then every writable tmpfs
# that is usually tmpfs, then a directory under the home. The order is a
# preference, NOT the decision: sh_space_plan ranks the working candidates by
# free space and picks the roomiest, because a name earlier in this list is not
# evidence of room (issue #37).
#
# NOTE: ONE LIST AND ONE DEDUPE, BECAUSE TWO LISTS DRIFT. The plan and the probe
# report each built their own candidate string and they disagreed: the plan did
# not create a missing candidate and the report created one as a side effect of
# asking whether it was writable, so `sandhome space --probe` listed a directory
# that the bootstrap had never made and would never use. /var/tmp was in the list
# at all only because the probe created it (in this sandbox /var/tmp is absent,
# and a probe that makes the directory it reports is a probe that changes the
# machine it claims to be reading).
sh_exec_candidates() {
    sh_ec_seen=' '
    sh_ec_out=''
    sh_ec_add() {
        [ -n "$1" ] || return 0
        case "$sh_ec_seen" in
            *" $1 "*) return 0 ;;
        esac
        sh_ec_seen="$sh_ec_seen$1 "
        sh_ec_out="$sh_ec_out$1 "
        return 0
    }
    # # STOP: THE WORKING TREE IS A CANDIDATE (issue #114). The list was a
    # hardcoded set, so a machine whose scratch roots are small or refuse
    # execve but whose checkout sits on a roomy, exec-capable mount never
    # considered it: `/workspace` ran binaries and had gigabytes free and the
    # planner still handed out a 245MB /dev/shm. The candidate is a dedicated
    # `.sandhome/exec` under the tree, not the tree itself, so a chosen root
    # writes bin/ and views/ into a namespaced directory instead of littering
    # a project root. `/` is skipped: `/.sandhome` is not a working tree.
    #
    # REDUNDANCY: FOUR LAYERS, NOT ONE PWD. PWD alone misses the project root
    # when the agent works in a subdir (PWD=/ws/proj/sub, root=/ws/proj), the
    # git top level when PWD is not the checkout, and every other exec-capable
    # mount the hardcoded five never named. Each layer is best-effort and
    # bounded: a missing tool (git), an unreadable /proc/mounts, or a strange
    # PWD degrades to the layers that remain rather than failing the list.
    # Exec perms differ by sandbox, so listing is never deciding: every entry
    # is still probed with a real file before it can win.
    sh_ec_pwd=''
    case "${PWD:-}" in
        ''|/) ;;
        *) sh_ec_pwd=$PWD/.sandhome/exec ;;
    esac
    # Layer 1: the explicit override and the work-tree namespaced dirs (PWD,
    # its parents up to two levels, and the git top level). Parents cover
    # `project/subdir` runs; git covers a PWD outside the checkout.
    # REDUNDANCY: NAMED VOLUMES FIRST, BECAUSE PWD MISSES THEM. PWD parents and
    # git cover the checkout, but a harness that runs in /tmp with a roomy
    # /workspace beside it never names it through PWD at all. The durable
    # work volumes are named explicitly so the roomiest exec-capable one can
    # win on its merits: /workspace here is 117GB and exec-capable while /tmp
    # and /dev/shm refuse execve, and on a cage without /workspace the same
    # entries are absent and cost nothing. CI and container harnesses name
    # theirs through the environment, so those are read too. Every entry is
    # still probed with a real file before it can win: exec perms differ by
    # sandbox, so listing is never deciding and a noexec volume loses here.
    sh_ec_git=''
    if sh_have git; then
        sh_ec_git=$(git rev-parse --show-toplevel 2>/dev/null) || sh_ec_git=''
    fi
    # Two parent levels, no deeper: a setup step must not walk to / looking
    # for room. Only '' and / are dropped; every other parent names a
    # namespaced dir, never the tree itself.
    sh_ec_par1=''; sh_ec_par2=''
    sh_ec_up=${PWD:-}
    case "$sh_ec_up" in ''|/) sh_ec_up='' ;; *) sh_ec_up=${sh_ec_up%/*} ;; esac
    case "$sh_ec_up" in ''|/) ;; *) sh_ec_par1=$sh_ec_up/.sandhome/exec ;; esac
    case "$sh_ec_up" in ''|/) sh_ec_up='' ;; *) sh_ec_up=${sh_ec_up%/*} ;; esac
    case "$sh_ec_up" in ''|/) ;; *) sh_ec_par2=$sh_ec_up/.sandhome/exec ;; esac
    for sh_ec_c in \
        ${SANDHOME_EXEC:+"$SANDHOME_EXEC"} \
        ${sh_ec_pwd:+"$sh_ec_pwd"} \
        ${sh_ec_git:+"$sh_ec_git/.sandhome/exec"} \
        ${sh_ec_par1:+"$sh_ec_par1"} \
        ${sh_ec_par2:+"$sh_ec_par2"} \
        ${GITHUB_WORKSPACE:+"$GITHUB_WORKSPACE/.sandhome/exec"} \
        ${RUNNER_TEMP:+"$RUNNER_TEMP/.sandhome/exec"} \
        ${AGENT_WORKFOLDER:+"$AGENT_WORKFOLDER/.sandhome/exec"} \
        ${WORKSPACE:+"$WORKSPACE/.sandhome/exec"} \
        ${SANDHOME_WORKSPACE:+"$SANDHOME_WORKSPACE/.sandhome/exec"} \
        "/workspace/.sandhome/exec" \
        "/mnt/.sandhome/exec" \
        "/data/.sandhome/exec" \
        "/scratch/.sandhome/exec" \
        "/srv/.sandhome/exec" \
        "$SH_HOME" \
        /dev/shm \
        /tmp \
        "/run/user/$(id -u 2>/dev/null)" \
        ${HOME:+"$HOME/.cache/sandhome/exec"} \
        ${TMPDIR:+"$TMPDIR"} \
        ${XDG_RUNTIME_DIR:+"$XDG_RUNTIME_DIR/sandhome-exec"} \
        /var/tmp
    do
        [ -n "$sh_ec_c" ] || continue
        # The filesystem root is never a working tree.
        case "$sh_ec_c" in /.sandhome/exec|/.sandhome) continue ;; esac
        sh_ec_add "$sh_ec_c"
    done
    # Layer 2: every other rw mount point, bounded. /proc/mounts names what
    # the kernel mounted; the plan still probes each entry with a real file,
    # so a noexec mount is listed and then loses on its merits rather than
    # being assumed away from its options. Only scratch-like prefixes are
    # considered: system prefixes (/bin, /lib, /usr, /etc, /opt) are never
    # candidates, because writing `.sandhome/exec` there litters the OS and
    # is usually read-only anyway. Bounded at 12 entries so a container
    # with 40 bind mounts does not turn the plan into 40 probes.
    if [ -r /proc/mounts ]; then
        sh_ec_n=0
        while read -r sh_ec_dev sh_ec_point sh_ec_fs sh_ec_opts sh_ec_a sh_ec_b; do
            [ "$sh_ec_n" -lt 12 ] || break
            case "$sh_ec_point" in
                ''|/|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run/secrets|/run/secrets/*|/etc/*) continue ;;
            esac
            case "$sh_ec_fs" in proc|sysfs|cgroup*|devpts|mqueue|shm|overlay) continue ;; esac
            case "$sh_ec_opts" in *ro*) continue ;; esac
            # Scratch-like prefixes only: the work areas and temp roots.
            # Anything else (system bind mounts, language runtimes, package
            # caches) is not a place to put an exec root. Deep bind mounts
            # (a tool dir mounted at /home/u/.local/share/.../bin) are also
            # skipped: only roots up to three levels deep are considered, so
            # per-tool mounts never become exec roots.
            case "$sh_ec_point" in
                /workspace*|/tmp*|/var/tmp*|/home*|/state*|/mnt*|/media*|/srv*|/data*|/scratch*|/run/user/*|/dev/shm) ;;
                *) continue ;;
            esac
            case "$sh_ec_point" in /*/*/*/*) continue ;; esac
            [ -d "$sh_ec_point" ] || continue
            sh_ec_mp_c="$sh_ec_point/.sandhome/exec"
            case "$sh_ec_seen" in *" $sh_ec_mp_c "*) continue ;; esac
            case "$sh_ec_seen" in *" $sh_ec_point "*) continue ;; esac
            sh_ec_add "$sh_ec_mp_c"
            sh_ec_n=$((sh_ec_n + 1))
        done < /proc/mounts
    fi
    sh_ec_out=${sh_ec_out% }
    printf '%s' "$sh_ec_out"
}

# sh_space_recorded_exec -> the SANDHOME_EXEC recorded in $SH_HOME/env.sh, or
# nothing. The plan reuses it so a later install does not migrate the exec root
# and orphan the views and launchers on the old one (issue #41). Parsed with the
# shell's own read, because the library may not use grep.
sh_space_recorded_exec() {
    sh_sre_out=''
    [ -r "$SH_HOME/env.sh" ] || {
        printf ''
        return 0
    }
    while IFS= read -r sh_sre_l; do
        case "$sh_sre_l" in
            SANDHOME_EXEC=*)
                sh_sre_out=${sh_sre_l#SANDHOME_EXEC=}
                sh_sre_out=${sh_sre_out#\'}
                sh_sre_out=${sh_sre_out%\'}
                ;;
        esac
    done < "$SH_HOME/env.sh"
    printf '%s' "$sh_sre_out"
}

# sh_space_plan -> set SH_HOME and SH_EXEC, create both, and export them. The
# exec root is the ROOMIEST candidate that is writable and actually runs a file
# and clears SANDHOME_MIN_EXEC_MB; when none clears it, the first working one is
# used with a warning, because a small exec root that works beats a large one
# that does not. Order in sh_exec_candidates is only a tie-break: preferring the
# first candidate that merely clears the floor put /dev/shm (184MB) ahead of
# /tmp (488MB) on a host where the guide names /tmp the default, and the default
# --toolset developer then failed for want of room (issue #37).
#
# # STOP: `--no-create` ANSWERS WITHOUT CHANGING THE MACHINE, BECAUSE A QUESTION
# ABOUT A ROOT IS NOT A REQUEST TO BUILD ONE. The planner used to mkdir both
# roots on the way to answering anything, and bin/sandhome called it before its
# dispatcher, so every subcommand created them:
#   $ SANDHOME_HOME=/tmp/h SANDHOME_EXEC=/tmp/e sh bin/sandhome version
#   sandhome/1
#   $ find /tmp/h /tmp/e -maxdepth 1        # four directories each
# Three things were wrong with that. `version` and `help` are the two commands a
# caller reaches for BECAUSE something is broken, and they could not run at all
# on a machine whose configured home is unwritable: sh_die fired during startup
# and the usage text was never printed. `space --probe` reported a post-creation
# state, so the answer was about the world it had just made rather than the one
# asked about - the same fault the probe report already documents for /var/tmp.
# And `HOME/.cache/sandhome/exec` is a candidate, so once any command had run,
# a directory appeared that would never otherwise exist and became a writable,
# exec-capable candidate: the plan's own outcome then depended on which command
# had been run first.
#
# In --no-create the home is NOT probed for exec and NOT created, the candidate
# list is examined as it stands, and a directory that does not exist is passed
# over rather than made. A caller that needs the directories runs a command that
# installs something; that is what creating them is for.
sh_space_plan() {
    sh_sp_create=1
    if [ "${1:-}" = --no-create ]; then
        sh_sp_create=0
    fi
    SH_HOME=$(sh_home_default)
    SH_EXEC=''
    SH_HOME_EXEC=no
    # # STOP: THE USABLE FLAG IS RESET AT THE TOP OF EVERY PLAN, NOT ONLY SET ON
    # THE FAILING PATH. A read-only plan that found nothing sets it to 1, and the
    # create plan that runs after it reused the stale 1, so `sandhome install`
    # refused a root it had just made. Every plan decides this from scratch.
    SH_EXEC_UNUSABLE=0

    if [ "$sh_sp_create" = 1 ]; then
        if ! mkdir -p "$SH_HOME" 2>/dev/null; then
            sh_die "cannot create the home root at $SH_HOME; pass SANDHOME_HOME"
        fi
    fi
    # Probing the home for exec WRITES to it (sh_exec_probe creates and runs a
    # file), so it is a create-only measurement. A read-only plan reports the
    # RECORDED answer rather than guessing: the create plan persists what it
    # measured to $SH_HOME/.home_exec, and the read-only plan reads that file
    # back. Without it `sandhome report` and `sandhome space` printed
    # home_exec=unknown for a machine the bootstrap had already called
    # home_exec=no (issue #60), which reads as "not measured yet" when it is a
    # settled fact. A missing or unreadable record still answers unknown.
    if [ "$sh_sp_create" = 1 ]; then
        if sh_exec_probe "$SH_HOME"; then
            SH_HOME_EXEC=yes
        fi
        printf '%s\n' "$SH_HOME_EXEC" > "$SH_HOME/.home_exec" 2>/dev/null || true
    else
        SH_HOME_EXEC=unknown
        if [ -r "$SH_HOME/.home_exec" ]; then
            sh_sp_he=''
            IFS= read -r sh_sp_he < "$SH_HOME/.home_exec" 2>/dev/null || sh_sp_he=''
            case "$sh_sp_he" in
                yes|no) SH_HOME_EXEC=$sh_sp_he ;;
            esac
        fi
    fi

    # # STOP: A RECORDED EXEC ROOT IS REUSED, BECAUSE FREE SPACE IS NOT STABLE.
    # The first plan picks the roomiest (issue #37), but free space moves as
    # views and caches are written, so a fresh ranking on every install could
    # migrate the exec root and orphan the views, caches, launchers and PATH
    # entry on the old one. env.sh records the choice; while that root still runs
    # a file it wins, whether or not it is the roomiest. Only a root that is
    # gone or refuses exec falls back to the ranking, and --exec / SANDHOME_EXEC
    # overrides both.
    sh_sp_recorded=$(sh_space_recorded_exec)
    sh_sp_candidates=$(sh_exec_candidates)
    if [ -n "$sh_sp_recorded" ]; then
        case " $sh_sp_candidates " in
            *" $sh_sp_recorded "*) ;;
            *) sh_sp_candidates="$sh_sp_recorded $sh_sp_candidates" ;;
        esac
    fi
    sh_sp_first_working=''
    sh_sp_first_roomy=''
    sh_sp_roomy_mb=0
    sh_sp_sticky=''
    sh_sp_explicit_ok=0
    sh_sp_tried=''
    for sh_sp_candidate in $sh_sp_candidates; do
        [ -n "$sh_sp_candidate" ] || continue
        sh_sp_tried="$sh_sp_tried$sh_sp_candidate "
        # # STOP: THE FLAG IS INITIALISED BEFORE THE BRANCH THAT MAY `continue`
        # PAST IT, BECAUSE `set -u` IS A RUNTIME ABORT AND NOT A LINT WARNING.
        # The read-only branch below does `continue` when the candidate is not a
        # directory, and the room check that reads this flag is outside it, so a
        # read-only plan that saw a missing candidate first died with
        # "sh_sp_fake: parameter not set" and the command exited 0 on the way
        # out, having printed nothing. Every variable a loop reads after a
        # conditional `continue` is assigned before the branch, not in it.
        sh_sp_fake=''
        if [ "$sh_sp_create" = 1 ]; then
            if ! mkdir -p "$sh_sp_candidate" 2>/dev/null; then
                continue
            fi
            # # STOP: A CANDIDATE THIS CALL JUST CREATED IS NOT EVIDENCE OF ROOM,
            # AND THE GATE BELOW IS THE OTHER HALF OF THAT. The directory did not
            # exist a moment ago, so its free space was measured on a filesystem
            # that had just been given an empty directory, and preferring it on
            # that number would rank what we made above a real tmpfs with
            # gigabytes on it. The flag marks the created ones and the room check
            # SKIPS them.
            #
            # The first version of this got the sense backwards: it set the flag
            # on the created candidates and then ran the room check only for
            # those, so it preferred exactly the directories it had just made and
            # ignored every real one. The original code measured all of them and
            # was right to; what changed is only that the ones we created are
            # excluded. tests/space.sh drives the two shapes.
            [ -d "$sh_sp_candidate" ] || sh_sp_fake=yes
        else
            # Read-only: a directory that is not there is not a candidate, and
            # is not brought into being to become one.
            [ -d "$sh_sp_candidate" ] || continue
        fi
        if ! sh_dir_writable "$sh_sp_candidate"; then
            continue
        fi
        if ! sh_exec_probe "$sh_sp_candidate"; then
            continue
        fi
        if [ -n "${SANDHOME_EXEC:-}" ] && [ "$sh_sp_candidate" = "$SANDHOME_EXEC" ]; then
            sh_sp_explicit_ok=1
        fi
        if [ -z "$sh_sp_first_working" ]; then
            sh_sp_first_working=$sh_sp_candidate
        fi
        # The recorded root is sticky as soon as it is writable and runs a file.
        # Free space does NOT unseat it: migrating an established root orphans
        # every view, cache and launcher that already lives on it, which is a
        # worse failure than a later install running out of room on the root the
        # caller already has. A root that is gone or refuses exec falls through
        # to the ranking, and --exec still moves it deliberately.
        if [ -n "$sh_sp_recorded" ] && [ "$sh_sp_candidate" = "$sh_sp_recorded" ]; then
            sh_sp_sticky=$sh_sp_candidate
        fi
        if [ -z "$sh_sp_fake" ]; then
            sh_sp_free=$(sh_free_mb "$sh_sp_candidate")
            case "$sh_sp_free" in
                ''|*[!0-9]*) sh_sp_free=0 ;;
            esac
            # # STOP: THE ROOMIEST CANDIDATE WINS, NOT THE FIRST. The old rule
            # kept the first candidate over the floor and threw the rest away,
            # so the choice was decided by the ORDER of sh_exec_candidates rather
            # than by what a toolchain needs. /dev/shm is listed before /tmp, and
            # /dev/shm on a container is a 256MB tmpfs, so a host with 31GB of
            # exec-capable space in /tmp got a 135MB exec root and then:
            #   sandhome: [!] /dev/shm has 135MB free and the .../toolchains/rust
            #   view wants about 238MB; set SANDHOME_EXEC to a roomy root
            # (issue #50). The floor is a qualification threshold, not a target.
            # Keeping the maximum also makes the "no candidate had NMB free"
            # warning below mean what it says: the ROOMIEST one fell short.
            if [ "$sh_sp_free" -ge "$SANDHOME_MIN_EXEC_MB" ] && [ "$sh_sp_free" -gt "$sh_sp_roomy_mb" ]; then
                sh_sp_roomy_mb=$sh_sp_free
                sh_sp_first_roomy=$sh_sp_candidate
            fi
        fi
    done


    # # NOTE: THE TWO ROOTS COLLAPSE ONLY WHEN NOTHING WAS ASKED FOR EXPLICITLY. An
    # operator who named SANDHOME_EXEC has said where executables must go, and
    # silently overriding that with the home root is how a small root becomes a
    # surprise. A named root that cannot be used is refused by name rather than
    # swapped for a different one.
    # # STOP: AN EXPLICITLY NAMED ROOT IS CREATED BEFORE IT IS JUDGED. The loop
    # above tests `SANDHOME_EXEC` only after a successful mkdir, and a nested
    # path whose parent does not exist fails that mkdir, so a caller who named
    # `$work/unk-x` was told the root "is not writable or does not allow exec"
    # about a directory that simply had not been made. The create plan makes it
    # and asks again. A read-only plan does not, and says so instead.
    if [ -n "${SANDHOME_EXEC:-}" ] && [ "$sh_sp_create" = 1 ] && [ "$sh_sp_explicit_ok" != 1 ]; then
        if mkdir -p "$SANDHOME_EXEC" 2>/dev/null &&
           sh_dir_writable "$SANDHOME_EXEC" &&
           sh_exec_probe "$SANDHOME_EXEC"; then
            SH_EXEC=$SANDHOME_EXEC
            sh_sp_explicit_ok=1
            SH_EXEC_UNUSABLE=0
        fi
    fi

    if [ -n "${SANDHOME_EXEC:-}" ]; then
        if [ "$sh_sp_explicit_ok" = 1 ]; then
            SH_EXEC=$SANDHOME_EXEC
        elif [ "$sh_sp_create" = 0 ]; then
            # # NOTE: A READ-ONLY PLAN REFUSES BY NAME RATHER THAN DYING. `sandhome
            # version` with an unwritable SANDHOME_EXEC used to exit 2 from
            # startup, before the dispatcher, so the usage text never printed and
            # the two commands an operator reaches for when a machine is broken
            # were the two that could not run on one. The plan now reports what it
            # found and the CALLER decides whether that is fatal; only a command
            # that installs something turns this into a refusal.
            SH_EXEC=$SANDHOME_EXEC
            SH_EXEC_UNUSABLE=1
        else
            sh_die "SANDHOME_EXEC=$SANDHOME_EXEC is not writable or does not allow exec"
        fi
    elif [ "$sh_sp_create" = 0 ] && [ -n "$sh_sp_recorded" ] && [ ! -d "$sh_sp_recorded" ]; then
        # # STOP: A READ-ONLY PLAN NAMES THE RECORDED ROOT EVEN WHEN IT IS GONE.
        # It used to fall through to the ranking, so a wiped exec root (the
        # exact case `resume` exists for) made every read-only command --
        # status, report, doctor, and the startup plan that feeds resume --
        # answer about some OTHER writable root left on the box while env.sh
        # still named the missing one. Measured on this tree, after
        # `rm -rf $exec_root` with env.sh recording it: status printed
        # exec=/workspace/.sandhome/exec (a stale sibling from an earlier run)
        # with ready=yes; doctor judged that sibling; and `resume` baked the
        # sibling into SANDHOME_EXEC, rebuilt every view THERE, and sh_env_write
        # then overwrote env.sh with the sibling, losing the recorded root for
        # good. Naming the recorded root as unusable is the machine as
        # configured: the caller decides what to do. sh_cmd_needs_roots
        # re-plans with a create plan, which mkdirs the recorded root back,
        # and doctor fails by name with the resume hint.
        SH_EXEC=$sh_sp_recorded
        SH_EXEC_UNUSABLE=1
    elif [ "$sh_sp_create" = 0 ] && [ -n "$sh_sp_sticky" ]; then
        # STOP: A READ-ONLY PLAN REPORTS THE RECORDED ROOT BEFORE RE-DECIDING.
        # The create plan collapses the roots when the home runs binaries, but
        # a read-only answer must describe the machine as configured, not pick
        # a new root: the bootstrap may have split deliberately (an explicit
        # --exec on an exec-capable home), and collapsing here orphaned the
        # views, caches and launchers on the recorded root. Measured: a bare
        # `eval "$(sandhome env)"` shell reported SANDHOME_EXEC as the home
        # while env.sh named the exec root the setup had used, because the
        # recorded home_exec=yes outranked the sticky recorded root.
        SH_EXEC=$sh_sp_sticky
    elif [ "$SH_HOME_EXEC" = yes ]; then
        SH_EXEC=$SH_HOME
    elif [ -n "$sh_sp_sticky" ]; then
        SH_EXEC=$sh_sp_sticky
    elif [ -n "$sh_sp_first_roomy" ]; then
        SH_EXEC=$sh_sp_first_roomy
    elif [ -n "$sh_sp_first_working" ]; then
        SH_EXEC=$sh_sp_first_working
        sh_warn "no candidate had ${SANDHOME_MIN_EXEC_MB}MB free; using $SH_EXEC anyway"
    else
        # Nothing on this machine both runs a file and can be written. A create
        # run cannot continue; a read-only run can still ANSWER, and the answer
        # is the finding.
        if [ "$sh_sp_create" = 1 ]; then
            sh_die "no writable mount here both allows exec and can be written; set SANDHOME_EXEC to one"
        fi
        SH_EXEC=''
        SH_EXEC_UNUSABLE=1
    fi

    if [ -n "$SH_EXEC" ]; then
        SH_EXEC_BIN="$SH_EXEC/bin"
        SH_EXEC_VIEWS="$SH_EXEC/views"
    else
        SH_EXEC_BIN=''
        SH_EXEC_VIEWS=''
    fi
    SH_HOME_TOOLCHAINS="$SH_HOME/toolchains"
    SH_HOME_TMP="$SH_HOME/tmp"
    if [ "$sh_sp_create" = 1 ]; then
        mkdir -p "$SH_EXEC_BIN" "$SH_EXEC_VIEWS" "$SH_HOME_TOOLCHAINS" "$SH_HOME_TMP" 2>/dev/null || \
            sh_die "cannot create the sandhome directories below $SH_HOME and $SH_EXEC"
    fi

    # What the plan actually tried, and why it settled where it did. `doctor`
    # and the bootstrap log read these instead of re-deriving the list.
    SH_EXEC_TRIED=$sh_sp_tried
    SH_EXEC_CHOSEN_REASON=collapsed
    if [ -z "$SH_EXEC" ]; then
        SH_EXEC_CHOSEN_REASON=none
    fi
    if [ -n "$SH_EXEC" ] && [ "$SH_EXEC" != "$SH_HOME" ]; then
        SH_EXEC_CHOSEN_REASON=split
    fi
    if [ -n "${SANDHOME_EXEC:-}" ] && [ "$SH_EXEC" = "$SANDHOME_EXEC" ]; then
        SH_EXEC_CHOSEN_REASON=explicit
    fi
    SH_PLAN_CREATED=$sh_sp_create
    export SH_HOME SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TOOLCHAINS SH_HOME_TMP
    export SH_HOME_EXEC SH_EXEC_TRIED SH_EXEC_CHOSEN_REASON SH_PLAN_CREATED SH_EXEC_UNUSABLE
    return 0
}

# sh_space_need MB [WHERE] -> refuse to proceed when there is plainly not enough
# room for the named install. WHERE is `exec`, `home` or `both` (default both).
# sh_total_mb DIR -> the total size of the filesystem holding DIR, in megabytes,
# or nothing. sh_free_mb reads df's Available column; this reads its 1024-blocks
# column, and the pair is what turns "37MB free" into "37MB of 245MB, 15%".
# Without the total a low-space warning can only be absolute, and absolute alone
# is wrong in both directions: 40MB is critical on a 256MB tmpfs and unremarkable
# on a 4TB disk.
# STOP: THIS READS THE SIZE COLUMN AND NOT THE USED COLUMN. df -Pk prints
# Filesystem 1024-blocks Used Available Capacity Mounted, so the second field is
# the total and the third is what is used. The old form named the third field
# "total" and returned it, so `sandhome space` printed exec_total_mb=435 on a
# 489MB tmpfs with 434MB used, and home_total_mb smaller than home_free_mb
# (issue #69). The duplicate in lib/common.sh always read the right column;
# this one shadowed it because bin/sandhome sources space.sh after common.sh.
sh_total_mb() {
    df -Pk "$1" 2>/dev/null | {
        if read -r sh_tm_dev sh_tm_total sh_tm_used sh_tm_free sh_tm_rest; then
            if read -r sh_tm_dev sh_tm_total sh_tm_used sh_tm_free sh_tm_rest; then
                case "$sh_tm_total" in
                    ''|*[!0-9]*) printf '' ;;
                    *) printf '%s' $((sh_tm_total / 1024)) ;;
                esac
            fi
        fi
    }
}

# sh_space_status [DIR] -> one word naming how much room is left in DIR:
# ok, low, critical, full, or unknown.
#
# # STOP: THE THRESHOLDS ARE DECIDED ON MAGABYTES BELOW 1GB AND ON BOTH A SHARE
# AND A FLOOR ABOVE IT, AND BOTH HALVES OF THAT ARE NECESSARY. Each was measured
# on this host, and in both directions:
#
#   - a share alone is nonsense at scale. This host's 419GB disk sat at 6.6% free
#     with 393GB still on it; a share-only rule called that `low` and failed
#     `doctor` on a freshly built home that had 27GB free.
#   - megabytes alone is nonsense on a small root. 10% of a 207MB tmpfs is 20MB,
#     so a share rule calls it "fine at 17%" and the next build is refused with
#     "no space left on device".
#
# So: a root under SANDHOME_PCT_MEANINGFUL_MB (1GB) is judged on megabytes
# alone; above it, `low` needs the share under SANDHOME_LOW_EXEC_PCT (10) AND
# the free space under SANDHOME_LOW_EXEC_MB (100), and `critical` needs the share
# under 5% AND the free space under SANDHOME_CRIT_MB (32). 40MB of 4TB is
# 0.001% free and is correctly `low`: there is nothing there to build with.
#
# # STOP: THIS EXISTS BECAUSE THE FAILURE IS SILENT UNTIL A BUILD DIES, AND
# SOMETIMES NOT EVEN THEN. Measured on this host, exec root /dev/shm at 245MB:
#
#   df: /dev/shm  86% full, 37MB free
#   sandhome doctor   -> doctor_failures=0
#   sandhome report   -> exec_free_mb=36      (printed, not flagged)
#   go build -o $SANDHOME_EXEC/x .
#     go build: copying .../a.out to /dev/shm/x: no space left on device
#     go exit=0                                   <- SUCCESS, no artifact
#
# Three failures in one. Nothing warned while the root drained. The build then
# reported exit 0 having produced nothing, so a script or an agent that checks
# the status code sees a success. And the only check that did fire, on a
# completely full root, was `exec_runs=no` - a true statement about a mount
# that cannot hold a file, but a sentence about exec, not about space, and it
# fires at 0MB rather than at the point where the work stops.
sh_space_status() {
    sh_ss_dir=${1:-${SH_EXEC:-/tmp}}
    sh_ss_free=$(sh_free_mb "$sh_ss_dir" 2>/dev/null)
    case "$sh_ss_free" in
        ''|*[!0-9]*) printf 'unknown'; return 0 ;;
    esac
    if [ "$sh_ss_free" -le 0 ]; then
        printf 'full'
        return 0
    fi
    sh_ss_low=${SANDHOME_LOW_EXEC_MB:-100}
    sh_ss_crit=${SANDHOME_CRIT_MB:-32}
    sh_ss_lowpct=${SANDHOME_LOW_EXEC_PCT:-10}
    sh_ss_pct_mb=${SANDHOME_PCT_MEANINGFUL_MB:-1024}
    # The total, when df will say it. sh_free_mb reads the fourth column only.
    sh_ss_total=$(sh_total_mb "$sh_ss_dir" 2>/dev/null)
    case "$sh_ss_total" in
        ''|*[!0-9]*) sh_ss_total=0 ;;
    esac
    sh_ss_lowpct_hits=no
    if [ "$sh_ss_total" -lt "$sh_ss_pct_mb" ]; then
        # # STOP: A SMALL ROOT IS JUDGED ON MEGABYTES, NOT ON ITS SHARE.
        # 10% of a 207MB tmpfs is 20MB, so a share rule calls a 207MB root with
        # 36MB free "fine at 17%", and the next rust view or Go build is refused
        # with "no space left on device". On a root this size the absolute floor
        # is the only honest question: is there enough room for the next thing.
        if [ "$sh_ss_free" -lt "$sh_ss_crit" ]; then
            printf 'critical'
            return 0
        fi
        if [ "$sh_ss_free" -lt "$sh_ss_low" ]; then
            printf 'low'
            return 0
        fi
        printf 'ok'
        return 0
    fi
    # # STOP: A LARGE ROOT IS JUDGED ON ITS SHARE **AND** ITS ABSOLUTE SIZE, AND
    # NEITHER ALONE WORKS. A pure share rule is nonsense at scale: this host's
    # 419GB disk sitting at 6.6% free still has 393GB on it, and `low` fired on
    # it, which is the warning nobody believes the second time they see one. A
    # pure absolute rule is nonsense at the other end, which is why the small-root
    # branch above exists.
    #
    # So a large root is low when the share is under SANDHOME_LOW_EXEC_PCT AND
    # the free space is under SANDHOME_LOW_EXEC_MB. Both halves are needed for
    # either failure to be real: a share under 10% of 419GB is 41GB, which is
    # not low, and 40MB on a disk is under 10% of almost anything, which is
    # exactly the case that must warn.
    #
    # The cross-multiplied comparison is a readability choice, not a correctness
    # one: for a strict `<`, truncating division is equivalent, since (a/k) < c
    # holds exactly when a < k*c. It is written this way so the threshold stays a
    # readable number in the source instead of a divisor.
    if [ $((sh_ss_free * 100)) -lt $((sh_ss_total * sh_ss_lowpct)) ] &&
       [ "$sh_ss_free" -lt "$sh_ss_low" ]; then
        sh_ss_lowpct_hits=yes
    fi
    if [ $((sh_ss_free * 100)) -lt $((sh_ss_total * 5)) ] &&
       [ "$sh_ss_free" -lt "$sh_ss_crit" ]; then
        printf 'critical'
        return 0
    fi
    # Critical on a large root needs BOTH a tiny share and too little room for
    # the next write. Share alone is not enough, and the reason is the same
    # truncation: 40MB of 4TB is 0.001% of the disk, which is under 5%, and
    # reporting a 4TB disk as critical for having 40MB on it is a warning nobody
    # believes the second time they see one.
    if [ $((sh_ss_free * 100)) -lt $((sh_ss_total * 5)) ] &&
       [ "$sh_ss_free" -lt "$sh_ss_crit" ]; then
        printf 'critical'
        return 0
    fi
    if [ "$sh_ss_free" -lt "$sh_ss_crit" ]; then
        printf 'critical'
        return 0
    fi
    # # STOP: ON A LARGE ROOT THE SHARE ALONE DECIDES "low", WITH NO ABSOLUTE
    # FLOOR BESIDE IT. The rule was `free < low AND share < lowpct`, and the
    # absolute half made the percentage meaningless above 100MB: 390GB free of a
    # 4TB disk is 9.75% used, which is under the 10% line, and the clause
    # answered "ok" because 390000 is not less than 100. A root this size is
    # reported on how full it is, which is the only question at this scale, and
    # the megabytes are already covered by the critical test above.
    if [ "$sh_ss_lowpct_hits" = yes ]; then
        printf 'low'
        return 0
    fi
    printf 'ok'
}

# sh_space_advise [DIR] -> say something on stderr when a root is low, critical
# or full, and say what to DO about it. 0 always, so a caller can use it as a
# statement and decide for itself whether being quiet is allowed.
#
# The advice is a command, not a description. "the exec root is full" leaves a
# consumer with nothing to type; the whole point of hearing about it early is
# that there is still time to act on it.
#
# # STOP: IT SAYS IT ONCE PER PROCESS. Every toolchain that installs writes a
# fragment, and each write calls this, so a multi-toolchain run on a low root
# (the count depends on the toolset, so it is not named here) produced the same
# line once per fragment - measured, and the same line over and over.
# A repeated warning is not a louder warning, it is noise that trains the reader
# to scroll past the one line that mattered. The state is cached per process and
# the second caller is silent; a new process, and therefore a new command, says
# it again.
sh_space_advise() {
    sh_sa_dir=${1:-${SH_EXEC:-/tmp}}
    sh_sa_status=$(sh_space_status "$sh_sa_dir")
    case "$sh_sa_status" in
        ok|unknown) return 0 ;;
    esac
    case " ${SH_SPACE_ADVISED:-} " in
        *" $sh_sa_status "*) return 0 ;;
    esac
    SH_SPACE_ADVISED="${SH_SPACE_ADVISED:-} $sh_sa_status"
    sh_sa_free=$(sh_free_mb "$sh_sa_dir" 2>/dev/null)
    case "$sh_sa_free" in ''|*[!0-9]*) sh_sa_free='?' ;; esac
    # # STOP: THE ADVICE NAMES WHAT ACTUALLY HOLDS THE SPACE, IN THE ORDER THAT
    # WORKS. `gc` is named second, not first, because on a root that is full of
    # build output it reclaims nothing: measured here, `sandhome gc --dry-run`
    # reported "nothing was removed" on a root where the space was in a rustc
    # object files and a Go build cache the CONSUMER created. gc's own caches
    # (`cache/`, `tmp/`, `go-bin/`) were 0 bytes. Telling someone to run gc first
    # on a full root wastes the one moment they have, and then they run the real
    # fix anyway.
    case "$sh_sa_status" in
        full)
            sh_warn "$sh_sa_dir is FULL (0MB free). Builds and installs that write there fail with 'no space left on device'. The space is usually build output you own - a target/ directory, a GOCACHE, a staged tarball - so removing that is the first thing to try; 'du -sh $sh_sa_dir/* | sort -h | tail' names it. 'sandhome gc' then reclaims sandhome's own caches. If that is not enough, re-run the setup with '--exec DIR' on a roomy exec-capable path, or set SANDHOME_EXEC to one."
            ;;
        critical)
            sh_warn "$sh_sa_dir has only ${sh_sa_free}MB free, which will not hold a build. The exec root carries GOCACHE, GOBIN, CARGO_TARGET_DIR, NPM_CONFIG_PREFIX and every build artifact, so it fills with YOUR output first: 'du -sh $sh_sa_dir/* | sort -h | tail' names what is holding it, and removing that is the first thing to try. 'sandhome gc' reclaims sandhome's own caches. To move everything: re-run the setup with '--exec DIR' naming a roomy exec-capable path. 'sandhome space --probe' lists the candidates with their free space."
            ;;
        low)
            sh_warn "$sh_sa_dir has ${sh_sa_free}MB free, which is low for builds. A cross-target or release build will run out. 'du -sh $sh_sa_dir/* | sort -h | tail' names what is holding it; 'sandhome space --probe' lists roomier candidates and 'sandhome gc' reclaims sandhome's own caches."
            ;;
    esac
    return 0
}

# sh_space_need() -> refuse a write the root has no room for.
sh_space_need() {
    sh_sn_mb=$1
    sh_sn_where=${2:-both}
    case "$sh_sn_where" in
        exec|both)
            sh_sn_free=$(sh_free_mb "$SH_EXEC")
            case "$sh_sn_free" in ''|*[!0-9]*) sh_sn_free=0 ;; esac
            if [ "$sh_sn_free" -lt "$sh_sn_mb" ]; then
                sh_warn "$SH_EXEC has ${sh_sn_free}MB free and this wants ${sh_sn_mb}MB on the exec root"
                return 1
            fi
            ;;
    esac
    case "$sh_sn_where" in
        home|both)
            sh_sn_free=$(sh_free_mb "$SH_HOME")
            case "$sh_sn_free" in ''|*[!0-9]*) sh_sn_free=0 ;; esac
            if [ "$sh_sn_free" -lt "$sh_sn_mb" ]; then
                sh_warn "$SH_HOME has ${sh_sn_free}MB free and this wants ${sh_sn_mb}MB on the home root"
                return 1
            fi
            ;;
    esac
    return 0
}

# sh_view_copy_kb SRC -> the KB that sh_promote_tree will actually COPY out of
# SRC. It is the size the exec root must hold, and it is NOT the size of the
# tree: shared objects (.so/.rlib/.a), data files and every symlink are
# symlinked back to the home and cost the exec root nothing, and the largest
# entries in a toolchain are exactly those (librustc_driver.so, libLLVM). A gate
# that used `du -sk` over the whole tree therefore over-counted by hundreds of
# megabytes and refused rust on a root the real view fits in. The walk mirrors
# sh_promote_tree's copy rule and is a queue for the same reason (rule 5, no
# recursion in POSIX sh). du reads disk usage, so a compressed home prices
# below what an uncompressed exec root pays; the gate's headroom covers the
# difference, and the feas total inherits the same approximation.
sh_view_copy_kb() {
    sh_vck_src=$1
    if [ ! -d "$sh_vck_src" ] || ! sh_have du; then
        printf ''
        return 0
    fi
    sh_vck_total=0
    sh_vck_queue=$(sh_tmp_file "${SH_HOME_TMP:-${TMPDIR:-/tmp}}" viewcopy)
    printf '%s\n' "$sh_vck_src" > "$sh_vck_queue" 2>/dev/null || {
        printf ''
        return 0
    }
    while IFS= read -r sh_vck_d; do
        [ -n "$sh_vck_d" ] || continue
        for sh_vck_e in "$sh_vck_d"/* "$sh_vck_d"/.[!.]* "$sh_vck_d"/..?*; do
            [ -e "$sh_vck_e" ] || [ -L "$sh_vck_e" ] || continue
            if [ -d "$sh_vck_e" ] && [ ! -L "$sh_vck_e" ]; then
                printf '%s\n' "$sh_vck_e" >> "$sh_vck_queue"
                continue
            fi
            # A symlink is mirrored as a link, never copied.
            [ -L "$sh_vck_e" ] && continue
            sh_is_exec_file "$sh_vck_e" || continue
            sh_vck_rel=${sh_vck_e#"$sh_vck_src"/}
            # In launch mode the view holds a launcher copy per executable,
            # priced off the helper, not off the payload: a 15MB rustc costs
            # the exec root 20KB. sh_memexec_template_kb answers 32 when the
            # helper is not there yet, which over-prices rather than
            # under-prices the gate. A copy-listed executable is priced at
            # its real size: it lands as bytes, so the gate must hold room.
            #
            # STOP: AND SO IS EVERY EXECUTABLE THE LAUNCHER CANNOT REPLACE, WHICH
            # MEANS EVERY NON-ELF ONE. This gate must mirror sh_promote_tree's
            # branch exactly, because it is what decides whether a root can hold
            # the view (sh_view_need). It did not, and it under-stated the view by
            # the whole payload. Measured here on a tree of one 10MB executable
            # .py plus 30 small ELF programs:
            #   sh_view_copy_kb, launch mode -> 992 KB
            # while sh_promote_tree in launch mode COPIED the .py (a launcher
            # cannot hold it, issue #173) and stamped the rest, so the view it
            # wrote was about 11200KB. The gate passed a root that then ran out
            # of space part-way through the walk, which is the one outcome the
            # gate exists to prevent. Pricing a non-ELF executable at its real
            # size closes it, and the two functions now agree by construction.
            if [ "${SH_VIEW_MODE:-copy}" = launch ] && ! sh_copy_listed "$sh_vck_rel" && sh_is_elf_exec "$sh_vck_e"; then
                sh_vck_k=$(sh_memexec_template_kb 2>/dev/null)
                case "$sh_vck_k" in
                    ''|*[!0-9]*) sh_vck_k=32 ;;
                esac
                sh_vck_total=$((sh_vck_total + sh_vck_k))
                continue
            fi
            sh_vck_k=$(sh_size_kb "$sh_vck_e" 2>/dev/null)
            case "$sh_vck_k" in
                ''|*[!0-9]*) continue ;;
            esac
            sh_vck_total=$((sh_vck_total + sh_vck_k))
        done
    done < "$sh_vck_queue"
    rm -f "$sh_vck_queue" 2>/dev/null
    printf '%s' "$sh_vck_total"
}

# sh_view_current SRC DST -> 0 when DST already mirrors SRC, so a rebuild
# would change nothing. Every regular file under SRC must exist under DST
# and be no older than it (`-nt` is POSIX, no stat needed); symlinks and
# directories must exist. A wrapper the module wrote into the view after the
# mirror (rust's --sysroot wrapper) is NEWER than the home file and passes:
# current means "nothing to do", not "identical bytes". The walk is a
# queue, like every other walk here (rule 5, no recursion).
#
# This is what keeps a no-op re-run green on a small exec root (issue #71):
# the size gate refuses a rebuild the root cannot hold, but a view that is
# already current needs no rebuild at all, so gating it is refusing work
# that was never going to happen. The framework's post-promote probe still
# runs afterwards, so a view that is current-but-broken is caught, not
# blessed.
sh_view_current() {
    sh_vc_src=$1
    sh_vc_dst=$2
    [ -d "$sh_vc_src" ] || return 1
    [ -d "$sh_vc_dst" ] || return 1
    sh_vc_queue=$(sh_tmp_file "${SH_HOME_TMP:-${TMPDIR:-/tmp}}" viewcur)
    printf '%s\n' "$sh_vc_src" > "$sh_vc_queue" 2>/dev/null || return 1
    sh_vc_ok=0
    while IFS= read -r sh_vc_d; do
        [ -n "$sh_vc_d" ] || continue
        for sh_vc_e in "$sh_vc_d"/* "$sh_vc_d"/.[!.]* "$sh_vc_d"/..?*; do
            [ -e "$sh_vc_e" ] || [ -L "$sh_vc_e" ] || continue
            sh_vc_rel=${sh_vc_e#"$sh_vc_src"/}
            if [ -d "$sh_vc_e" ] && [ ! -L "$sh_vc_e" ]; then
                [ -e "$sh_vc_dst/$sh_vc_rel" ] || { sh_vc_ok=1; break; }
                printf '%s\n' "$sh_vc_e" >> "$sh_vc_queue"
                continue
            fi
            [ -e "$sh_vc_dst/$sh_vc_rel" ] && [ ! "$sh_vc_e" -nt "$sh_vc_dst/$sh_vc_rel" ] || { sh_vc_ok=1; break; }
            # An executable that the view holds as a symlink back into the
            # HOME tree is not current: both modes land executables as
            # regular files (copies or launcher stamps), and a link to the
            # source is the stale remainder of an older mirror - exactly what
            # the copy branch removes before writing. A link whose target
            # stays inside the view (an in-tree relative link remapped onto
            # it, like a proxy to a toolchain binary) is legitimate and
            # passes; data files stay symlinks either way.
            if sh_is_exec_file "$sh_vc_e" && [ -L "$sh_vc_dst/$sh_vc_rel" ]; then
                if sh_have readlink; then
                    sh_vc_t=$(readlink "$sh_vc_dst/$sh_vc_rel" 2>/dev/null)
                    case "$sh_vc_t" in
                        /*) : ;;
                        *)
                            case "$sh_vc_rel" in
                                */*) sh_vc_t=$(sh_lex_normalize "$sh_vc_dst/${sh_vc_rel%/*}/$sh_vc_t") ;;
                                *) sh_vc_t=$(sh_lex_normalize "$sh_vc_dst/$sh_vc_t") ;;
                            esac
                            ;;
                    esac
                    case "$sh_vc_t" in
                        "$sh_vc_src"/*) sh_vc_ok=1; break ;;
                    esac
                else
                    sh_vc_ok=1; break
                fi
            fi
            # In launch mode mtime cannot tell a launcher from a real copy,
            # so a module that newly names a copy-list entry (or a rebuilt
            # helper) would leave a working-looking view holding the wrong
            # bytes. cmp closes it, AND IT CLOSES THE MODE FLIP BOTH WAYS: a
            # launcher stamped under launch mode is not a copy-mode view, and
            # a real copy left by copy mode is not a launch-mode view, so
            # `SANDHOME_VIEW_MODE=copy sandhome install NAME` (or the reverse)
            # rebuilds instead of being told the view is already current
            # (issue #113). A file that matches neither the helper nor its
            # home source is a wrapper the module wrote after the mirror
            # (rust's --sysroot wrapper), and stays current while it is newer
            # than the helper. Without cmp the mtime verdict above stands.
            if sh_have cmp && sh_is_exec_file "$sh_vc_e"; then
                if sh_copy_listed "$sh_vc_rel"; then
                    cmp -s "$sh_vc_e" "$sh_vc_dst/$sh_vc_rel" 2>/dev/null || { sh_vc_ok=1; break; }
                else
                    sh_vc_help=${SH_EXEC_BIN:-}/sandhome-memexec
                    if [ -f "$sh_vc_help" ]; then
                        if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
                            if cmp -s "$sh_vc_help" "$sh_vc_dst/$sh_vc_rel" 2>/dev/null; then
                                :
                            elif cmp -s "$sh_vc_e" "$sh_vc_dst/$sh_vc_rel" 2>/dev/null; then
                                # A real copy of an ELF here is a copy-mode
                                # leftover and stales the view (issue #113). A
                                # real copy of a NON-ELF is the current launch
                                # shape, because a launcher cannot hold one and
                                # sh_promote_tree copies it (issue #173). Reading
                                # it as stale instead would rebuild every view on
                                # every run, forever, for a difference that does
                                # not exist. So this branch now asks the same
                                # question sh_promote_tree asks.
                                if sh_is_elf_exec "$sh_vc_e"; then sh_vc_ok=1; break; fi
                            elif [ ! "$sh_vc_dst/$sh_vc_rel" -nt "$sh_vc_help" ]; then
                                sh_vc_ok=1; break
                            fi
                        elif cmp -s "$sh_vc_help" "$sh_vc_dst/$sh_vc_rel" 2>/dev/null; then
                            sh_vc_ok=1; break
                        fi
                    fi
                fi
            fi
        done
        [ "$sh_vc_ok" = 0 ] || break
    done < "$sh_vc_queue"
    rm -f "$sh_vc_queue" 2>/dev/null
    [ "$sh_vc_ok" = 0 ]
}

# sh_view_need SRC [DST] -> refuse before mirroring when the exec root plainly
# cannot hold the view. Uses the free-space number the planner already measures
# and the COPY size of SRC (sh_view_copy_kb), not its whole-tree size, because
# only regular executables are copied (issue #33 constrains #29: a 172MB zig
# binary does not fit a 245MB tmpfs that already holds views plus GOCACHE).
# When DST names the view being replaced, its present size is credited: the
# rebuild frees those bytes first, so charging the gross size refuses rebuilds
# that fit (issue #71).
sh_view_need() {
    sh_vn_src=$1
    sh_vn_dst=${2:-}
    [ -d "$sh_vn_src" ] || return 0
    sh_vn_need=$(sh_view_copy_kb "$sh_vn_src" 2>/dev/null)
    case "$sh_vn_need" in
        ''|*[!0-9]*) return 0 ;;
    esac
    # du reports KB; keep 20MB headroom for the copy itself plus a build cache.
    sh_vn_need_mb=$((sh_vn_need / 1024 + 20))
    sh_vn_free=$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)
    case "$sh_vn_free" in
        ''|*[!0-9]*) sh_vn_free=0 ;;
    esac
    if [ -n "$sh_vn_dst" ] && [ -d "$sh_vn_dst" ] && sh_have du; then
        sh_vn_have=$(du -sk "$sh_vn_dst" 2>/dev/null | { read -r sh_vn_h _ || :; printf '%s' "$sh_vn_h"; })
        case "$sh_vn_have" in
            ''|*[!0-9]*) ;;
            *) sh_vn_free=$((sh_vn_free + sh_vn_have / 1024)) ;;
        esac
    fi
    if [ "$sh_vn_free" -lt "$sh_vn_need_mb" ]; then
        sh_warn "$SH_EXEC has ${sh_vn_free}MB free and the $sh_vn_src view wants about ${sh_vn_need_mb}MB; set SANDHOME_EXEC to a roomy root (--exec DIR) and re-run"
        return 1
    fi
    return 0
}

# sh_is_exec_file PATH -> 0 for a regular file that must be COPIED into an exec
# view rather than symlinked. # STOP: A SHARED OBJECT IS NOT ONE: mmap(PROT_EXEC) from
# a noexec mount is allowed even where execve is not, which is the measurement
# this whole split rests on, and copying a 144MB librustc_driver or a 191MB
# libLLVM would not fit on the small root it would be copied to.
sh_is_exec_file() {
    [ -f "$1" ] || return 1
    [ -x "$1" ] || return 1
    case "$1" in
        *.so|*.so.*|*.dylib|*.dll|*.a|*.rlib|*.rmeta|*.o) return 1 ;;
    esac
    return 0
}

# sh_size_kb FILE -> the KB a COPY of FILE will occupy on the exec root, or
# nothing when the size cannot be read. Three readers, in order, because the
# difference between them is not academic on a compressed root.
#
# STOP: `du` REPORTS BLOCKS AND A COPY PAYS APPARENT BYTES. Measured here on the
# zfs root this tree runs on, a 10MB file of repeated digits:
#   du -sk                                ->   341 KB
#   du -sk --apparent-size                -> 10250 KB
#   the copy sh_promote_tree then writes  -> 10250 KB
# so the old reader under-priced a file this gate exists to protect by a factor
# of thirty, and the gate passed roots that ran out of space part-way through the
# walk. `wc -c` is the apparent size, is POSIX, and is already the reader this
# tree uses elsewhere (sh_file_bytes), so it leads. `du -sk` stays as the
# fallback for a host without wc, and over-stating is the safe direction there:
# it refuses a root it could have used, which the operator can widen with
# --exec, while under-stating writes to a root that is already full.
sh_size_kb() {
    sh_sk_f=$1
    [ -f "$sh_sk_f" ] || return 1
    sh_sk_b=$(sh_file_bytes "$sh_sk_f" 2>/dev/null)
    case "$sh_sk_b" in
        ''|*[!0-9]*) ;;
        *) printf '%s' "$((sh_sk_b / 1024))"; return 0 ;;
    esac
    if sh_have du; then
        sh_sk_k=$(du -sk "$sh_sk_f" 2>/dev/null | { read -r sh_sk_kb _ || :; printf '%s' "$sh_sk_kb"; })
        case "$sh_sk_k" in
            ''|*[!0-9]*) return 1 ;;
            *) printf '%s' "$sh_sk_k"; return 0 ;;
        esac
    fi
    return 1
}

# sh_is_elf_exec PATH -> 0 when PATH is a real ELF program, the only kind of
# file a memexec launcher may legally replace. A launcher copy is a BINARY, so
# replacing a script with one makes it unreadable to the interpreter that would
# have read it (issue #173).
#
# THE READER IS PURE SHELL, AND `dd | od | tr` IS NOT. That form is what AGENTS.md
# rule 4 forbids the library from growing, and it fails OPEN when the tools are
# absent: measured on a PATH carrying only sh/dash/cat/ls/mkdir/rm/cp/chmod/
# printf, `dd ... | od ... | tr -d ' \n'` printed "tr: not found" per file and
# answered "not ELF" for a real ELF binary, so this gate read false for every
# executable and launch mode degraded into copy mode with nothing said. The
# shell-only reader in lib/common.sh (sh_is_elf) was measured on the same
# stripped PATH and answers correctly for ELF, shebang, Mach-O, PE, empty and
# sub-four-byte files under both dash and bash --posix.
sh_is_elf_exec() {
    [ -x "$1" ] || return 1
    sh_is_elf "$1"
}

# sh_promote_tree SRC DEST -> mirror SRC into DEST. Directories are recreated,
# executable files are COPIED (they must be able to execve), and everything else
# is symlinked back to SRC. A copy that fails falls back to a symlink and warns,
# because a run that half-answers is worse than one that names the gap.
#
# STOP: IT IS A QUEUE AND NOT RECURSION, AND THAT IS NOT A STYLE CHOICE. POSIX sh has
# no `local`, so a recursive function's variables are GLOBALS: the recursive call
# for a subdirectory overwrote this call's source, destination and basename, and
# the loop then copied the remaining files to paths built from the child's names.
# Measured on the Go tree: 32 ".sh" files failed to copy and `go` never landed in
# the view at all, while every message blamed the file and not the walk.
sh_promote_tree() {
    sh_pt_src=$1
    sh_pt_dst=$2
    if [ ! -d "$sh_pt_src" ]; then
        return 0
    fi
    # Size-gate before writing anything (class C): name the constraint rather
    # than failing at ENOSPC mid-copy. A hard failure here is a refusal, and
    # the caller reports it; a soft warning would leave a half view behind.
    # The destination is named so the gate credits the view being replaced.
    sh_view_need "$sh_pt_src" "$sh_pt_dst" || return 1
    sh_pt_root_src=$(sh_lex_normalize "$sh_pt_src")
    sh_pt_root_dst=$(sh_lex_normalize "$sh_pt_dst")
    mkdir -p "$sh_pt_dst" 2>/dev/null || return 1
    sh_pt_tmp=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_pt_tmp" 2>/dev/null || return 1
    sh_pt_queue=$(sh_tmp_file "$sh_pt_tmp" promote)
    printf '%s\t%s\n' "$sh_pt_src" "$sh_pt_dst" > "$sh_pt_queue" 2>/dev/null || return 1
    while IFS="$SH_TAB" read -r sh_pt_s sh_pt_d; do
        [ -n "$sh_pt_s" ] || continue
        for sh_pt_e in "$sh_pt_s"/* "$sh_pt_s"/.[!.]* "$sh_pt_s"/..?*; do
            [ -e "$sh_pt_e" ] || [ -L "$sh_pt_e" ] || continue
            sh_pt_b=${sh_pt_e##*/}
            if [ -d "$sh_pt_e" ] && [ ! -L "$sh_pt_e" ]; then
                mkdir -p "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                printf '%s\t%s\n' "$sh_pt_e" "$sh_pt_d/$sh_pt_b" >> "$sh_pt_queue"
                continue
            fi
            # # STOP: A SYMLINK WHOSE TARGET IS IN THIS TREE IS MIRRORED, NOT RESOLVED,
            # AND THAT FIXED A BROKEN npm. Copying the link's target under the
            # link's basename moves it: node's bin/npm -> ../lib/node_modules/
            # npm/bin/npm-cli.js has a relative `require('../lib/cli.js')`, and a
            # copy at bin/npm looked for bin/../lib/cli.js and died. A symlink to
            # the home does not help either: the kernel refuses execve on a
            # shebang script whose inode is on a noexec mount. Pointing the link
            # at the mirrored copy keeps the script on the exec root and keeps
            # every relative path inside the tree.
            if [ -L "$sh_pt_e" ] && sh_have readlink; then
                sh_pt_t=$(readlink "$sh_pt_e" 2>/dev/null)
                case "$sh_pt_t" in
                    '') sh_pt_abs='' ;;
                    /*) sh_pt_abs=$(sh_lex_normalize "$sh_pt_t") ;;
                    *)  sh_pt_abs=$(sh_lex_normalize "$sh_pt_s/$sh_pt_t") ;;
                esac
                # NOTE: A TARGET INSIDE THIS TREE IS REMAPPED ONTO THE VIEW. A
                # target OUTSIDE IT IS LEFT ALONE, and this is not a style
                # choice: the earlier code computed the view path for ANY
                # absolute target and compared it afterwards, so
                # `bin/link.sh -> ../outside/ext.sh` became
                # `link.sh -> <view>/outside/ext.sh`, a path the view does not
                # contain and never will. Measured: the link pointed at a file
                # that did not exist, and nothing in the run said so. A link
                # whose target lives outside the tree is a link to a file that
                # is not being mirrored, so the honest link is the original one.
                case "$sh_pt_abs" in
                    "$sh_pt_root_src"/*)
                        if [ -e "$sh_pt_abs" ] || [ -L "$sh_pt_abs" ]; then
                            if ln -sfn "$sh_pt_root_dst/${sh_pt_abs#"$sh_pt_root_src"/}" "$sh_pt_d/$sh_pt_b" 2>/dev/null; then
                                continue
                            fi
                        fi
                        ;;
                    *)
                        # NOTE: A LINK TO A TARGET OUTSIDE THE TREE IS REPOINTED AT
                        # THAT TARGET'S ABSOLUTE PATH, NOT COPIED VERBATIM AND NOT
                        # REMAPPED INTO THE VIEW. Three wrong answers were
                        # available and each was measured. Remapping the target
                        # into the view produced `<view>/outside/ext.sh`, which
                        # the view does not contain. Copying the link's own text
                        # produced `../outside/ext.sh` relative to the VIEW's
                        # bin, which is a different directory. And linking to the
                        # link itself produced a self-referential path. The
                        # target's absolute path names the same file from
                        # anywhere, and it is the only one of the four that does.
                        if [ -n "$sh_pt_abs" ] && [ -e "$sh_pt_abs" ]; then
                            if ln -sfn "$sh_pt_abs" "$sh_pt_d/$sh_pt_b" 2>/dev/null; then
                                continue
                            fi
                        fi
                        ;;
                esac
            fi
            # STOP: A DEAD SYMLINK IS REPRODUCED POINTING AT ITS OWN TARGET, AND
            # NEVER AT ITSELF. `cp` dereferences, so a link whose target is gone
            # fails to copy, and the old fallback was `ln -sfn "$entry"`, which
            # points the view's copy at the SOURCE'S COPY of the link rather than
            # at what the link names. Measured: `bin/link.sh -> ../outside/ext.sh`
            # became `link.sh -> <source>/bin/link.sh`, a self-referential path
            # that resolves to the source link, which resolves to nothing. The
            # link is reproduced with its target's absolute path instead, so it
            # names the same file it always named and stays broken in exactly the
            # way the source is broken rather than in a new way.
            if [ -L "$sh_pt_e" ] && [ ! -e "$sh_pt_e" ]; then
                sh_pt_dead=''
                if sh_have readlink; then
                    sh_pt_dead=$(readlink "$sh_pt_e" 2>/dev/null)
                    case "$sh_pt_dead" in
                        /*) : ;;
                        *)  sh_pt_dead=$(sh_lex_normalize "$sh_pt_s/$sh_pt_dead") ;;
                    esac
                    if [ -n "$sh_pt_dead" ]; then
                        ln -sfn "$sh_pt_dead" "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                        continue
                    fi
                fi
                sh_warn "$sh_pt_e is a symlink whose target is missing and could not be reproduced"
                continue
            fi
            if sh_is_exec_file "$sh_pt_e"; then
                sh_pt_rel=${sh_pt_e#"$sh_pt_src"/}
                # Launch mode: a launcher copy maps itself back to this file
                # at runtime and runs it from memory, so the exec root holds
                # kilobytes per entry. ONLY AN ELF MAY BE STAMPED: the launcher
                # is itself a binary, so stamping a script replaces readable
                # interpreter source with 20KB of ELF and the interpreter then
                # dies on it. Measured on this tree after a `sandhome repair
                # python` in launch mode: CPython ships ~14 stdlib modules with
                # the executable bit set (platform.py among them), every one of
                # them was a launcher copy, and `import platform` died with
                # "source code string cannot contain null bytes" (issue #173).
                # It was worse than a crash, because a stamped .py is byte-
                # identical to the helper, so sh_view_current read the broken
                # view as CURRENT and repair never fixed it again. A script now
                # takes the copy branch below, which is both readable and
                # runnable. A copy-listed executable lands as real bytes for the
                # other reason: it is spawned by path and locates its siblings
                # exe-relative, which a memfd image cannot do (see
                # sh_copy_listed). A stamp that fails falls back to the copy
                # below, which is the old behavior and always works where
                # the view itself is writable.
                if [ "${SH_VIEW_MODE:-copy}" = launch ] && ! sh_copy_listed "$sh_pt_rel" && sh_is_elf_exec "$sh_pt_e" && sh_memexec_stamp "$sh_pt_e" "$sh_pt_d/$sh_pt_b"; then
                    :
                else
                    # The destination is removed first: it may be a symlink
                    # from an earlier view pointing back at this same source,
                    # and cp follows it and refuses with "are the same file",
                    # leaving a symlink to the noexec home that cannot run.
                    rm -f "$sh_pt_d/$sh_pt_b" 2>/dev/null
                    if cp -f "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null; then
                        chmod 0755 "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                    else
                        sh_warn "could not copy $sh_pt_e into the exec view; symlinking it instead, and it will not run"
                        ln -sfn "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                    fi
                fi
            else
                ln -sfn "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null || cp -f "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
            fi
        done
    done < "$sh_pt_queue"
    rm -f "$sh_pt_queue" 2>/dev/null
    return 0
}

# sh_toolchain_root NAME -> where toolchain NAME's data lives.
sh_toolchain_root() { printf '%s/%s' "$SH_HOME_TOOLCHAINS" "$1"; }

# sh_toolchain_view NAME -> where toolchain NAME's exec view lives.
sh_toolchain_view() { printf '%s/%s' "$SH_EXEC_VIEWS" "$1"; }

# sh_toolchain_adopted_root NAME -> the directory an ADOPTED toolchain was found
# in, or nothing. # NOTE: AN ADOPTED TOOLCHAIN HAS NO DIRECTORY IN THE HOME, AND
# PROMOTING IT FROM `sh_toolchain_root` SILENTLY DID NOTHING. The home root of an
# adopted toolchain does not exist, so `sh_promote_tree` was handed a missing
# source, returned 0 because it could not mirror what was not there, and every
# `TC_<name>_BINS` link was skipped: the tool answered on PATH (it was already
# there) and was absent from `$SANDHOME_EXEC/bin`, so a shell that read only
# `env.sh` could not find it, and a later run on a host where the original copy
# was gone had nothing to fall back on. A module declares where its working copy
# lives with `tc_<name>_adopted`; when it declares nothing, the binary that
# answered the probe is linked by its own absolute path, which is the honest
# answer and is what the caller had been relying on.
sh_toolchain_adopted_root() {
    sh_tar_name=$1
    sh_toolchain_load "$sh_tar_name" >/dev/null 2>&1 || { printf ''; return 0; }
    if command -v "tc_${sh_tar_name}_adopted" >/dev/null 2>&1; then
        "tc_${sh_tar_name}_adopted" 2>/dev/null
        return 0
    fi
    printf ''
}

# sh_promote_toolchain NAME BIN_REL... -> build the exec view for NAME and put
# every named relative executable on PATH under its basename. When the home is
# already exec-capable the tree needs no mirror, but the bins are still linked:
# the PATH entry is how `sandhome` and the env file find the tool, and skipping
# it left a toolchain installed, reported present in the home, and absent from
# every shell.
#
# An adopted toolchain is linked from wherever it actually lives rather than from
# the home root it never had. A BINARY FOUND ON PATH THAT CANNOT RUN FROM ITS OWN
# DIRECTORY (the noexec-home case) IS MIRRORED THROUGH AN EXEC VIEW LIKE ANY
# OTHER TREE, and a refusal is reported rather than swallowed.
# sh_copy_listed REL -> 0 when REL is named in SH_COPY_ONLY, the per-module
# list of executables that must be REAL copies even in launch mode. A
# process that is SPAWNED by path and locates its siblings exe-relative
# (gcc's ld.lld wrapper resolving its parent directory) cannot run from a
# memfd image, which has no stable directory; stamping it answers the exec
# and then dies locating itself. Measured: a launcher ld.lld links nothing
# (`lld-wrapper: parent directory could not be determined`) while a real
# copy of the same file links fine. The list is short (~4MB for rust) and
# the module names it; everything else stays a launcher.
sh_copy_listed() {
    case " ${SH_COPY_ONLY:-} " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# sh_copy_only_set NAME -> resolve the module's real-copy list into
# SH_COPY_ONLY. The promote step and the size gate both price off it, so it
# is resolved in one place: a list the gate cannot see under-prices the
# view it guards (measured: rust priced 198KB up front for a 17MB view,
# because the copy-listed linkers were priced as launchers).
sh_copy_only_set() {
    SH_COPY_ONLY=''
    # The module has to be loaded before its list can be read: the function that
    # declares the list IS the module, and a caller that has not sourced it sees
    # nothing. sh_toolchain_load is idempotent, so this is safe from every path.
    if command -v sh_toolchain_load >/dev/null 2>&1; then
        sh_toolchain_load "${1:-}" >/dev/null 2>&1 || true
    fi
    if command -v "tc_${1:-}_copy_bins" >/dev/null 2>&1; then
        SH_COPY_ONLY=$("tc_${1:-}_copy_bins" 2>/dev/null)
    fi
    export SH_COPY_ONLY
}

sh_promote_toolchain() {
    sh_ptc_name=$1
    shift
    # The view mode defaults to the copy the tree always did; the processes
    # that install (bootstrap, install, repair) run sh_memexec_ensure first
    # and export launch when the helper proves itself here.
    : "${SH_VIEW_MODE:=copy}"
    # The module's real-copy list, resolved against the tree it names (the
    # triple in rust's gcc-ld path is only known at install time, so this
    # is a function, not a variable). Empty when the module names none.
    #
    # # STOP: THE MODULE IS LOADED FIRST, BECAUSE THE LIST LIVES IN IT. The
    # caller here had never sourced tools/<name>.sh, so `command -v
    # tc_<name>_copy_bins` answered no and SH_COPY_ONLY came back EMPTY for
    # every toolchain that declares one. Measured with node in launch mode and
    # the list read straight out of the module:
    #   tc_node_copy_bins -> bin/node
    #   SH_COPY_ONLY after sh_promote_toolchain -> (empty)
    # so `bin/node` was stamped as a launcher anyway - the exact defect
    # tc_node_copy_bins exists to prevent (issue #139) - and the same held for
    # rust's ld.lld wrappers and zig, whose copy lists had been inert on this
    # path since they were added. sh_toolchain_load is idempotent, so loading
    # here costs one read and cannot disturb a caller that loaded it already.
    sh_toolchain_load "$sh_ptc_name" >/dev/null 2>&1 || true
    sh_copy_only_set "$sh_ptc_name"
    sh_ptc_root=$(sh_toolchain_root "$sh_ptc_name")
    sh_ptc_view=$(sh_toolchain_view "$sh_ptc_name")
    if [ -d "$sh_ptc_root" ]; then
        # # STOP: THE COLLAPSE IS FOR "NO SEPARATE ROOT", NOT FOR "THE HOME RUNS
        # FILES". `SH_HOME_EXEC=yes` means the home happens to permit execve,
        # which on a tmpfs `/tmp` or a normal disk home is ordinary -- so this
        # branch put every payload, view and launcher in the home even when the
        # caller named a different, roomier root with `--exec`/`SANDHOME_EXEC`.
        # Measured: `--exec /workspace/cp/exec` (152GB free) named and recorded
        # (`exec_reason=explicit`), while `install rust` aimed at the home and
        # failed "900MB wanted, 172MB free" on the 488MB tmpfs the caller had
        # named the other root to avoid (issue #149). The plan's own rule is
        # that an explicitly named root wins ("an operator who named
        # SANDHOME_EXEC has said where executables must go"); this applies it
        # to the payload, not only to the root.
        #
        # The condition reads the PLAN's answer, not the caller's variable:
        # bin/sandhome binds SANDHOME_EXEC from SH_EXEC at every entry point,
        # so testing SANDHOME_EXEC for emptiness never fires and the collapse
        # went dead for the ordinary no-root case. SH_EXEC = SH_HOME is the
        # plan saying there is no separate root, which is exactly when a
        # needless copy of every payload is avoided.
        if [ "$SH_HOME_EXEC" = yes ] && [ "$SH_EXEC" = "$SH_HOME" ]; then
            sh_ptc_view=$sh_ptc_root
        else
            # Prune before comparing: a view-only entry (payload deleted
            # since, half-finished earlier run) is invisible to the
            # current-check, which compares home-to-view and never
            # view-to-home, so without this it survives every reinstall on
            # PATH pointing at nothing (issue #110).
            sh_ptc_pruned=$(sh_view_prune "$sh_ptc_name" 2>/dev/null)
            case "$sh_ptc_pruned" in
                ''|0) ;;
                *) sh_step "pruned $sh_ptc_pruned stale view entries for $sh_ptc_name" ;;
            esac
            if sh_view_current "$sh_ptc_root" "$sh_ptc_view"; then
            # The view already mirrors the payload: rebuilding it would
            # change nothing, so the size gate is not consulted at all. A
            # no-op re-run on a drained exec root stays green (issue #71),
            # and the bin links below are still (re)made, so a view whose
            # links were lost is repaired without a rebuild.
            sh_step "the $sh_ptc_name view is current; leaving it in place"
        else
            sh_promote_tree "$sh_ptc_root" "$sh_ptc_view" || sh_fail "could not build the exec view for $sh_ptc_name"
        fi
        fi
    else
        # Adopted: no home tree. Link the probe's answer, or the module's own
        # declared location, straight into the exec bin.
        sh_ptc_adopted=$(sh_toolchain_adopted_root "$sh_ptc_name")
        sh_ptc_done=no
        for sh_ptc_rel in "$@"; do
            sh_ptc_bin=${sh_ptc_rel##*/}
            sh_ptc_link=''
            if [ -n "$sh_ptc_adopted" ] && [ -x "$sh_ptc_adopted/$sh_ptc_rel" ]; then
                sh_ptc_link="$sh_ptc_adopted/$sh_ptc_rel"
            elif [ -n "$sh_ptc_adopted" ] && [ -x "$sh_ptc_adopted/$sh_ptc_bin" ]; then
                sh_ptc_link="$sh_ptc_adopted/$sh_ptc_bin"
            fi
            if [ -n "$sh_ptc_link" ] && [ "$sh_ptc_link" = "$SH_EXEC_BIN/$sh_ptc_bin" ]; then
                # # STOP: A LINK WHOSE TARGET IS THE LINK IS NEVER RIGHT. The exec
                # view is on PATH by the time an install runs (sh_env_load put it
                # there), so `command -v` - which is how tc_<name>_adopted finds the
                # working copy - answers with the exec-view symlink this same
                # function wrote on the previous run. `ln -sfn` then writes that
                # path over itself and the tool is gone:
                #   readlink /dev/shm/bin/jq -> /dev/shm/bin/jq
                #   /dev/shm/bin/jq: Too many levels of symbolic links  (exit 126)
                # Measured on jq, rg, fd and node: 8 runs of
                # `. env.sh; sandhome install jq ripgrep fd` out of 8 left at least
                # one of them broken. The link is skipped and the lookup falls
                # through to the arm below, which re-resolves the binary with the
                # exec view filtered out.
                sh_ptc_link=''
            fi
            # A view link to a wrapper script that is already on PATH is a trap:
            # the script re-resolves its own name, finds the view link first and
            # execs itself forever (see sh_adopt_view_skip). Drop any link a
            # previous run wrote and leave the binary where PATH finds it.
            if [ -n "$sh_ptc_link" ] && sh_adopt_view_skip "$sh_ptc_bin" "$sh_ptc_link"; then
                rm -f "$SH_EXEC_BIN/$sh_ptc_bin" 2>/dev/null || true
                sh_ptc_done=yes
                continue
            fi
            if [ -n "$sh_ptc_link" ]; then
                mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
                ln -sfn "$sh_ptc_link" "$SH_EXEC_BIN/$sh_ptc_bin" 2>/dev/null || \
                    sh_warn "could not link $sh_ptc_link into $SH_EXEC_BIN"
                sh_ptc_done=yes
                continue
            fi
            # No declared location. Fall back to whatever answered on PATH, but
            # only if it RUNS: a binary on a noexec mount is not a binary here.
            # sh_path_where answers with the exec view removed, so this cannot
            # rediscover the link this function is about to rewrite.
            sh_ptc_which=$(sh_path_where "$sh_ptc_bin")
            if [ -n "$sh_ptc_which" ] && [ -x "$sh_ptc_which" ]; then
                if sh_adopt_view_skip "$sh_ptc_bin" "$sh_ptc_which"; then
                    rm -f "$SH_EXEC_BIN/$sh_ptc_bin" 2>/dev/null || true
                    sh_ptc_done=yes
                    continue
                fi
                if "$sh_ptc_which" --version >/dev/null 2>&1; then
                    mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
                    ln -sfn "$sh_ptc_which" "$SH_EXEC_BIN/$sh_ptc_bin" 2>/dev/null || \
                        sh_warn "could not link $sh_ptc_which into $SH_EXEC_BIN"
                    sh_ptc_done=yes
                else
                    # # STOP: A WARNING ABOUT SOMETHING THE RUN IS ABOUT TO FIX
                    # IS NOISE, AND THE FIX IS ALREADY IN THIS PROCESS. The promote
                    # step runs BEFORE the module's tc_<name>_env, and node's
                    # tc_node_env fetches and shims a working npm in response to
                    # exactly this state (issue #46). So the run printed
                    #   [!] .../npm is on PATH but will not run from /tmp; run
                    #       'sandhome install --force node' to place it properly
                    # and then, two lines later,
                    #   provided a working npm 12.1.0 for node v26.8.1
                    # The consumer is told the base toolchain is broken and given
                    # a --force to run, for a problem the same run solved. The
                    # warning is downgraded to a step so the run is honest without
                    # sending anyone to fix a machine that is already fixed; a
                    # module with no repair of its own still says so here, because
                    # this line is where it is learned.
                    sh_step "$sh_ptc_which is on PATH but will not run from $SH_EXEC; $sh_ptc_name is repairing that in this run, and 'sandhome install --force $sh_ptc_name' places it outright"
                fi
            fi
        done
        if [ "$sh_ptc_done" = no ]; then
            # # STOP: THE WARNING NAMES THE COMMAND THAT FIXES IT, AND SAYS THE
            # LIMIT OF THE BORROW. An adopted toolchain whose binaries cannot be
            # linked into the exec view is not broken, but it IS only reachable
            # through a PATH entry it inherited, and a shell that did not inherit
            # it has no go. The old text said "reachable only on the current
            # PATH" and stopped, which leaves a consumer reading a diagnosis with
            # no action attached. The action is the flag this tree grew for
            # exactly this case (issue #45), and it is named here so the sentence
            # and the remedy are in the same place.
            sh_warn "$sh_ptc_name was adopted but no declared binary could be linked into $SH_EXEC_BIN; it is reachable only through a PATH entry it already had, and 'sandhome install --force $sh_ptc_name' puts a copy on the exec view"
        fi
        SH_TOOLCHAIN_VIEW=$SH_EXEC_BIN
        export SH_TOOLCHAIN_VIEW
        return 0
    fi
    for sh_ptc_rel in "$@"; do
        sh_ptc_src="$sh_ptc_view/$sh_ptc_rel"
        sh_ptc_bin=${sh_ptc_rel##*/}
        if [ -e "$sh_ptc_src" ] || [ -L "$sh_ptc_src" ]; then
            mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
            ln -sfn "$sh_ptc_src" "$SH_EXEC_BIN/$sh_ptc_bin" 2>/dev/null || true
        fi
    done
    # # STOP: A SHRUNK BIN SET MUST NOT LEAVE DANGLING EXEC LINKS. A qemu
    # reinstall asking for different guests wipes the payload bin and rebuilds
    # the view, but the exec-bin link for a dropped guest survived: the next
    # doctor failed exec_link_qemu-aarch64=broken while every install had
    # exited 0 (measured on a --extra aarch64 then --extra arm run). A link
    # whose target sits under THIS view belongs to this toolchain, so one
    # whose name is no longer promoted is removed here, where the set is
    # known. Only symlinks under the view are touched; adopted roots, host
    # links and real files are never candidates.
    # # STOP: AN EMPTY BIN SET IS NOT A DECLARATION THAT THE VIEW IS EMPTY.
    # The sweep below removes every exec link into THIS view whose name is not
    # in "$@", so a promote called with no bins (the framework's promote for a
    # module whose TC_<name>_BINS is empty, and tc_python_env's own call) swept
    # away the uv/uvx links tc_python_install had just made. `uv` then vanished
    # from every fresh shell while the toolchain description still promised it
    # and the payload was untouched (issue #152). A caller that wants to shrink
    # the view names the bins it keeps; a caller that names none is asking for
    # no links, not for all of them to be removed.
    if [ "$#" -gt 0 ] && [ -n "$sh_ptc_view" ] && [ -d "${SH_EXEC_BIN:-/nonexistent}" ]; then
        for sh_ptc_l in "$SH_EXEC_BIN"/*; do
            [ -L "$sh_ptc_l" ] || continue
            sh_ptc_lb=${sh_ptc_l##*/}
            sh_ptc_lt=$(readlink "$sh_ptc_l" 2>/dev/null) || continue
            case "$sh_ptc_lt" in
                "$sh_ptc_view"/*) ;;
                *) continue ;;
            esac
            sh_ptc_keep=no
            for sh_ptc_rel in "$@"; do
                [ "${sh_ptc_rel##*/}" = "$sh_ptc_lb" ] && sh_ptc_keep=yes
            done
            if [ "$sh_ptc_keep" = no ]; then
                rm -f "$sh_ptc_l" 2>/dev/null || true
                sh_step "removed stale exec link $sh_ptc_lb (no longer in the $sh_ptc_name view)"
            fi
        done
        unset sh_ptc_l sh_ptc_lb sh_ptc_lt sh_ptc_keep
    fi
    SH_TOOLCHAIN_VIEW=$sh_ptc_view
    export SH_TOOLCHAIN_VIEW
    return 0
}

# sh_space_max_exec_free -> the most free megabytes on any exec-capable
# candidate, or 0. This is the ceiling `sandhome space` names when no roomy
# exec-capable root exists (issue #59): `--exec DIR` has no target then, and a
# report that lists candidates without naming the ceiling leaves the consumer
# to add the column themselves.
sh_space_max_exec_free() {
    sh_sme_max=0
    for sh_sme_c in $(sh_exec_candidates); do
        [ -n "$sh_sme_c" ] || continue
        [ -d "$sh_sme_c" ] || continue
        sh_dir_writable "$sh_sme_c" || continue
        sh_exec_probe "$sh_sme_c" || continue
        sh_sme_free=$(sh_free_mb "$sh_sme_c" 2>/dev/null)
        case "$sh_sme_free" in ''|*[!0-9]*) continue ;; esac
        if [ "$sh_sme_free" -gt "$sh_sme_max" ]; then
            sh_sme_max=$sh_sme_free
        fi
    done
    printf '%s' "$sh_sme_max"
}

# sh_space_ceiling -> small when no exec-capable candidate clears 900MB (the
# rust view), roomy otherwise. 900MB is the heaviest first-party view; clang
# wants more and node/go want less, so a small ceiling means rust and clang
# cannot be installed here however they are asked for.
sh_space_ceiling() {
    sh_sc_max=$(sh_space_max_exec_free)
    case "$sh_sc_max" in ''|*[!0-9]*) sh_sc_max=0 ;; esac
    if [ "$sh_sc_max" -ge 900 ]; then
        printf 'roomy'
    else
        printf 'small'
    fi
}

# sh_space_payloads -> where installed toolchain payloads actually are: exec
# when every payload under the home has its view on the exec root, home when
# none does (the collapse put views into the home), both when mixed, none when
# no payload is installed. This is read off disk, not off the plan: the plan
# says where things should go, this says where they are, so the two answers
# cannot disagree again (issue #149: the root was explicit while every view
# sat in the home). Only a REAL payload counts: an adopted toolchain leaves
# auxiliary data under the home (the npm seed home/toolchains/node/npm that
# tc_node_ensure_npm fetches for an adopted node) without any view, and that
# is by design, not a collapse. sh_toolchain_payload_present checks the
# module's declared binaries, so a seed without them is not a payload.
sh_space_payloads() {
    sh_spl_home=0
    sh_spl_exec=0
    if [ -n "${SH_HOME_TOOLCHAINS:-}" ] && [ -d "$SH_HOME_TOOLCHAINS" ]; then
        for sh_spl_d in "$SH_HOME_TOOLCHAINS"/*; do
            [ -d "$sh_spl_d" ] || continue
            sh_spl_n=${sh_spl_d##*/}
            case "$sh_spl_n" in .*|staging|tmp) continue ;; esac
            if command -v sh_toolchain_payload_present >/dev/null 2>&1; then
                sh_toolchain_payload_present "$sh_spl_n" 2>/dev/null || continue
            fi
            # Without toolchain.sh the predicate is unavailable and every
            # directory counts, the old behaviour. bin/sandhome always loads
            # every library, so this arm only serves a hand-sourced shell.
            if [ -n "${SH_EXEC_VIEWS:-}" ] && [ -d "$SH_EXEC_VIEWS/$sh_spl_n" ]; then
                sh_spl_exec=$((sh_spl_exec + 1))
            else
                sh_spl_home=$((sh_spl_home + 1))
            fi
        done
    fi
    unset sh_spl_d sh_spl_n
    if [ "$sh_spl_exec" -gt 0 ] && [ "$sh_spl_home" -gt 0 ]; then
        printf 'both'
    elif [ "$sh_spl_exec" -gt 0 ]; then
        printf 'exec'
    elif [ "$sh_spl_home" -gt 0 ]; then
        printf 'home'
    else
        printf 'none'
    fi
    unset sh_spl_home sh_spl_exec
}

# sh_space_report -> one line per root, and the mounts that were tried. This is
# what `sandhome space` prints and what the bootstrap says when it had to split.
sh_space_report() {
    printf 'home=%s\n' "$SH_HOME"
    printf 'home_exec=%s\n' "$SH_HOME_EXEC"
    printf 'home_mount=%s\n' "$(sh_mount_opts "$SH_HOME")"
    printf 'home_free_mb=%s\n' "$(sh_free_mb "$SH_HOME")"
    printf 'home_total_mb=%s\n' "$(sh_total_mb "$SH_HOME")"
    printf 'exec=%s\n' "$SH_EXEC"
    printf 'exec_reason=%s\n' "${SH_EXEC_CHOSEN_REASON:-unknown}"
    printf 'exec_mount=%s\n' "$(sh_mount_opts "$SH_EXEC")"
    printf 'exec_free_mb=%s\n' "$(sh_free_mb "$SH_EXEC")"
    printf 'exec_total_mb=%s\n' "$(sh_total_mb "$SH_EXEC")"
    printf 'exec_bin=%s\n' "$SH_EXEC_BIN"
    printf 'exec_space=%s\n' "$(sh_space_status "$SH_EXEC")"
    printf 'exec_space_low_mb=%s\n' "${SANDHOME_LOW_EXEC_MB:-100}"
    printf 'exec_space_critical_mb=%s\n' "${SANDHOME_CRIT_MB:-32}"
    printf 'min_exec_mb=%s\n' "$SANDHOME_MIN_EXEC_MB"
    printf 'max_exec_free_mb=%s\n' "$(sh_space_max_exec_free)"
    printf 'exec_ceiling=%s\n' "$(sh_space_ceiling)"
    printf 'payloads=%s\n' "$(sh_space_payloads)"
}

# sh_space_probe_report -> every candidate tried, with the real answer for each.
# This is the report that explains a split decision, and the one to read when a
# toolchain would not run.
sh_space_probe_report() {
    sh_spr_chosen=${SH_EXEC:-}
    for sh_spr_c in $(sh_exec_candidates); do
        [ -n "$sh_spr_c" ] || continue
        if [ ! -d "$sh_spr_c" ]; then
            # # NOTE: A DIRECTORY THAT DOES NOT EXIST IS REPORTED AS ABSENT, AND NOT
            # MADE. The probe created every candidate it listed, so a report of
            # this machine changed it; in this sandbox /var/tmp is absent and one
            # probe call brought it into being. Existence is now the first fact
            # printed and the only one the plan needed before mkdir.
            printf 'candidate=%s exists=no writable=no exec=no mount= free_mb=\n' "$sh_spr_c"
            continue
        fi
        sh_spr_w=no
        sh_spr_x=no
        sh_dir_writable "$sh_spr_c" && sh_spr_w=yes
        sh_exec_probe "$sh_spr_c" && sh_spr_x=yes
        sh_spr_pick=''
        [ "$sh_spr_c" = "$sh_spr_chosen" ] && sh_spr_pick=' chosen=yes'
        # # A VERDICT, NOT ONLY A TABLE OF NUMBERS. The plan already decides
        # whether a candidate runs a file, and prints why only in `space`; a
        # consumer reading `--probe` sees a roomy candidate and cannot tell why
        # it was passed over. The verdict names the reason in one word so the
        # list is a decision (issue #125).
        # REDUNDANCY: FIVE VERDICTS, NOT THREE, BECAUSE ROOM IS A REASON TOO.
        # A candidate that runs a file but holds less than SANDHOME_MIN_EXEC_MB
        # loses the ranking exactly like a noexec one does, and without a word
        # for it the list reads as though the plan ignored a working root. The
        # order is the plan's own order: writable, then exec, then room, then
        # chosen. A verdict is never inferred from mount options, only from
        # the same probes the plan runs.
        sh_spr_verdict=usable
        sh_spr_free=$(sh_free_mb "$sh_spr_c" 2>/dev/null)
        case "$sh_spr_free" in ''|*[!0-9]*) sh_spr_free=0 ;; esac
        if [ "$sh_spr_w" = no ]; then
            sh_spr_verdict=not-writable
        elif [ "$sh_spr_x" = no ]; then
            sh_spr_verdict=noexec
        elif [ "$sh_spr_free" -lt "${SANDHOME_MIN_EXEC_MB:-128}" ]; then
            sh_spr_verdict=too-small
        elif [ "$sh_spr_c" = "$sh_spr_chosen" ]; then
            sh_spr_verdict=chosen
        fi
        sh_spr_total=$(sh_total_mb "$sh_spr_c" 2>/dev/null)
        case "$sh_spr_total" in ''|*[!0-9]*) sh_spr_total='' ;; esac
        if [ -n "$sh_spr_total" ]; then
            printf 'candidate=%s exists=yes writable=%s exec=%s mount=%s free_mb=%s total_mb=%s verdict=%s%s\n' \
                "$sh_spr_c" "$sh_spr_w" "$sh_spr_x" \
                "$(sh_mount_opts "$sh_spr_c")" "$sh_spr_free" "$sh_spr_total" "$sh_spr_verdict" "$sh_spr_pick"
        else
            printf 'candidate=%s exists=yes writable=%s exec=%s mount=%s free_mb=%s verdict=%s%s\n' \
                "$sh_spr_c" "$sh_spr_w" "$sh_spr_x" \
                "$(sh_mount_opts "$sh_spr_c")" "$sh_spr_free" "$sh_spr_verdict" "$sh_spr_pick"
        fi
    done
}

# sh_gc_entry_kb PATH -> the size in KB, or 0 when it cannot be measured.
# sh_dir_size answers nothing without du; a gc that priced off nothing would
# report nothing reclaimed however much it deleted (issue #85), so the
# unmeasurable entry prices at zero and the total stays a number.
sh_gc_entry_kb() {
    sh_gek_k=$(sh_dir_size "$1" 2>/dev/null)
    case "$sh_gek_k" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$sh_gek_k" ;;
    esac
}

# sh_gc_live DIR -> 0 when a live install holds DIR: it contains a
# .sandhome-live-PID file whose process still runs. A concurrent `gc 0` must
# not delete the staging of a live install and blame the URL afterwards
# (issue #103). A stale marker (dead pid, killed run) protects nothing, so a
# previous session's wreckage is still reclaimed.
sh_gc_live() {
    for sh_gl_m in "$1"/.sandhome-live-*; do
        [ -e "$sh_gl_m" ] || continue
        sh_gl_pid=${sh_gl_m##*.sandhome-live-}
        case "$sh_gl_pid" in
            ''|*[!0-9]*) continue ;;
        esac
        if kill -0 "$sh_gl_pid" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# sh_gc_fresh PATH -> 0 when PATH was modified within the last 30 minutes.
# find -mmin answers it; without find nothing is fresh, and the caller says
# find is missing rather than deleting blindly.
sh_gc_fresh() {
    sh_have find || return 1
    [ -n "$(find "$1" -maxdepth 0 -mmin -30 2>/dev/null)" ]
}

# sh_gc_keep ENTRY -> 0 when ENTRY must survive this run. Two cases, and
# neither is the age rule below: a live install holds it (any DAYS -- a `gc 0`
# that kills a running install destroys a working toolchain to fix a full
# root), or it is younger than 30 minutes on a run that asked for everything
# (top-level DAYS=0, read off the caller's sh_gc_days). SANDHOME_GC_FORCE=1
# deletes regardless; it is the operator saying "I know what is running here".
sh_gc_keep() {
    # The operator's explicit override deletes regardless, even past a live
    # install: it is the operator saying "I know what is running here".
    if [ "${SANDHOME_GC_FORCE:-0}" = 1 ]; then
        return 1
    fi
    if sh_gc_live "$1"; then
        return 0
    fi
    if [ "${sh_gc_days:-7}" = 0 ] && sh_gc_fresh "$1"; then
        return 0
    fi
    return 1
}

# sh_gc_rm ENTRY DAYS -> remove one gc entry, counting bytes. DAYS is the age
# gate, or `always` for scans with no age rule (staging: a killed run's
# leftovers are exactly what that scan clears). The liveness/freshness guard
# above applies to every scan. Sets sh_gc_removed/sh_gc_bytes in the caller;
# prints nothing itself except in dry-run, where it names what would go.
sh_gc_rm() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if sh_gc_keep "$1"; then
        sh_step "keeping $1 (live or fresh; SANDHOME_GC_FORCE=1 overrides)"
        return 0
    fi
    if [ "$2" != always ] && [ "$2" != 0 ]; then
        if ! sh_have find; then
            return 0
        fi
        if [ -z "$(find "$1" -maxdepth 0 -mtime +"$2" 2>/dev/null)" ]; then
            return 0
        fi
    fi
    if [ "${SH_GC_DRY_RUN:-0}" = 1 ]; then
        sh_step "would remove $1 ($(sh_gc_entry_kb "$1")KB)"
        return 0
    fi
    sh_gc_kb=$(sh_gc_entry_kb "$1")
    if rm -rf "$1" 2>/dev/null; then
        sh_gc_removed=$((sh_gc_removed + 1))
        # STOP: THE COUNTER IS INCREMENTED, BECAUSE ZERO IS A CLAIM. sh_gc_bytes
        # was initialised and never touched, so `sandhome gc` always reported
        # "0KB (0MB) reclaimed" however much it deleted (issue #85) -- the
        # recovery command grading its own work as nothing done. The size is
        # measured before the removal, off du, so the number is what left.
        sh_gc_bytes=$((sh_gc_bytes + sh_gc_kb))
    fi
    return 0
}

# sh_space_gc [DAYS] -> remove work directories older than DAYS (default 7) and
# every staging directory. A bootstrap leaves staging behind when it is killed,
# and on a small exec root that is the difference between the next install
# fitting and not. Named so a caller can see exactly what may be deleted.
#
# # STOP: THE ARGUMENT IS CHECKED BEFORE IT REACHES `find`. It was interpolated
# straight into `-mtime +"$sh_gc_days"`, and `sandhome gc abc` then ran
# `find ... -mtime +abc`, which failed, returned nothing, removed nothing, and
# REPORTED SUCCESS:
#   $ sh bin/sandhome gc abc
#   sandhome: removed 0 staging entries      # exit 0
# `gc -5` became `-mtime +-5` the same way. `gc` is the command a caller reaches
# for when a small exec root is full, and it is the only command here that
# deletes; a wrong answer there costs a session and a `--dry-run` was missing
# for a command whose whole job is destructive. Both are below, and
# tests/space.sh drives all four cases.
sh_space_gc() {
    sh_gc_days=${1:-7}
    case "$sh_gc_days" in
        ''|*[!0-9]*)
            sh_warn "gc needs a whole number of days, not '$sh_gc_days'"
            return 2
            ;;
    esac
    sh_gc_removed=0
    sh_gc_bytes=0
    # The named staging areas are ours and are always safe to clear, subject
    # to the live-install guard above: staging is never age-gated (a killed
    # run's leftovers are exactly what this clears), so the scan passes
    # `always` and only liveness -- or a fresh DAYS=0 entry -- holds it back.
    for sh_gc_dir in "$SH_HOME/.staging" "$SH_EXEC/.staging"; do
        [ -n "$sh_gc_dir" ] || continue
        [ -d "$sh_gc_dir" ] || continue
        for sh_gc_e in "$sh_gc_dir"/* "$sh_gc_dir"/.[!.]*; do
            [ -e "$sh_gc_e" ] || [ -L "$sh_gc_e" ] || continue
            sh_gc_rm "$sh_gc_e" always
        done
    done
    # Build caches and targets on the exec root (issue #33): GOCACHE, the exec
    # tmp, uv/npm caches on exec, and cargo target dirs under the home views.
    # Only entries older than DAYS are removed, so an active build is kept.
    # STOP: DAYS=0 MEANS EVERYTHING SANDHOME OWNS, WITH NO AGE CHECK (issue
    # #67). `-mtime +0` means more than 0 whole days old, so an entry written
    # earlier in the session never matches and `gc 0` reclaimed 0 bytes exactly
    # when the doctor line named it. Views are never scanned here: they are
    # toolchain data rebuilt by `repair`, not caches, and deleting them would
    # break every toolchain to reclaim the root they run from.
    if sh_have find; then
        for sh_gc_dir in "$SH_EXEC/cache" "$SH_EXEC/tmp"; do
            [ -n "$sh_gc_dir" ] || continue
            [ -d "$sh_gc_dir" ] || continue
            for sh_gc_e in "$sh_gc_dir"/* "$sh_gc_dir"/.[!.]*; do
                [ -e "$sh_gc_e" ] || [ -L "$sh_gc_e" ] || continue
                sh_gc_rm "$sh_gc_e" "$sh_gc_days"
            done
        done
        # A failed node-gyp build leaves ~70MB of node-gyp-tmp-* scratch where
        # the build ran, and no scan above names it, so `gc` reclaimed 0 bytes
        # while the root stayed full (issues #86, #102). The pattern is
        # scanned at the exec root's top level, where such builds land; views
        # are still never scanned.
        if [ -n "$SH_EXEC" ] && [ -d "$SH_EXEC" ]; then
            for sh_gc_e in "$SH_EXEC"/node-gyp-tmp-* "$SH_EXEC"/.node-gyp-tmp-*; do
                [ -e "$sh_gc_e" ] || [ -L "$sh_gc_e" ] || continue
                sh_gc_rm "$sh_gc_e" "$sh_gc_days"
            done
        fi
    else
        sh_warn "no find; leaving $SH_EXEC/cache and $SH_EXEC/tmp alone"
    fi
    # # STOP: AGE IS CHECKED WITH find AND NOT ASSUMED. Without find the temp area is
    # left alone and that is said out loud, rather than deleted wholesale:
    # another bootstrap may be holding a directory in it right now.
    if [ -d "$SH_HOME_TMP" ]; then
        if sh_have find; then
            for sh_gc_e in "$SH_HOME_TMP"/* "$SH_HOME_TMP"/.[!.]*; do
                [ -e "$sh_gc_e" ] || [ -L "$sh_gc_e" ] || continue
                sh_gc_rm "$sh_gc_e" "$sh_gc_days"
            done
        else
            sh_warn "no find; leaving $SH_HOME_TMP alone rather than deleting a running bootstrap's work"
        fi
    fi
    # The reason to run gc is space, and a count of entries is not a number of
    # bytes. The bytes are measured per entry before removal and accumulated
    # above. Both cross to the caller as text -- `REMOVED BYTES_KB` on stdout
    # -- because a command substitution runs in a subshell and assignments
    # inside it would not reach the caller. The exports beside it serve
    # callers that source rather than capture.
    SH_GC_REMOVED=$sh_gc_removed
    SH_GC_BYTES=$sh_gc_bytes
    export SH_GC_REMOVED SH_GC_BYTES
    printf '%s %s' "$sh_gc_removed" "$sh_gc_bytes"
    return 0
}

# sh_view_prune NAME -> remove view entries whose payload is gone, printing
# the count. An entry whose home file was deleted (or never promoted on a
# half-finished run) survives every reinstall: the mirror only adds, and the
# current-check only compares home-to-view, so a view-only entry is invisible
# to both and stays on PATH pointing at nothing (issue #110). The walk is a
# queue like every other walk here. Adopted toolchains have no home tree and
# are skipped: there is nothing to compare against, and their links are
# managed by the adopt path itself.
sh_view_prune() {
    sh_vp_name=$1
    sh_vp_root=$(sh_toolchain_root "$sh_vp_name")
    sh_vp_view=$(sh_toolchain_view "$sh_vp_name")
    sh_vp_pruned=0
    if [ ! -d "$sh_vp_view" ] || [ ! -d "$sh_vp_root" ]; then
        printf '0'
        return 0
    fi
    sh_vp_queue=$(sh_tmp_file "${SH_HOME_TMP:-${TMPDIR:-/tmp}}" viewprune)
    printf '%s\n' "$sh_vp_view" > "$sh_vp_queue" 2>/dev/null || {
        printf '0'
        return 0
    }
    while IFS= read -r sh_vp_d; do
        [ -n "$sh_vp_d" ] || continue
        for sh_vp_e in "$sh_vp_d"/* "$sh_vp_d"/.[!.]* "$sh_vp_d"/..?*; do
            [ -e "$sh_vp_e" ] || [ -L "$sh_vp_e" ] || continue
            sh_vp_rel=${sh_vp_e#"$sh_vp_view"/}
            if [ -d "$sh_vp_e" ] && [ ! -L "$sh_vp_e" ]; then
                if [ ! -d "$sh_vp_root/$sh_vp_rel" ]; then
                    rm -rf "$sh_vp_e" 2>/dev/null && sh_vp_pruned=$((sh_vp_pruned + 1))
                else
                    printf '%s\n' "$sh_vp_e" >> "$sh_vp_queue"
                fi
                continue
            fi
            if [ ! -e "$sh_vp_root/$sh_vp_rel" ] && [ ! -L "$sh_vp_root/$sh_vp_rel" ]; then
                rm -f "$sh_vp_e" 2>/dev/null && sh_vp_pruned=$((sh_vp_pruned + 1))
            fi
        done
    done < "$sh_vp_queue"
    rm -f "$sh_vp_queue" 2>/dev/null
    printf '%s' "$sh_vp_pruned"
    return 0
}

# sh_space_largest [N] -> the N biggest top-level entries under the exec root,
# one `SIZE_KB PATH` line each, biggest first. This is the answer `du -sh
# $SH_EXEC/* | sort -h | tail` gives in the space advice, as a command: the
# exec root fills with the consumer's own build output first, and gc only
# reclaims sandhome's own caches, so naming what holds the space is the first
# step of every recovery. Without du there is no portable measure, and that
# is said rather than guessed.
sh_space_largest() {
    sh_sl_n=${1:-10}
    case "$sh_sl_n" in
        ''|*[!0-9]*) sh_sl_n=10 ;;
    esac
    if [ -z "${SH_EXEC:-}" ] || [ ! -d "$SH_EXEC" ]; then
        return 0
    fi
    if ! sh_have du; then
        sh_warn 'no du here, so entry sizes are unavailable'
        return 0
    fi
    # Without sort the entries still print, unsorted: a missing tool degrades
    # the listing rather than refusing it.
    if sh_have sort; then
        sh_sl_sort='sort -rn'
    else
        sh_sl_sort='cat'
    fi
    for sh_sl_e in "$SH_EXEC"/* "$SH_EXEC"/.[!.]*; do
        [ -e "$sh_sl_e" ] || [ -L "$sh_sl_e" ] || continue
        sh_sl_k=$(sh_dir_size "$sh_sl_e" 2>/dev/null)
        case "$sh_sl_k" in
            ''|*[!0-9]*) continue ;;
        esac
        # # TAG THE OWNER OF EACH ENTRY, AFTER THE PATH. When an exec root drains
        # during a session the biggest thing is usually the consumer's OWN build
        # output (a cargo install root, an npm prefix, a project venv), not
        # sandhome's caches, and `gc` deliberately does not touch those. Without
        # a tag the list reads as though `gc` could reclaim all of it, so the
        # consumer deletes the wrong thing or waits for a command that will not
        # help (issue #125). Three tags, one meaning each: `reclaim` is what a
        # default `gc` removes, `sandhome` is what the tree owns and `gc` keeps,
        # `yours` is anything else. `space --reclaim` and `gc --dry-run` read
        # the same scan `gc` runs, so the tags and the numbers cannot disagree
        # again (issue #141: the legend said `sandhome` is what gc reclaims
        # while the tag also covered views, which gc never touches, and named
        # `$SH_EXEC/staging`, which this tree never creates -- gc clears
        # `$SH_HOME/.staging` and `$SH_EXEC/.staging`).
        # REDUNDANCY: PREFIX, NOT BASENAME, BECAUSE A CONSUMER NESTS. The first
        # version matched the basename against a fixed list, so `$EXEC/myproj/target`
        # read as `yours` (right) but `$EXEC/cache/myproj` read as `sandhome`
        # only when the leaf matched, and a nested `views.bak` or `cargo-install.old`
        # read as `yours` while gc would still reclaim part of it. The rule is
        # now the exec-root layout the tree itself writes: anything under the
        # known sandhome-owned top levels is sandhome, everything else is yours.
        # The check is a prefix on the full path, so it survives renames of the
        # leaf and does not mistake a consumer dir named `cache` inside a project
        # for the top-level cache. Unknown top levels stay `yours`, which is the
        # safe direction: gc never touches them, so claiming gc could reclaim
        # them would be the wrong advice.
        sh_sl_tag=yours
        case "$sh_sl_e" in
            "$SH_EXEC"/cache|"$SH_EXEC"/cache/*|"$SH_EXEC"/tmp|"$SH_EXEC"/tmp/*|"$SH_EXEC"/.staging|"$SH_EXEC"/.staging/*) sh_sl_tag=reclaim ;;
        esac
        if [ "$sh_sl_tag" = yours ]; then
            case "$sh_sl_e" in
                "$SH_EXEC"/node-gyp-tmp-*|"$SH_EXEC"/.node-gyp-tmp-*) sh_sl_tag=reclaim ;;
            esac
        fi
        if [ "$sh_sl_tag" = yours ]; then
            case "$sh_sl_e" in
                "$SH_EXEC"/views|"$SH_EXEC"/views/*|"$SH_EXEC"/bin|"$SH_EXEC"/bin/*|"$SH_EXEC"/.sandhome-lib|"$SH_EXEC"/.sandhome-lib/*|"$SH_EXEC"/npm-global|"$SH_EXEC"/npm-global/*|"$SH_EXEC"/uv-bin|"$SH_EXEC"/uv-bin/*|"$SH_EXEC"/go-bin|"$SH_EXEC"/go-bin/*|"$SH_EXEC"/cargo-install|"$SH_EXEC"/cargo-install/*) sh_sl_tag=sandhome ;;
            esac
        fi
        # Fallback for an SH_EXEC that is unset in a test harness: match the
        # leaf the old way so the tag still answers rather than going silent.
        if [ "$sh_sl_tag" = yours ]; then
            case "${sh_sl_e##*/}" in
                cache|tmp|.staging|node-gyp-tmp-*) sh_sl_tag=reclaim ;;
                views|bin|npm-global|uv-bin|go-bin|cargo-install) sh_sl_tag=sandhome ;;
            esac
        fi
        printf '%s\t%s\t%s\n' "$sh_sl_k" "$sh_sl_e" "$sh_sl_tag"
    done | $sh_sl_sort 2>/dev/null | {
        sh_sl_i=0
        while IFS="	" read -r sh_sl_k sh_sl_p sh_sl_tag; do
            sh_sl_i=$((sh_sl_i + 1))
            [ "$sh_sl_i" -le "$sh_sl_n" ] || break
            printf '%sKB\t%s\t(%s)\n' "$sh_sl_k" "$sh_sl_p" "$sh_sl_tag"
        done
    }
    printf '%s\n' 'tag: reclaim = gc removes this; sandhome = this tree owns it and gc keeps it; yours = you installed or built it, remove it yourself'
    return 0
}

# sh_free_kb DIR -> free kilobytes on the filesystem holding DIR, or nothing.
sh_free_kb() {
    df -Pk "$1" 2>/dev/null | {
        if read -r sh_fk_dev sh_fk_1 sh_fk_used sh_fk_free sh_fk_rest; then
            if read -r sh_fk_dev sh_fk_1 sh_fk_used sh_fk_free sh_fk_rest; then
                case "$sh_fk_free" in
                    ''|*[!0-9]*) printf '' ;;
                    *) printf '%s' "$sh_fk_free" ;;
                esac
            fi
        fi
    }
}

# sh_dir_size PATH -> the apparent size in kilobytes, or nothing when no tool
# that can measure is present. `du -sk` is the only portable answer, and it is
# NOT assumed: a report that guesses a size is worse than one that prints
# nothing beside it, so this answers the empty string and the caller says
# "size unavailable" rather than a number.
# sh_dir_apparent_kb DIR -> the KB DIR's contents would occupy if copied, or
# nothing when the size cannot be read. This is the same ruler as
# sh_size_kb/sh_view_copy_kb, and it exists because the two are otherwise not
# comparable: sh_dir_size reports allocated blocks, and on a root that
# compresses or deduplicates those are far smaller than the bytes a copy writes.
# Measured here on zfs, seven copies of /bin/sh:
#   sh_dir_size      ->    4 KB
#   apparent         ->  888 KB
# so a gate that prices copies correctly looks wrong beside a block count. It
# walks the same way sh_view_copy_kb does (a queue, not recursion, rule 5) and
# counts every regular file, which is what "if this tree were copied" means.
sh_dir_apparent_kb() {
    sh_da_src=$1
    if [ ! -d "$sh_da_src" ]; then
        printf ''
        return 0
    fi
    sh_da_total=0
    sh_da_queue=$(sh_tmp_file "${SH_HOME_TMP:-${TMPDIR:-/tmp}}" dirapparent)
    printf '%s\n' "$sh_da_src" > "$sh_da_queue" 2>/dev/null || {
        printf ''
        return 0
    }
    while IFS= read -r sh_da_d; do
        [ -n "$sh_da_d" ] || continue
        for sh_da_e in "$sh_da_d"/* "$sh_da_d"/.[!.]* "$sh_da_d"/..?*; do
            [ -e "$sh_da_e" ] || [ -L "$sh_da_e" ] || continue
            if [ -d "$sh_da_e" ] && [ ! -L "$sh_da_e" ]; then
                printf '%s\n' "$sh_da_e" >> "$sh_da_queue"
                continue
            fi
            # A symlink costs its own target string, not the target's bytes: the
            # view writes links, so counting the target here would overstate
            # exactly what this function exists to measure.
            [ -L "$sh_da_e" ] && continue
            sh_da_k=$(sh_size_kb "$sh_da_e" 2>/dev/null)
            case "$sh_da_k" in
                ''|*[!0-9]*) continue ;;
            esac
            sh_da_total=$((sh_da_total + sh_da_k))
        done
    done < "$sh_da_queue"
    rm -f "$sh_da_queue" 2>/dev/null
    printf '%s' "$sh_da_total"
}

sh_dir_size() {
    if sh_have du; then
        sh_ds_out=$(du -sk "$1" 2>/dev/null | { read -r sh_ds_k _ || :; printf '%s' "$sh_ds_k"; })
        case "$sh_ds_out" in
            ''|*[!0-9]*) printf '' ;;
            *) printf '%s' "$sh_ds_out" ;;
        esac
        return 0
    fi
    printf ''
}
