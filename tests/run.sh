#!/bin/sh
# tests/run.sh - run every sandhome test.
#
# THREE CLAIMS, KEPT APART, AND ONLY ONE OF THEM IS A NON-ZERO STATUS.
#   passed  every clause in the file ran here and held
#   skipped the file could not run here (no network, no compiler, no pty)
#   failed  a clause ran here and did not hold
# A skip is a fact about the machine, not a defect in the tree, so it is printed
# and does not turn the suite red. It used to exit 2, and CI ran this suite, so
# a runner without a network failed the job for a reason that is not a bug and
# the first thing a maintainer learns is to ignore a red suite.
#
# The file is read through an interpreter and never executed, because this
# checkout may itself be on a mount that refuses execve - the condition the tree
# exists for. Each file's own tally is read as well as its status, so a file that
# prints a failure and exits 0 is still a failure.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FAILED=''
SKIPPED=''
PASSED=''

# # STOP: harness IS FIRST, BECAUSE IT GRADES EVERY OTHER FILE. `t_end` used to
# `return` its status instead of exiting with it, and a script cannot exit with
# a value another function returned, so a test file whose last command was not
# t_end exited 0 however many clauses it had failed. run.sh reads the exit code
# to decide passed/failed, so those files were reported under `passed`, and a
# failing suite was green. tests/harness.sh now measures that directly; running
# it first means a break in the harness is visible before it is mistaken for
# anything else.
for t in harness syntax unit space fetch toolchain memexec shims docs bootstrap global consumer errandsh-posix regressions-141-147 regressions-149-150 regressions-151-164 regressions-beyond-166 regressions-167-174 regressions-175-179 regressions-181-186 regressions-187-192; do
    script="$HERE/$t.sh"
    [ -r "$script" ] || continue
    printf '\n#### %s\n' "$t"
    # ALWAYS THROUGH AN INTERPRETER, NEVER BY EXECUTING THE FILE. This tree is
    # worked on from a checkout that may itself be on a noexec mount, and
    # `./tests/x.sh` then fails with `Permission denied` on a file that is fine.
    # A test is a script; naming its reader is the portable way to run it.
    first=''
    IFS= read -r first < "$script" 2>/dev/null || first=''
    t_failed=''
    # # STOP: THE OUTPUT IS KEPT, NOT SENT STRAIGHT TO THE TERMINAL, BECAUSE THE
    # FILE'S OWN TALLY IS READ AND COMPARED WITH ITS EXIT STATUS. The two
    # disagreeing is the failure mode this whole file exists to catch: a harness
    # that prints FAIL and leaves its counter at zero ends 0, and a file that
    # prints "3 failed" while exiting 0 is the same thing one level up. Both are
    # read here and both are reported, because `skipped` and `passed` are the
    # only two claims a reader of the summary takes away.
    #
    # The output goes to a FILE and the status is kept, rather than both through
    # one command substitution. A first version parsed the captured text in a
    # `while` loop that advanced with `${rest#*"$NL"}`; when a file printed no
    # trailing newline that expansion returned the string UNCHANGED, the loop
    # never advanced, and the whole suite hung for fifteen minutes. A file, a
    # `$?` read straight after the command, and a `read` loop that terminates on
    # a last line with no newline in it - which is the pattern tests/lib.sh
    # already documents and uses.
    t_log=$HERE/.$t.out.$$
    case "$first" in
        *bash*) bash "$script" > "$t_log" 2>&1 ;;
        *)      sh "$script" > "$t_log" 2>&1 ;;
    esac
    t_rc=$?
    if [ -r "$t_log" ]; then
        while IFS= read -r t_line || [ -n "$t_line" ]; do
            printf '%s\n' "$t_line"
            # The summary line every test file ends with: "<name>: N run, M
            # failed, K skipped". M is read here, with the shell, because this
            # file must run on a userland with no grep.
            case "$t_line" in
                "$t: "*' run, '*' failed, '*' skipped')
                    # "name: N run, M failed, K skipped" -> M. Split on ", " and
                    # take the middle field, stripping the " failed" tail. A
                    # version that took the FIRST number captured N, the run
                    # count, and reported every passing file as having failed.
                    t_mid=${t_line#*', '}
                    t_mid=${t_mid%%' failed'*}
                    case "$t_mid" in
                        ''|*[!0-9]*) : ;;
                        *) t_failed=$t_mid ;;
                    esac
                    ;;
            esac
        done < "$t_log"
        rm -f "$t_log" 2>/dev/null
    fi
    if [ -n "$t_failed" ] && [ "$t_failed" -gt 0 ] && [ "$t_rc" = 0 ]; then
        printf '  (note: %s reported %s failed but exited 0; treating it as failed)\n' \
               "$t" "$t_failed"
        t_rc=1
    fi
    # # STOP: AN EXIT CODE OUTSIDE THE THREE IS A FAILURE, AND IT IS NOW SAID
    # OUT LOUD. The case below coerces anything unexpected to 1, which is right -
    # a file killed by a signal did not pass - but a reader of the summary could
    # not tell a coerced code from a reported one, so a file that died with 127
    # or 137 looked exactly like a file that ran and failed.
    case "$t_rc" in
        0|1|2) ;;
        *) printf '  (note: %s exited %s, which is outside 0/1/2; treated as failed)\n' \
               "$t" "$t_rc"
           t_rc=1 ;;
    esac
    if [ "$t_rc" = 0 ]; then
        PASSED="$PASSED $t"
    elif [ "$t_rc" = 2 ]; then
        SKIPPED="$SKIPPED $t"
    else
        FAILED="$FAILED $t"
    fi
done

# The exec-candidate plan mkdir -p's the namespaced work-tree candidate even
# when it does not choose it (issue #114). The checkout is left as it was
# found, whether or not the create-plan ever selected that root.
rm -rf "$HERE/../.sandhome" "$HERE/.sandhome" 2>/dev/null

printf '\n===============================\n'
printf 'passed :%s\n' "$PASSED"
printf 'skipped:%s\n' "$SKIPPED"
printf 'failed :%s\n' "$FAILED"
if [ -n "$FAILED" ]; then
    exit 1
fi
exit 0
