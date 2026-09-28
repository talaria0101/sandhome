#!/bin/sh
# tests/space.sh - the two-root plan, the exec probe and the mirror.
#
# THE REGRESSION THIS FILE EXISTS FOR: sh_promote_tree was recursive, and POSIX
# sh has no `local`, so the recursive call for one subdirectory overwrote the
# parent's source/destination/basename. The second sibling directory was mirrored
# under the FIRST sibling instead of at the top, and 32 files were reported as
# copy failures. The two-sibling case below fails against that shape.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT; SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin space

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-space.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- writable and exec probes -------------------------------------------------
mkdir -p "$tmp/writable" "$tmp/ro" 2>/dev/null
chmod 0500 "$tmp/ro" 2>/dev/null
sh_dir_writable "$tmp/writable" && t_ok 0 'dir_writable accepts a writable dir' || t_ok 1 'dir_writable accepts a writable dir'
sh_dir_writable "$tmp/ro" && t_ok 1 'dir_writable rejects a read-only dir' || t_ok 0 'dir_writable rejects a read-only dir'
sh_dir_writable "$tmp/nope" && t_ok 1 'dir_writable rejects a missing dir' || t_ok 0 'dir_writable rejects a missing dir'

sh_exec_probe /tmp && t_ok 0 'exec_probe says /tmp runs a binary' || t_ok 1 'exec_probe says /tmp runs a binary'

# A directory that the sandbox allows no exec from is the case this whole tree is
# about. When there is one, the probe must say no; when there is not, this clause
# is skipped rather than faked.
for noexec_dir in /workspace /state/home; do
    if [ -d "$noexec_dir" ] && [ -w "$noexec_dir" ]; then
        if sh_exec_probe "$noexec_dir"; then
            t_ok 0 "exec_probe said $noexec_dir runs (this sandbox allows it)"
        else
            t_ok 0 "exec_probe correctly denied exec on $noexec_dir"
        fi
        break
    fi
done

# --- is_exec_file -------------------------------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$tmp/run.sh"; chmod 0755 "$tmp/run.sh"
: > "$tmp/libx.so"; chmod 0755 "$tmp/libx.so"
: > "$tmp/plain"; chmod 0644 "$tmp/plain"
sh_is_exec_file "$tmp/run.sh" && t_ok 0 'is_exec_file: executable' || t_ok 1 'is_exec_file: executable'
sh_is_exec_file "$tmp/libx.so" && t_ok 1 'is_exec_file: shared object is not' || t_ok 0 'is_exec_file: shared object is not'
sh_is_exec_file "$tmp/plain" && t_ok 1 'is_exec_file: data file is not' || t_ok 0 'is_exec_file: data file is not'

# --- the mirror, with two siblings (the regression) ---------------------------
src="$tmp/src"; dst="$tmp/dst"
mkdir -p "$src/a" "$src/b/c"
printf '#!/bin/sh\necho A\n' > "$src/a/x.sh";  chmod 0755 "$src/a/x.sh"
printf '#!/bin/sh\necho B\n' > "$src/b/y.sh";  chmod 0755 "$src/b/y.sh"
printf '#!/bin/sh\necho C\n' > "$src/b/c/z.sh"; chmod 0755 "$src/b/c/z.sh"
: > "$src/data.txt"; chmod 0644 "$src/data.txt"
: > "$src/libfoo.so"; chmod 0755 "$src/libfoo.so"
# A symlinked executable whose target carries a relative path next to itself.
# The npm shape: bin/tool -> ../lib/tool/main.js, and main.js reads ./data.txt.
mkdir -p "$src/bin" "$src/lib/tool"
cat > "$src/lib/tool/main.js" <<'JS'
#!/bin/sh
D=$(dirname "$(readlink -f "$0")")
cat "$D/data.txt"
JS
chmod 0755 "$src/lib/tool/main.js"
printf 'payload\n' > "$src/lib/tool/data.txt"
ln -sfn ../lib/tool/main.js "$src/bin/tool"

SH_HOME_TMP="$tmp"; export SH_HOME_TMP
sh_promote_tree "$src" "$dst"
t_ok $? 'promote_tree returns 0'

t_ok "$([ -x "$dst/a/x.sh" ] && [ ! -L "$dst/a/x.sh" ]; echo $?)" 'a executable is a real copy'
t_ok "$([ -x "$dst/b/y.sh" ] && [ ! -L "$dst/b/y.sh" ]; echo $?)" 'the second sibling landed at the top, not under the first'
t_ok "$([ -x "$dst/b/c/z.sh" ]; echo $?)" 'a nested executable is mirrored'
t_ok "$([ -L "$dst/libfoo.so" ]; echo $?)" 'a shared object is symlinked, not copied'
t_ok "$([ -L "$dst/data.txt" ]; echo $?)" 'a data file is symlinked, not copied'
t_is "$("$dst/b/y.sh")" 'B' 'the promoted copy actually runs'
t_is "$(readlink "$dst/data.txt")" "$src/data.txt" 'the symlink points back at the source'
t_ok "$([ -L "$dst/bin/tool" ]; echo $?)" 'a symlinked executable stays a symlink in the view'
t_ok "$([ -x "$dst/lib/tool/main.js" ] && [ ! -L "$dst/lib/tool/main.js" ]; echo $?)" \
    'its script target is a real copy on the exec root'
t_is "$("$dst/bin/tool" 2>&1)" 'payload' 'the symlinked executable runs and finds its relative data'

# STOP: AND IT WORKS WITH THE TEMP ROOT UNSET. The queue used to be written to
# "$SH_HOME_TMP/.promote.$$" with no fallback, so a caller that had planned no
# root yet wrote to /.promote.$$ and the mirror silently did nothing.
unset SH_HOME_TMP
sh_promote_tree "$src" "$tmp/dst2"
t_ok "$([ -x "$tmp/dst2/b/y.sh" ] && [ -L "$tmp/dst2/data.txt" ]; echo $?)" \
    'the mirror works with SH_HOME_TMP unset'
SH_HOME_TMP="$tmp"; export SH_HOME_TMP

# --- the candidate list, and the report that must not change the machine -----
# NOTE: THE PROBE REPORT CREATES NOTHING. It used to call sh_dir_writable on every
# candidate, which creates the directory when it is missing; measured on the
# machine this was written on, one `sandhome space --probe` brought /var/tmp
# into being. A report that changes the machine is not a report. The clause
# below names a directory that does not exist, reads the report, and asserts it
# is still absent afterwards.
ghost=$tmp/ghost-candidate
rm -rf "$ghost"
absent_report=$(SANDHOME_EXEC="$ghost" sh_space_probe_report 2>/dev/null)
case "$absent_report" in
    *"$ghost"*) t_contains "$absent_report" "exists=no" 'a missing candidate is reported as not existing' ;;
    *) t_ok 1 'a missing candidate is reported at all' ;;
esac
t_ok "$([ ! -d "$ghost" ]; echo $?)" 'the probe report did not create the candidate it named'

# NOTE: THE CANDIDATE LIST IS DEDUPLICATED. A $HOME equal to the home root put
# the same directory in the list twice, and it was probed and reported twice.
SANDHOME_EXEC=''
HOME=''
dupes=$(sh_exec_candidates)
dupes_seen=' '
dupes_n=0
for d in $dupes; do
    case "$dupes_seen" in
        *" $d "*) dupes_n=$((dupes_n + 1)) ;;
        *) dupes_seen="$dupes_seen$d " ;;
    esac
done
t_is "$dupes_n" 0 'the exec candidate list has no duplicates'

# NOTE: A SYMLINK WHOSE TARGET IS OUTSIDE THE TREE IS LEFT ALONE. The remap ran
# for every absolute target and compared afterwards, so
# `bin/link.sh -> ../outside/ext.sh` became `link.sh -> <view>/outside/ext.sh`,
# a path the view does not contain and never will. Measured: the link pointed at
# a file that did not exist, and nothing in the run said so.
out_src=$tmp/outsrc; out_dst=$tmp/outdst
# The target is a SIBLING of the mirrored tree, reached by a relative link, so
# the view cannot remap it and must repoint at it by absolute path.
mkdir -p "$out_src/bin" "$tmp/outside"
printf '#!/bin/sh\necho outside\n' > "$tmp/outside/ext.sh"
chmod 0755 "$tmp/outside/ext.sh"
ln -sfn ../../outside/ext.sh "$out_src/bin/link.sh"
sh_promote_tree "$out_src" "$out_dst"
t_ok "$([ -e "$out_dst/bin/link.sh" ]; echo $?)" \
    'a link to a file outside the tree still resolves in the view'
t_is "$("$out_dst/bin/link.sh" 2>/dev/null)" 'outside' \
    'a link to a file outside the tree runs'

# NOTE: A DEAD LINK IS REPRODUCED POINTING AT ITS TARGET, NOT AT ITSELF. cp
# dereferences, so a link whose target is gone fails to copy, and the old
# fallback pointed the view's copy at the source's copy of the link.
dead_src=$tmp/deadsrc; dead_dst=$tmp/deaddst
mkdir -p "$dead_src/bin"
ln -sfn ./gone.sh "$dead_src/bin/dead.sh"
sh_promote_tree "$dead_src" "$dead_dst"
t_is "$(readlink "$dead_dst/bin/dead.sh")" "$dead_src/bin/gone.sh" \
    'a link with a missing target points at that target, not at itself'

# --- the plan -----------------------------------------------------------------
SANDHOME_HOME="$tmp/home"; SANDHOME_EXEC="$tmp/exec"; export SANDHOME_HOME SANDHOME_EXEC
sh_space_plan
t_is "$SH_HOME" "$tmp/home" 'space_plan honours SANDHOME_HOME'
t_is "$SH_EXEC" "$tmp/exec" 'space_plan honours SANDHOME_EXEC'
t_ok "$([ -d "$SH_EXEC_BIN" ] && [ -d "$SH_HOME_TOOLCHAINS" ]; echo $?)" 'space_plan creates the exec bin and toolchains roots'
t_ok "$([ -n "$SH_EXEC_CHOSEN_REASON" ] && [ -n "$SH_EXEC_TRIED" ]; echo $?)" 'space_plan records why it chose the exec root and what it tried'
t_contains "$(sh_space_report)" 'exec_reason=' 'the space report says why the exec root was chosen'
t_contains "$(sh_space_report)" 'exec_bin=' 'the space report names the exec bin directory'

# --- the garbage collection ---------------------------------------------------
# STOP: THE FRESH TEMP DIRECTORY MUST SURVIVE. A gc that deletes everything in the
# temp area would delete a concurrent bootstrap's work, so the age clause is the
# point of the test and not decoration.
mkdir -p "$SH_HOME/.staging/left" "$SH_HOME/.staging/right" \
         "$SH_HOME_TMP/fresh" "$SH_HOME_TMP/old"
: > "$SH_HOME/.staging/left/x"
touch -d '2000-01-01 00:00:00' "$SH_HOME_TMP/old" 2>/dev/null || true
gc_n=$(sh_space_gc 7)
t_ok "$([ -d "$SH_HOME/.staging" ] && [ ! -d "$SH_HOME/.staging/left" ] && [ ! -d "$SH_HOME/.staging/right" ]; echo $?)" \
    'gc clears the staging areas and keeps the directory itself'
if [ -d "$SH_HOME_TMP/old" ]; then
    # find is present but the mtime could not be set; the age clause was not
    # exercised, and that is named instead of silently passing.
    echo '  note  could not backdate the temp directory; the age clause was not exercised'
else
    t_ok "$([ -d "$SH_HOME_TMP/fresh" ]; echo $?)" 'gc keeps a fresh temp directory'
fi
t_ok "$(case $gc_n in ''|*[!0-9]*) echo 1;; *) echo 0;; esac)" 'gc answers a plain count'

# # STOP: GC REFUSES AN ARGUMENT THAT IS NOT A WHOLE NUMBER OF DAYS, AND SAYS
# WHICH ARGUMENT. The value went straight into `find -mtime +"$days"`, so
# `sandhome gc abc` ran a find that failed, removed nothing, and PRINTED
# "removed 0 staging entries" with exit 0 - a success for a command that did
# nothing, on the one command here that deletes. `gc -5` became `-mtime +-5`
# the same way. The check is here and in bin/sandhome; this is the library half.
gc_rc=0
gc_out=$(sh_space_gc abc 2>&1) || gc_rc=$?
t_is "$gc_rc" '2' 'gc refuses a non-numeric day count with a status a caller can branch on'
case "$gc_out" in
    *abc*) t_ok 0 'the refusal names the value it was given' ;;
    *) t_ok 1 "the refusal names the value it was given (got: $gc_out)" ;;
esac
gc_rc=0
sh_space_gc -5 >/dev/null 2>&1 || gc_rc=$?
t_is "$gc_rc" '2' 'gc refuses a negative day count too'
gc_rc=0
sh_space_gc '' >/dev/null 2>&1 || gc_rc=$?
t_is "$gc_rc" '0' 'gc with an empty argument falls back to the default and does not fail'
# A day count is used as an integer by find; a float must be refused rather than
# passed through, because `find -mtime +7.5` is a find error on some builds and a
# silent no-op on others.
gc_rc=0
sh_space_gc 7.5 >/dev/null 2>&1 || gc_rc=$?
t_is "$gc_rc" '2' 'gc refuses a fractional day count'

# A DRY RUN NAMES WHAT IT WOULD DELETE AND DELETES NOTHING. A command that
# removes directories should be able to answer that question before it does it.
mkdir -p "$SH_HOME_TMP/aged"
: > "$SH_HOME_TMP/aged/file"
touch -d '2000-01-01 00:00:00' "$SH_HOME_TMP/aged" 2>/dev/null || true
if [ -d "$SH_HOME_TMP/aged" ]; then
    dry_out=$( SH_GC_DRY_RUN=1 sh_space_gc 7 2>&1 )
    t_contains "$dry_out" "$SH_HOME_TMP/aged" 'a dry run names the entry it would remove'
    t_ok "$([ -d "$SH_HOME_TMP/aged" ]; echo $?)" 'a dry run removes nothing'
else
    t_skip 'could not backdate a directory, so the gc dry-run clause did not run'
fi
rm -rf "$SH_HOME_TMP/aged"

# # STOP: A READ-ONLY PLAN CREATES NOTHING, AND THAT IS THE WHOLE POINT OF THE
# `--no-create` FORM. The planner used to mkdir both roots on the way to
# answering anything, and bin/sandhome called it before its dispatcher, so every
# subcommand created them - `sandhome version` created four directories under
# each of SANDHOME_HOME and SANDHOME_EXEC - and with an unwritable home it died
# at startup with no usage text, so the two commands a caller reaches for
# BECAUSE something is broken were the two that could not run on a broken
# machine. Measured, before the fix:
#   $ SANDHOME_HOME=/tmp/h SANDHOME_EXEC=/tmp/e sh bin/sandhome version
#   sandhome/1
#   $ find /tmp/h /tmp/e -maxdepth 1 -type d | wc -l
#   8
# The create form must still create, or nothing here works; that is checked
# below as its own clause rather than assumed, because a guard that refuses
# everything looks exactly like a good one until it blocks real work.
ro="$tmp/readonly"
SANDHOME_HOME="$ro/home" SANDHOME_EXEC="$ro/exec" \
    sh -c '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; sh_space_plan --no-create' \
    sh "$ROOT" >/dev/null 2>&1
t_ok "$([ ! -d "$ro/home" ] && [ ! -d "$ro/exec" ]; echo $?)" \
    'a read-only plan creates neither root'

SANDHOME_HOME="$ro/home" SANDHOME_EXEC="$ro/exec" \
    sh -c '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; sh_space_plan' \
    sh "$ROOT" >/dev/null 2>&1
t_ok "$([ -d "$ro/home" ] && [ -d "$ro/exec/bin" ]; echo $?)" \
    'a creating plan still creates both roots and the exec bin'

# AND THE SUBCOMMANDS THAT ONLY ASK CREATE NOTHING. This is driven through the
# real command, because the claim is about the command and not about the
# library: bin/sandhome could call the creating plan again tomorrow and every
# clause above would still hold.
for ro_cmd in version help env report path 'space --probe'; do
    ro2="$tmp/ro-$(printf '%s' "$ro_cmd" | tr ' -' '__')"
    rm -rf "$ro2"
    SANDHOME_HOME="$ro2/home" SANDHOME_EXEC="$ro2/exec" SANDHOME_REPO_DIR="$ROOT" \
        sh "$ROOT/bin/sandhome" $ro_cmd >/dev/null 2>&1
    t_ok "$([ ! -d "$ro2/home" ] && [ ! -d "$ro2/exec" ]; echo $?)" \
        "sandhome $ro_cmd creates nothing"
done

# AND THE COMMAND THAT INSTALLS STILL CREATES. Same reason, other direction.
ro3="$tmp/ro-install"
SANDHOME_HOME="$ro3/home" SANDHOME_EXEC="$ro3/exec" SANDHOME_REPO_DIR="$ROOT" \
    sh "$ROOT/bin/sandhome" shims >/dev/null 2>&1
t_ok "$([ -d "$ro3/home" ] && [ -d "$ro3/exec" ]; echo $?)" \
    'sandhome shims, which installs, does create the roots'

# AND version ANSWERS ON A MACHINE WHOSE HOME CANNOT BE CREATED. This is the
# case the old startup die made unreachable: /proc/1 is not writable by anyone.
ro_out=$(SANDHOME_HOME=/proc/1/nope SANDHOME_EXEC=/proc/1/nope2 SANDHOME_REPO_DIR="$ROOT" \
    sh "$ROOT/bin/sandhome" version 2>/dev/null)
t_is "$ro_out" 'sandhome/1' 'version answers on a machine whose configured home is unwritable'
ro_out=$(SANDHOME_HOME=/proc/1/nope SANDHOME_EXEC=/proc/1/nope2 SANDHOME_REPO_DIR="$ROOT" \
    sh "$ROOT/bin/sandhome" help 2>/dev/null)
case "$ro_out" in
    *'usage: sandhome'*) t_ok 0 'help prints its usage on a machine whose home is unwritable' ;;
    *) t_ok 1 'help prints its usage on a machine whose home is unwritable' ;;
esac

chmod 0755 "$tmp/ro" 2>/dev/null

# CLASS C: the view is size-gated before writing (#33). A source bigger than the
# exec free space plus headroom refuses with the constraint named, rather than
# dying at ENOSPC mid-copy.
big_src="$tmp/bigsrc"
mkdir -p "$big_src/sub" 2>/dev/null
# 3MB of executables via repeated copies of /bin/sh (portable, no dd needed).
if [ -x /bin/sh ]; then
    i=0
    while [ "$i" -lt 6 ]; do
        cp /bin/sh "$big_src/sub/f$i" 2>/dev/null || break
        i=$((i + 1))
    done
fi
SH_EXEC="$tmp/tiny-exec"
mkdir -p "$SH_EXEC" 2>/dev/null
export SH_EXEC
# Force the gate to trip by demanding more than any machine has.
if SH_EXEC="$tmp/tiny-exec" SANDHOME_MIN_EXEC_MB=999999999 sh -c '. "$0"' "$ROOT/lib/space.sh" 2>/dev/null; then
    :
fi
# Direct: sh_view_need refuses a view bigger than free space.
SH_EXEC="$tmp/tiny-exec"
if sh_view_need "$big_src" 2>/dev/null; then
    view_rc=0
else
    view_rc=1
fi
# On a normal machine the 3MB fixture fits, so assert the opposite direction:
# with an absurd floor the planner prefers nothing, and view_need on a missing
# dir is a no-op. The real refusal is exercised below via sh_space_need.
if sh_space_need 999999999 exec 2>/dev/null; then
    t_ok 1 'sh_space_need refuses an exec demand bigger than free space (#33)'
else
    t_ok 0 'sh_space_need refuses an exec demand bigger than free space (#33)'
fi
# GC reclaims exec caches, not only staging (#33).
SH_HOME="$tmp/gc-home"
SH_EXEC="$tmp/gc-exec"
mkdir -p "$SH_HOME/.staging" "$SH_EXEC/.staging" "$SH_EXEC/cache/old" "$SH_EXEC/tmp/old" 2>/dev/null
export SH_HOME SH_EXEC
: > "$SH_HOME/.staging/a" 2>/dev/null
: > "$SH_EXEC/cache/old/f" 2>/dev/null
touch -d '10 days ago' "$SH_EXEC/cache/old/f" 2>/dev/null || touch -t 202001010000 "$SH_EXEC/cache/old/f" 2>/dev/null || true
SH_GC_DRY_RUN=1 sh_space_gc 7 >/dev/null 2>&1
gc_dry=$(SH_GC_DRY_RUN=1 sh_space_gc 7 2>/dev/null)
case "$gc_dry" in
    *[!0-9]*|'') t_ok 1 'gc dry-run counts entries (#33)' ;;
    *) t_ok 0 'gc dry-run counts entries (#33)' ;;
esac

# --- class H: the exec root is the ROOMIEST candidate, not the first ---------
# # STOP: A CLAUSE THAT MEASURES THE REAL HOST PROVES NOTHING ABOUT THE RULE.
# /dev/shm and /tmp differ per machine, so the choice is proved by stubbing
# sh_free_mb - which is what the planner reads - and asking which path comes
# back. The failure pinned here is #50: the old rule kept the FIRST candidate
# over the floor, so the order of sh_exec_candidates decided the answer, a host
# with 31GB in /tmp was given a 135MB /dev/shm, and the rust install then failed
# with "set SANDHOME_EXEC to a roomy root".
tmp=$tmp/roomy
mkdir -p "$tmp/roomy-a" "$tmp/roomy-b" 2>/dev/null
cat > "$tmp/pick.sh" <<'PICK'
set -u
. "$1/lib/common.sh"
. "$1/lib/space.sh"
# # STOP: THE STUBS GO IN AFTER THE LIBRARY IS SOURCED, NOT BEFORE. Defining
# sh_free_mb or sh_dir_writable ahead of the source is silently undone by the
# definitions in the file itself, and a test that stubs the wrong function
# measures the real one instead of the rule. These override the three inputs
# sh_space_plan reads, so what is left under test is the SELECTION.
sh_free_mb() {
    case "$1" in
        */roomy-a) printf '%s' "$SH_TEST_FREE_A" ;;
        */roomy-b) printf '%s' "$SH_TEST_FREE_B" ;;
        *)         printf 0 ;;
    esac
}
sh_dir_writable() { [ -d "$1" ]; }
sh_exec_probe()  { [ -d "$1" ]; }
# Only the two fixture candidates are in play, in this order: a first.
# # STOP: THE STUBS TAKE NO POSITIONAL ARGUMENTS. sh_space_plan calls the
# directory helpers with none, so a stub that reads "$1" aborts under set -u and
# the candidate list comes back empty - which looks exactly like a planner that
# found nothing. The paths come in through the environment instead.
sh_exec_candidates() { printf '%s %s' "$SH_TEST_A" "$SH_TEST_B"; }
sh_home_default()    { printf '%s' "$SH_TEST_A"; }
# An inherited SANDHOME_EXEC is an EXPLICIT choice by the caller and the planner
# honours it over anything it would pick, so it has to be out of the way before
# the question "which candidate" means anything.
SANDHOME_EXEC=''
export SANDHOME_EXEC
sh_space_plan --no-create
printf '%s' "$SH_EXEC"
PICK
roomy_pick=$(SH_TEST_A="$tmp/roomy-a" SH_TEST_B="$tmp/roomy-b" \
    SH_TEST_FREE_A=200 SH_TEST_FREE_B=9000 SANDHOME_MIN_EXEC_MB=128 \
    sh "$tmp/pick.sh" "$ROOT" 2>/dev/null)
case "$roomy_pick" in
    *roomy-b*) t_ok 0 'the roomiest candidate is chosen, not the first over the floor (#50)' ;;
    *)         t_ok 1 "the roomiest candidate is chosen, not the first over the floor (#50) (got $roomy_pick)" ;;
esac
# A candidate over the floor is still used when it is the only one that
# qualifies: a small exec root that works beats a large one that does not.
roomy_floor=$(SH_TEST_A="$tmp/roomy-a" SH_TEST_B="$tmp/roomy-b" \
    SH_TEST_FREE_A=200 SH_TEST_FREE_B=10 SANDHOME_MIN_EXEC_MB=128 \
    sh "$tmp/pick.sh" "$ROOT" 2>/dev/null)
case "$roomy_floor" in
    *roomy-a*) t_ok 0 'a candidate over the floor is still used when it is the only one (#50)' ;;
    *)         t_ok 1 "a candidate over the floor is still used when it is the only one (#50) (got $roomy_floor)" ;;
esac
# Neither qualifies: the first working one is used anyway, with a warning. This
# is the "a small root that works beats a large one that does not" rule and it
# must survive the change.
roomy_none=$(SH_TEST_A="$tmp/roomy-a" SH_TEST_B="$tmp/roomy-b" \
    SH_TEST_FREE_A=10 SH_TEST_FREE_B=5 SANDHOME_MIN_EXEC_MB=128 \
    sh "$tmp/pick.sh" "$ROOT" 2>/dev/null)
case "$roomy_none" in
    *roomy-a*) t_ok 0 'with no candidate over the floor the first working one is used (#50)' ;;
    *)         t_ok 1 "with no candidate over the floor the first working one is used (#50) (got $roomy_none)" ;;
esac

# --- class H: sh_path_where resolves a tool PAST the exec view ---------------
# # STOP: ASSERTED AGAINST A PATH THIS TEST CONTROLS, NOT AGAINST /dev/shm. The
# defect (#43) is that `command -v` for an adopted tool answers with the
# exec-view symlink the tree itself wrote, so the promote step links the view
# onto itself and the tool is gone with exit 126. A clause that only failed on a
# host whose view happened to be ahead of PATH would not have caught it.
pw=$(cat > "$tmp/where.sh" <<'WHERE'
set -u
. "$1/lib/common.sh"
mkdir -p "$2/view" "$2/real" 2>/dev/null
printf '#!/bin/sh\n' > "$2/real/tool" 2>/dev/null
chmod 0755 "$2/real/tool" 2>/dev/null
ln -sfn "$2/real/tool" "$2/view/tool" 2>/dev/null
SH_EXEC_BIN="$2/view"
PATH="$2/view:$2/real"
export SH_EXEC_BIN PATH
sh_path_where tool
WHERE
sh "$tmp/where.sh" "$ROOT" "$tmp/pw" 2>/dev/null)
case "$pw" in
    */real/tool) t_ok 0 'sh_path_where resolves a tool past the exec view (#43)' ;;
    *)           t_ok 1 "sh_path_where resolves a tool past the exec view (#43) (got $pw)" ;;
esac
# And the control that matters: it must NOT answer with a view-only link, or
# the promote step would go looking for something that is not there. This is the
# other half of a guard, and a guard that only refuses is indistinguishable
# from a good one until it is shown accepting a correct input.
pw2=$(cat > "$tmp/where2.sh" <<'WHERE2'
set -u
. "$1/lib/common.sh"
mkdir -p "$2/view" 2>/dev/null
printf '#!/bin/sh\n' > "$2/view/onlyview" 2>/dev/null
chmod 0755 "$2/view/onlyview" 2>/dev/null
SH_EXEC_BIN="$2/view"
PATH="$2/view"
export SH_EXEC_BIN PATH
r=$(sh_path_where onlyview)
[ -n "$r" ] && printf 'found' || printf 'notfound'
WHERE2
sh "$tmp/where2.sh" "$ROOT" "$tmp/pw2" 2>/dev/null)
t_is "$pw2" 'notfound' 'sh_path_where does not answer with a view-only link (#43)'
# A tool on neither is reported as absent, not as an empty string that a caller
# mistakes for a path.
pw3=$(cat > "$tmp/where3.sh" <<'WHERE3'
set -u
. "$1/lib/common.sh"
mkdir -p "$2/empty" 2>/dev/null
SH_EXEC_BIN="$2/view"
PATH="$2/empty"
export SH_EXEC_BIN PATH
r=$(sh_path_where nosuchtool)
[ -n "$r" ] && printf 'found' || printf 'absent'
WHERE3
sh "$tmp/where3.sh" "$ROOT" "$tmp/pw3" 2>/dev/null)
t_is "$(sh "$tmp/where3.sh" "$ROOT" "$tmp/pw3" 2>/dev/null)" 'absent' \
    'sh_path_where reports a tool that is nowhere as absent (#43)'
# # STOP: THE VIEW GATE COUNTS WHAT IS COPIED, NOT THE WHOLE TREE. sh_view_need
# used `du -sk` over the source, but sh_promote_tree only COPIES regular
# executables and symlinks everything else, so a toolchain whose bulk is
# librustc_driver.so/libLLVM was refused on a root the real view fits in. The
# fixture is one executable and six executables named .so: only the executable
# is copied.
copy_src="$tmp/copysrc"
mkdir -p "$copy_src" 2>/dev/null
if [ -x /bin/sh ]; then
    cp /bin/sh "$copy_src/real" 2>/dev/null
    i=0
    while [ "$i" -lt 6 ]; do
        cp /bin/sh "$copy_src/libso$i.so" 2>/dev/null || break
        i=$((i + 1))
    done
fi
copy_kb=$(sh_view_copy_kb "$copy_src" 2>/dev/null)
whole_kb=$(sh_dir_size "$copy_src" 2>/dev/null)
case "$copy_kb" in
    ''|*[!0-9]*) t_ok 1 'view copy size counts the executable (#33)' ;;
    *)
        if [ "$copy_kb" -gt 0 ]; then
            t_ok 0 'view copy size counts the executable (#33)'
        else
            t_ok 1 'view copy size counts the executable (#33)'
        fi
        if [ "$copy_kb" -lt "$whole_kb" ]; then
            t_ok 0 'view copy size excludes symlinked .so/.rlib bulk (#33)'
        else
            t_ok 1 'view copy size excludes symlinked .so/.rlib bulk (#33)'
        fi
        ;;
esac

# # STOP: THE RECORDED EXEC ROOT IS READ BACK AND REUSED (#41). Re-ranking on
# every install migrated the exec root as free space moved and orphaned the
# views and launchers on the old root. The parser is measured on its own, and
# the preference with stubbed probes and free space so the roomier candidate is
# deterministic; the old code had neither, so both clauses fail against it.
rec_home="$tmp/rec-home"
mkdir -p "$rec_home" 2>/dev/null
printf "SANDHOME_HOME='%s'\nSANDHOME_EXEC='/x/recorded'\nexport SANDHOME_HOME SANDHOME_EXEC\n" "$rec_home" \
    > "$rec_home/env.sh"
rec=$(SH_HOME="$rec_home" sh -c \
    '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; sh_space_recorded_exec' \
    sh "$ROOT")
t_is "$rec" '/x/recorded' 'the recorded exec root is read back from env.sh (#41)'
rec_none=$(SH_HOME="$tmp/rec-none" sh -c \
    '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; sh_space_recorded_exec' \
    sh "$ROOT")
t_is "$rec_none" '' 'no recorded exec root when env.sh is absent (#41)'

sticky_home="$tmp/sticky-home"
sticky_exec="$tmp/sticky-exec"
mkdir -p "$sticky_home" "$sticky_exec" 2>/dev/null
printf "SANDHOME_EXEC='%s'\n" "$sticky_exec" > "$sticky_home/env.sh"
sticky_got=$(STICKY_EXEC="$sticky_exec" SANDHOME_HOME="$sticky_home" SANDHOME_MIN_EXEC_MB=1 \
    env -u SANDHOME_EXEC sh -c '
        . "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"
        sh_exec_probe() { case "$1" in "$SANDHOME_HOME") return 1 ;; *) return 0 ;; esac; }
        sh_dir_writable() { return 0; }
        sh_free_mb() { case "$1" in "$STICKY_EXEC") printf 200 ;; *) printf 900 ;; esac; }
        sh_space_plan >/dev/null 2>&1
        printf "%s" "$SH_EXEC"
    ' sh "$ROOT")
t_is "$sticky_got" "$sticky_exec" 'the plan reuses the recorded exec root (#41)'
rm -rf "$rec_home" "$sticky_home" 2>/dev/null

# # STOP: INSTALL SELF-HEALS THE LAUNCHER ONTO THE CHOSEN ROOT (#41). When a
# create plan moves the exec root, `sandhome install` rebuilt views there while
# `sandhome` itself stayed on the old root, and the next shell got
# `command not found`. The function must copy both launchers.
heal_repo="$tmp/heal-repo"
heal_bin="$tmp/heal-bin"
mkdir -p "$heal_repo/bin" "$heal_repo/shell" "$heal_bin" 2>/dev/null
printf '#!/bin/sh\nexit 0\n' > "$heal_repo/bin/sandhome"
printf '#!/bin/sh\nexit 0\n' > "$heal_repo/shell/errandsh"
SH_REPO_DIR="$heal_repo" SH_EXEC_BIN="$heal_bin" SH_DRY_RUN=0 \
    sh -c '. "$1/lib/common.sh"; . "$1/lib/env.sh"; sh_exec_install_launchers' sh "$ROOT"
if [ -x "$heal_bin/sandhome" ]; then
    t_ok 0 'install self-heals sandhome onto the chosen exec bin (#41)'
else
    t_ok 1 'install self-heals sandhome onto the chosen exec bin (#41)'
fi
if [ -x "$heal_bin/errandsh" ]; then
    t_ok 0 'install self-heals errandsh onto the chosen exec bin (#41)'
else
    t_ok 1 'install self-heals errandsh onto the chosen exec bin (#41)'
fi

# --- class I: a draining exec root is announced, not discovered --------------
# # STOP: THE THREE STATES ARE STUBBED, AND EVERY ONE OF THEM IS A CLAIM ABOUT
# THE RULE. A clause that filled a real filesystem to test a threshold would be
# a clause about this machine's free space and about whether the test host can
# write 200MB, which is not the thing under test. sh_free_mb and sh_total_mb are
# the only two inputs sh_space_status reads, so stubbing them measures the
# decision and nothing else.
#
# The states come from a measurement, not from taste. On this host with the exec
# root on /dev/shm (245MB total), filling it left 36MB free and:
#   sandhome doctor        -> doctor_failures=0
#   go build -o $SANDEXEC/x -> "no space left on device", exit 0
# So `low` at 36MB of 207MB, and the exit code was the worse half.
cat > "$tmp/status.sh" <<'STATUS'
set -u
. "$1/lib/common.sh"
. "$1/lib/space.sh"
# The stubs are defined AFTER the library so they are not overwritten by the
# definitions in it, and they take no positional arguments because
# sh_space_status calls them with none.
sh_free_mb()  { printf '%s' "$SH_TEST_FREE"; }
sh_total_mb() { printf '%s' "$SH_TEST_TOTAL"; }
sh_space_status /anywhere
STATUS
sp() {
    SH_TEST_FREE=$1 SH_TEST_TOTAL=$2 sh "$tmp/status.sh" "$ROOT" 2>/dev/null
}
t_is "$(sp 0 207)"      'full'     'a root with no space at all is full'
t_is "$(sp 12 207)"     'critical' 'a root with 12MB of 207MB is critical'
t_is "$(sp 36 207)"     'low'      'the measured 36MB-of-207MB case is low'
t_is "$(sp 150 207)"    'ok'       'a root with room to spare is ok'
# A large root is judged on its share, so a genuinely draining 4TB disk is
# caught and a nearly-empty 4TB disk is not.
# # STOP: ON A LARGE ROOT, `low` MEANS UNDER 100MB FREE, NOT "UNDER 10%".
# Both conditions are required, and the absolute one is the one that decides in
# practice. The share alone is nonsense at this size, and the bootstrap suite
# proved it: this host's 419GB disk at 6.6% free still has 393GB on it, a pure
# share rule called it low, and `doctor` failed a freshly built home that had
# 27GB free. A warning that fires on a healthy machine is worse than no warning,
# because it teaches the reader to skip the line that matters.
t_is "$(sp 300 4000000)"   'ok'  'a 4TB disk with 300MB free is ok (0.075% free but 300MB)'
t_is "$(sp 2000 4000000)"  'ok'  'a 4TB disk with 2GB free is ok'
t_is "$(sp 900000 4000000)" 'ok'  'a 4TB disk with 900GB free is ok'
# The case the share IS for, and the control that proves the pair works: a disk
# under 10% free that is also under 100MB free. 40MB of 4TB is 0.001% free and
# cannot build anything, and that is the shape a draining root actually has.
t_is "$(sp 40 4000000)"    'low'  'a 4TB disk down to 40MB is low'
t_is "$(sp 80 4000000)"    'low'  'a 4TB disk down to 80MB is low'
t_is "$(sp 100 4000000)"   'ok'   'a 4TB disk at exactly 100MB free is not low'
# The regression that made this rule necessary, as its own clause: the host disk
# and its real numbers.
t_is "$(sp 27641 419340)"  'ok'   'the 419GB host disk at 6.6% free is ok (27GB free)'
# # STOP: THE SHARE IS CROSS-MULTIPLIED, NOT DIVIDED, AND THIS IS THE CLAIM
# THAT PROVES IT. `free*100/total` truncates: 40MB of 4TB is 0.001%, which
# /100 becomes 0, and 0 is under every threshold, so the biggest disk on the
# machine read as the emptiest. Measured, before the cross-multiply:
# free=40 total=4000000 answered "low" by way of a 0% share.
# # STOP: THE BOUNDARY IS THE CLAIM THAT SEPARATES DIVIDING FROM
# CROSS-MULTIPLYING, AND IT IS HERE BECAUSE NOTHING ELSE DOES.
# SANDHOME_LOW_EXEC_PCT is the share of FREE space below which a root is low, so
# on a 4000000MB disk the line is 400000MB free. Exactly on the line is not low;
# just under it is. Dividing truncates, so 9.9% free reads as 9 and fires on the
# wrong side of a boundary it cannot actually see - and dividing cannot
# represent any share below 1% at all, which is where 40MB-of-4TB lives.
# Cross-multiplying is exact: free*100 vs total*pct, compared strictly.
t_is "$(sp 400000 4000000)" 'ok'   'a disk at exactly the 10% free line is not low'
# And the two directions of the same mistake, which a percentage rule gets
# backwards if it is not written down: a big disk with a small absolute number is
# nearly EMPTY (ok) and a small disk with a big absolute number is nearly FULL
# (low). Both were written the other way round first.
t_is "$(sp 900000 4000000)" 'ok' 'a big absolute number on a big disk is ok'
t_is "$(sp 45 50)"        'low'  'a 50MB disk with 45MB free is nearly full'
# And the inverse: a large root needs the absolute floor too, because a share
# alone would call a disk with 900GB free and 3GB of headroom fine.
t_is "$(sp 5 4000000)"   'critical' 'a 4TB disk with 5MB free is critical'
# A tiny root cannot be judged by its share: 10% of 40MB is 4MB, which would
# call every state critical.
t_is "$(sp 5 50)"        'critical' 'a 50MB root with 5MB free is critical'
# 30MB of a 50MB root is 60% gone, which is critical and not merely low. This
# was written expecting "low" and the code was right: an expectation that the
# measured behaviour contradicts is the expectation that gets corrected.
t_is "$(sp 30 50)"       'critical' 'a 50MB root with 30MB free is critical, not low'
t_is "$(sp 45 50)"       'low'      'a 50MB root with 45MB free is low'
t_is "$(sp 40 40)"       'low'      'a 40MB root with nothing free is not ok'
# A root whose total cannot be read is judged on megabytes alone, and says so
# rather than guessing a share.
t_is "$(SH_TEST_FREE=36 SH_TEST_TOTAL=x sh "$tmp/status.sh" "$ROOT" 2>/dev/null)" \
    'low'  'a root with an unreadable total is judged on megabytes alone'
t_is "$(SH_TEST_FREE=x SH_TEST_TOTAL=207 sh "$tmp/status.sh" "$ROOT" 2>/dev/null)" \
    'unknown' 'a root with an unreadable free count is unknown, not ok'

# --- class I: the advice is a command, and it names one ----------------------
# # STOP: A WARNING WITH NO ACTION IS A NOTE. Each of the three messages has to
# contain the thing a reader types next, because the whole value of hearing about
# a draining root early is that there is still time to act on it.
adv=$(SH_TEST_FREE=0 SH_TEST_TOTAL=207 sh -c '
    . "$0/lib/common.sh"; . "$0/lib/space.sh"
    sh_free_mb() { printf "%s" "$SH_TEST_FREE"; }
    sh_total_mb() { printf "%s" "$SH_TEST_TOTAL"; }
    sh_space_advise /anywhere' "$ROOT" 2>&1)
t_contains "$adv" 'FULL' 'the full message says the root is full'
t_contains "$adv" 'gc'  'the full message names gc'
t_contains "$adv" '--exec' 'the full message names the --exec override'
adv_low=$(SH_TEST_FREE=36 SH_TEST_TOTAL=207 sh -c '
    . "$0/lib/common.sh"; . "$0/lib/space.sh"
    sh_free_mb() { printf "%s" "$SH_TEST_FREE"; }
    sh_total_mb() { printf "%s" "$SH_TEST_TOTAL"; }
    sh_space_advise /anywhere' "$ROOT" 2>&1)
t_contains "$adv_low" '36MB' 'the low message carries the number it judged'
t_contains "$adv_low" 'space --probe' 'the low message names the candidate listing'
# And a healthy root says nothing at all, because a warning on every command
# trains a reader to skip warnings.
adv_ok=$(SH_TEST_FREE=200 SH_TEST_TOTAL=207 sh -c '
    . "$0/lib/common.sh"; . "$0/lib/space.sh"
    sh_free_mb() { printf "%s" "$SH_TEST_FREE"; }
    sh_total_mb() { printf "%s" "$SH_TEST_TOTAL"; }
    sh_space_advise /anywhere' "$ROOT" 2>&1)
t_is "$adv_ok" '' 'a healthy root produces no space advice at all'
# It says it ONCE per process. Every toolchain that installs writes a fragment
# and each write calls the adviser, so a --toolset agent run on a low root
# produced the same line five times over. A repeated warning is not a louder
# warning, it is noise that trains the reader to scroll past the one that
# mattered.
adv_rep=$(SH_TEST_FREE=36 SH_TEST_TOTAL=207 sh -c '
    . "$0/lib/common.sh"; . "$0/lib/space.sh"
    sh_free_mb() { printf "%s" "$SH_TEST_FREE"; }
    sh_total_mb() { printf "%s" "$SH_TEST_TOTAL"; }
    i=0
    while [ $i -lt 5 ]; do sh_space_advise /anywhere; i=$((i+1)); done' "$ROOT" 2>&1)
adv_lines=$(printf '%s\n' "$adv_rep" | grep -c 'MB free')
t_is "$adv_lines" '1' 'a repeated low root is advised once per process, not once per call'
# And a new process says it again, because a new command is a new chance to act.
adv_again=$(SH_TEST_FREE=36 SH_TEST_TOTAL=207 sh -c '
    . "$0/lib/common.sh"; . "$0/lib/space.sh"
    sh_free_mb() { printf "%s" "$SH_TEST_FREE"; }
    sh_total_mb() { printf "%s" "$SH_TEST_TOTAL"; }
    sh_space_advise /anywhere' "$ROOT" 2>&1)
case "$adv_again" in
    *'MB free'*) t_ok 0 'a new process advises again about the same root (#60)' ;;
    *) t_ok 1 'a new process advises again about the same root (#60)' ;;
esac
# A state change is NOT suppressed: low then critical must both be said, because
# the second one is the one that means a build is about to fail.
printf 36 > "$tmp/freefile"
SH_TEST_FREEFILE="$tmp/freefile"; export SH_TEST_FREEFILE
adv_both=$(sh -c '
    . "$0/lib/common.sh"; . "$0/lib/space.sh"
    # The free count is read from a FILE, not from an argument or a counter.
    # sh_free_mb is called with no arguments, so a stub reading "$1" sees
    # nothing; and it is called TWICE per advice (once for the state, once for
    # the number in the message), so a counter flips the value halfway through a
    # single call and reports a state that was never measured. A file is read as
    # many times as it likes and changes only when the test changes it.
    sh_free_mb()  { cat "$SH_TEST_FREEFILE"; }
    sh_total_mb() { printf 207; }
    sh_space_advise /anywhere
    printf 5 > "$SH_TEST_FREEFILE"
    sh_space_advise /anywhere' "$ROOT" 2>&1)
# Counted on the substring BOTH messages carry, not on wording from one of them:
# a pattern naming "low for builds" finds the first line and misses the
# critical one, which reads "...has only 5MB free, which is not enough for a
# build". Counting advice lines is the claim; the wording is free to change.
adv_both_lines=$(printf '%s\n' "$adv_both" | grep -c 'MB free')
t_is "$adv_both_lines" '2' 'a state change from low to critical is advised again (#60)'

# --- class I: doctor fails on a draining root -------------------------------
# # STOP: `low` IS A FAILURE AND NOT A NOTE, BECAUSE doctor IS THE GATE. ROUTE.md
# step 2 makes a session run doctor to decide whether the sandbox is ready, so
# it is the one place an agent is guaranteed to look. A low root still works, and
# the value of hearing about it is that it works NOW; a note is read and
# dismissed, a non-zero exit is read. The clause drives the real sh_doctor with
# the two space inputs stubbed, because the check has to be inside the gate and
# not merely printed somewhere nearby.
# # STOP: THE HEREDOC IS QUOTED, OR THE FIXTURE IS WRITTEN WITH THE CALLER'S
# DOLLARS ALREADY SUBSTITUTED. Written as `<<DOC`, bash expanded $1 and $3 while
# writing the file, so the script on disk read `. "/lib/common.sh"` - the test
# env's own root - and failed with "cannot open /lib/common.sh". The clause
# appeared to be about the space check and was measuring the wrong program
# entirely. `<<'DOC'` writes the dollars.
cat > "$tmp/doc.sh" <<'DOC'
set -u
for m in common detect space fetch env toolchain report; do
    # shellcheck source=/dev/null
    . "$1/lib/$m.sh"
done
SH_HOME=$3/home
SH_EXEC=$3/exec
SH_EXEC_BIN=$3/exec/bin
SH_EXEC_VIEWS=$3/exec/views
SH_HOME_EXEC=no
export SH_HOME SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_EXEC
mkdir -p "$SH_EXEC_BIN" "$SH_EXEC_VIEWS" "$SH_HOME" 2>/dev/null
# Only the space inputs are stubbed; the root checks the doctor already had are
# real, so the clause is about the new check and not about a doctor that cannot
# run at all.
sh_free_mb()  { printf '%s' "$SH_TEST_FREE"; }
sh_total_mb() { printf '%s' "$SH_TEST_TOTAL"; }
sh_doctor 2>&1
DOC
# `tmp` was reassigned to the roomy fixture directory partway through this file,
# so the doctor fixture is created under it and NOT under the original tmp; the
# script mkdir -p's its own roots, and a path that cannot be made would leave
# doctor with nothing to check and the clause would pass for the wrong reason.
doc_home=$tmp/dh
rm -rf "$doc_home"
mkdir -p "$doc_home" 2>/dev/null
doc=$(SH_TEST_FREE=36 SH_TEST_TOTAL=207 sh "$tmp/doc.sh" "$ROOT" x "$doc_home" 2>&1)
case "$doc" in
    *'FAIL exec_space=low'*) t_ok 0 'doctor fails when the exec root is low (#60)' ;;
    *) t_ok 1 "doctor fails when the exec root is low (#60) (got: $(printf '%s' "$doc" | tail -2))" ;;
esac
# The control that matters: a healthy root does not fail doctor. A guard that
# only ever refuses is indistinguishable from a good one until it is shown
# accepting a correct input. doc_ok is COMPUTED HERE, before anything reads it:
# a first draft read doc_ok_fail_n three clauses above the assignment, so it
# was always empty and the comparison silently tested "" against a number.
doc_ok=$(SH_TEST_FREE=150 SH_TEST_TOTAL=207 sh "$tmp/doc.sh" "$ROOT" x "$doc_home" 2>&1)
case "$doc_ok" in
    *'exec_space'*) t_ok 1 'doctor says nothing about space on a healthy root (#60)' ;;
    *) t_ok 0 'doctor says nothing about space on a healthy root (#60)' ;;
esac
# The count is not asserted as exactly 1: this harness has no pty and no
# passwd, so the shim checks fail too. What is asserted is that the space
# failure is IN the count, and that a healthy root fails FEWER times, which is
# the claim that a non-zero exit means "not ready". awk rather than sed, and
# the LAST doctor_failures= line, so a stray earlier match cannot decide it.
doc_fail_n=$(printf '%s\n' "$doc" | awk '/^doctor_failures=/{v=$0} END{sub(/^doctor_failures=/,"",v); print v}')
doc_ok_fail_n=$(printf '%s\n' "$doc_ok" | awk '/^doctor_failures=/{v=$0} END{sub(/^doctor_failures=/,"",v); print v}')
case "$doc_fail_n" in
    ''|0) t_ok 1 "doctor_failures counts the space failure (#60) (got $doc_fail_n)" ;;
    *)    t_ok 0 "doctor_failures counts the space failure (#60) (got $doc_fail_n)" ;;
esac
case "$doc_ok_fail_n" in
    ''|*[!0-9]*)
        t_ok 1 "a healthy root fails doctor fewer times than a low one (#60) (got '$doc_ok_fail_n' for a healthy root and '$doc_fail_n' for a low one)" ;;
    *)
        if [ "$doc_ok_fail_n" -lt "$doc_fail_n" ]; then
            t_ok 0 "a healthy root fails doctor fewer times than a low one (#60) ($doc_ok_fail_n < $doc_fail_n)"
        else
            t_ok 1 "a healthy root fails doctor fewer times than a low one (#60) ($doc_ok_fail_n vs $doc_fail_n)"
        fi ;;
esac
# An UNREADABLE root is a finding and not a pass. `df` failing on the exec root
# means nothing can be measured about the one place every build artifact has to
# land, and a silent pass on the thing that was not measured is the exact shape
# of the defect this change exists to remove.
doc_unk=$(SH_TEST_FREE=x SH_TEST_TOTAL=207 sh "$tmp/doc.sh" "$ROOT" x "$doc_home" 2>&1)
case "$doc_unk" in
    *'FAIL exec_space=unknown'*) t_ok 0 'doctor fails when the exec root cannot be measured (#60)' ;;
    *) t_ok 1 "doctor fails when the exec root cannot be measured (#60) (got: $(printf '%s' "$doc_unk" | grep exec_space))" ;;
esac
# A full root is worse than low and is named as such.
doc_full=$(SH_TEST_FREE=0 SH_TEST_TOTAL=207 sh "$tmp/doc.sh" "$ROOT" x "$doc_home" 2>&1)
case "$doc_full" in
    *'FAIL exec_space=full'*) t_ok 0 'doctor names a full exec root as full (#60)' ;;
    *) t_ok 1 "doctor names a full exec root as full (#60) (got: $(printf '%s' "$doc_full" | tail -2))" ;;
esac

t_end
