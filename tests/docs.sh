#!/bin/sh
# tests/docs.sh - the documentation is checked against the code, not trusted.
#
# WHY THIS FILE EXISTS. Every document here is read by an agent that will type
# what it reads. A document naming a flag the code does not have, a variable
# nothing reads, or a command that falls through to "unknown command" is worse
# than no document: it costs a session to discover. Three such defects were live
# in this tree before this file existed (the help named a subcommand that did
# not exist; the guide's exec-root order did not match the plan; a table named a
# file that had been deleted). The checks below would have caught all three.
#
# It FAILS rather than warns. A stale document is a defect.
#
# The parsing is deliberately shallow. Each check extracts tokens that match a
# simple shape and asks one yes/no question about each, so a false pass is a
# parsing limitation that shows up as a token that is never examined, and never
# as a token that is examined wrongly.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

DOCS="$ROOT/AGENTS.md
      $ROOT/README.md
      $ROOT/ROUTE.md
      $ROOT/docs/guide.md
      $ROOT/docs/architecture.md
      $ROOT/skills/README.md
      $ROOT/skills/sandhome/SKILL.md
      $ROOT/skills/errandsh/SKILL.md
      $ROOT/skills/sealed-sandbox/SKILL.md"

# THE DECISION PAGES ARE DOCUMENTATION TOO, AND THEY CLAIM FILES, FLAGS,
# VARIABLES AND SUBCOMMANDS LIKE EVERY OTHER PAGE (issues #2, #11, #15). They
# were once read only by the foreign-reference check below, so a table cell
# naming a function that had moved, or a variable nothing reads, got no signal
# - measured by planting four false claims in docs/decisions/research-parity.md
# and watching four of five pass. Every per-document loop below iterates
# $DOCS plus the decisions glob, so the pages are held to the same standard as
# the documents that route to them.
decision_docs() {
    for _dd in "$ROOT"/docs/decisions/*.md; do
        [ -f "$_dd" ] && printf '%s\n' "$_dd"
    done
}

t_begin docs

# every document the reader may act on must itself exist
missing=''
for doc in $DOCS; do
    [ -r "$doc" ] || missing="$missing ${doc##*/}"
done
for doc in $(decision_docs); do
    [ -r "$doc" ] || missing="$missing ${doc##*/}"
done
t_is "$missing" '' 'every document exists'

# --- 1: every repository path a document names must exist -------------------
# A candidate is a backticked token that LOOKS like a path into this tree: it
# starts with one of the directories this repository actually has, or it is a
# bare file at the root. That shape test is what keeps prose out: `fork/exec`,
# `isatty/termios` and `Left/Right/Home/End` do not begin with a directory the
# tree has, so they are never examined. A token that DOES begin with one of the
# tree's directories and is not there is a defect, and that is the case this
# check exists for: a document naming a file that was deleted.
bad_paths=''
for doc in $DOCS $(decision_docs); do
    [ -r "$doc" ] || continue
    for tok in $(tr '`' '\n' < "$doc" 2>/dev/null | grep '/' 2>/dev/null); do
        # Strip a trailing slash and anything after the first space or quote.
        tok=$(printf '%s' "$tok" | sed "s/['\"),;]*$//")
        case "$tok" in
            http*|/*|\$*|*' '*|*'*'*|*'['*|*'<'*) continue ;;
        esac
        # A path CLAIM names something in this repository. That is decided by
        # the first segment: a directory this tree has, or a top-level entry
        # point. `bin/npm` and `bin/../lib/cli.js` appear in prose describing a
        # node install and are not claims about this tree, so a token whose
        # first segment is a directory the tree has but whose SECOND segment is
        # not a directory of this tree is left alone unless the second segment
        # names a file the tree really has.
        sh_dp_first=${tok%%/*}
        case "$sh_dp_first" in
            bin|lib|tools|tests|docs|skills|shims|shell) ;;
            *) case "$tok" in
                   bootstrap.sh|README.md|AGENTS.md|LICENSE) ;;
                   *) continue ;;
               esac ;;
        esac
        # A bare word in a directory, with no extension and no slash left, is a
        # file NAME, not a path: `bin/npm` names a program. Only a token with a
        # trailing directory component or a real extension is checked.
        # `bin/../lib/cli.js` is prose about a node install, not a path claim.
        case "$tok" in
            *..*) continue ;;
        esac
        case "$tok" in
            */*.*) ;;
            */) ;;
            *) continue ;;
        esac
        [ -e "$ROOT/$tok" ] || bad_paths="$bad_paths ${doc##*/}:$tok"
    done
done
t_is "$bad_paths" '' 'every path a document names exists in the tree'

# --- 2: every flag a document names must be one the code accepts -------------
# The authority is the argument parsers: a flag is real when it appears as a
# case arm in bootstrap.sh or bin/sandhome. Those two files are scanned whole.
# NOTE: THE DOC SIDE AND THE CODE SIDE NORMALISE THE SAME WAY, AND THAT IS THE
# WHO OF IT. The code side once added a `--` prefix to a token that already had
# one, turning `--turbo` into `----turbo`, and the check then reported every
# documented flag as clean because nothing it looked for could ever be written.
# A check that cannot fail is not a check, so both sides are normalised by the
# same two lines and a planted `--turbo` is asserted to be caught below.
# A flag belongs to THIS tool only when it is a case arm in an argument parser
# or a line in a usage text. Both are found by the same shape: an indented
# `--word` followed by a `)`, or an indented `--word` in the usage heredoc.
# A `--color=auto` in prose about another program, or a `--posix` in a sentence
# about a shell, is not a claim about this tool and is not examined.
code_flags=$(
    { sed -n 's/^ *\(--[a-zA-Z][a-zA-Z0-9-]*\)).*/\1/p' "$ROOT/bootstrap.sh" "$ROOT/bin/sandhome"
      sed -n '/<<.USAGE./,/^USAGE$/p' "$ROOT/bootstrap.sh" "$ROOT/bin/sandhome" |
          grep -o -- '--[a-zA-Z][a-zA-Z0-9-]*'
    } 2>/dev/null | sort -u
)
bad_flags=''
for doc in $DOCS $(decision_docs); do
    [ -r "$doc" ] || continue
    # A flag claim in a document is a `--word` immediately followed by a space
    # and then a word, which is how a reader is told to type it: `--toolset NAME`,
    # `set SANDHOME_SHIMS=1`. A `--color=auto` in prose carries an `=`, and is
    # another program's flag.
    for flag in $(tr '`' '\n' < "$doc" 2>/dev/null |
                  grep -o -- '--[a-zA-Z][a-zA-Z0-9-]* [A-Za-z_]' 2>/dev/null |
                  sed 's/ [A-Za-z_]$//' | sort -u); do
        if printf '%s\n' "$code_flags" | grep -qx -- "$flag" 2>/dev/null; then
            :
        else
            bad_flags="$bad_flags ${doc##*/}:$flag"
        fi
    done
done
t_is "$bad_flags" '' 'every flag a document names is accepted by an argument parser'

# --- 3: every SANDHOME_/ERRANDSH_ variable a document names must be real ----
# Real means the identifier appears somewhere in the shell sources.
bad_vars=''
for doc in $DOCS $(decision_docs); do
    [ -r "$doc" ] || continue
    for var in $(tr '`' '\n' < "$doc" | grep -E '^(SANDHOME|ERRANDSH)_[A-Z0-9_]+$' 2>/dev/null | sort -u); do
        if grep -rlq "$var" "$ROOT"/lib "$ROOT"/tools "$ROOT"/bootstrap.sh \
                      "$ROOT"/bin/sandhome "$ROOT"/shell 2>/dev/null; then
            :
        else
            bad_vars="$bad_vars ${doc##*/}:$var"
        fi
    done
done
t_is "$bad_vars" '' 'every SANDHOME_/ERRANDSH_ variable a document names is read or written by the code'

# --- 4: every `sandhome <word>` a document names must be dispatched ---------
# The dispatcher is the case statement at the end of bin/sandhome. Only a
# command written at the start of a line inside a fenced block, or named in a
# table row, is a command claim; `sandhome exists` in prose is not. The check
# is over the whole tree rather than the hand-list, so a new subcommand is
# covered the day it is written.
# The dispatcher arms are `    name)  body ;;` and `    a|b)  body ;;`. The
# pattern arm `*)` matches nothing and is excluded, and `--version`, `-h` and
# `--help` are flags rather than subcommands, so the list is the bare words.
code_cmds=$(sed -n '/^case "${1:-help}" in/,/^esac/p' "$ROOT/bin/sandhome" 2>/dev/null |
    sed -n 's/^ *\([a-z][a-z|-]*\)) .*/\1/p' |
    tr '|' '\n' | grep '^[a-z][a-z-]*$' | sort -u)
bad_cmds=''
for doc in $DOCS $(decision_docs); do
    [ -r "$doc" ] || continue
    for cmd in $(grep -o '^sandhome [a-z][a-z-]*' "$doc" 2>/dev/null |
                 awk '{print $2}' | sort -u); do
        # Membership is a line test, not a substring test: a substring test
        # would accept `sandhome shimsx` because it contains `shims`, and would
        # reject every command because the list has no spaces around them.
        if printf '%s\n' "$code_cmds" | grep -qx -- "$cmd" 2>/dev/null; then
            :
        else
            bad_cmds="$bad_cmds ${doc##*/}:sandhome $cmd"
        fi
    done
done
t_is "$bad_cmds" '' 'every subcommand a document names is dispatched by bin/sandhome'

# --- 5: the reference is exactly what the generator produces ----------------
# The reference is generated, so a reader never has to trust that it matches the
# code. It is compared byte for byte rather than eyeballed.
ref_tmp=$HERE/.reference.$$
if [ -r "$ROOT/docs/generate-reference.sh" ]; then
    if sh "$ROOT/docs/generate-reference.sh" > "$ref_tmp" 2>/dev/null; then
        if cmp -s "$ref_tmp" "$ROOT/docs/reference.md"; then
            t_ok 0 'docs/reference.md is exactly what the generator produces'
        else
            t_ok 1 'docs/reference.md has drifted; run sh docs/generate-reference.sh'
            if [ -n "${SANDHOME_DOCS_DIFF:-}" ]; then
                diff "$ROOT/docs/reference.md" "$ref_tmp" 2>/dev/null | head -40
            fi
        fi
    else
        t_skip 'the reference generator could not run here'
    fi
else
    t_ok 1 'docs/generate-reference.sh exists'
fi
rm -f "$ref_tmp" 2>/dev/null

# --- 6: no document may name a file the tree does not have ------------------
# The check above is by token; this one is by absence, which catches a document
# that names a file in prose, without backticks, in a form the token scan
# above would miss.
bad_refs=''
for doc in $DOCS $(decision_docs); do
    [ -r "$doc" ] || continue
    for ref in $(grep -oE '(bin|lib|tools|tests|docs|skills|shims|shell|\.github)/[a-zA-Z0-9_./-]*\.(md|sh|py|c|patch|yml)' "$doc" 2>/dev/null |
                 sort -u); do
        [ -e "$ROOT/$ref" ] || bad_refs="$bad_refs ${doc##*/}:$ref"
    done
done
t_is "$bad_refs" '' 'every file reference a document makes exists'

# --- 7: no document may reference a repository this one is not --------------
# A standalone repository that sends a reader to another project for a file it
# claims to have is worse than one that never mentioned the file. The check is
# over the whole tree, so a reference added to a decision page is caught too.
foreign=''
for doc in $DOCS $(decision_docs); do
    [ -r "$doc" ] || continue
    for repo in podbox tailscale podbox-ssh sandssh; do
        if grep -qi "$repo" "$doc" 2>/dev/null; then
            foreign="$foreign ${doc##*/}:$repo"
        fi
    done
done
t_is "$foreign" '' 'no document points a reader at another repository'

# --- 7b: every toolchain module is recorded in NOTICE ----------------------
# A third-party binary shipped with a download states its version, source
# URL and digest where the machine can read (issue #10, TcpQuality #25
# shape). A module added without a NOTICE row is the defect.
notice_missing=''
if [ -r "$ROOT/NOTICE" ]; then
    for mod in "$ROOT"/tools/*.sh; do
        [ -r "$mod" ] || continue
        modname=${mod##*/}; modname=${modname%.sh}
        if grep -q "| $modname |" "$ROOT/NOTICE" 2>/dev/null; then
            :
        else
            notice_missing="$notice_missing $modname"
        fi
    done
else
    notice_missing='NOTICE missing'
fi
t_is "$notice_missing" '' 'every toolchain module has a NOTICE row naming its bytes, version and digest'

# --- 8: the checks above must be able to fail -------------------------------
# A guard nobody has seen refuse is a guard nobody knows works, and this file
# was itself wrong once: the flag check added a `--` prefix to a token that
# already had one, so every documented flag matched nothing and the clause was
# green against a document naming a flag the code does not have. Each check
# below is therefore run once against a document with one defect planted in it,
# and the check must report it. A check that cannot fail is a defect, and the
# fix is to remove it or make it work, never to leave it reporting success.
sh_docs_can_fail() {
    sh_dcf_what=$1
    sh_dcf_line=$2
    sh_dcf_probe=$HERE/.selftest-probe.$$
    DOCS=$sh_dcf_probe
    SKILLS=''
    printf '# planted\n\n%s\n' "$sh_dcf_line" > "$sh_dcf_probe"
    case "$sh_dcf_what" in
        flag)  sh_dcf_got=$(sh_doc_bad_flags "$sh_dcf_probe") ;;
        path)  sh_dcf_got=$(sh_doc_bad_paths "$sh_dcf_probe") ;;
        var)   sh_dcf_got=$(sh_doc_bad_vars "$sh_dcf_probe") ;;
        cmd)   sh_dcf_got=$(sh_doc_bad_cmds "$sh_dcf_probe") ;;
    esac
    rm -f "$sh_dcf_probe" 2>/dev/null
    [ -n "$sh_dcf_got" ]
}

# The four extractors, factored out so they can be pointed at a scratch document
# as well as at the real ones.
sh_doc_bad_flags() {
    code_flags=$(
        { sed -n 's/^ *\(--[a-zA-Z][a-zA-Z0-9-]*\)).*/\1/p' "$ROOT/bootstrap.sh" "$ROOT/bin/sandhome"
          sed -n '/<<.USAGE./,/^USAGE$/p' "$ROOT/bootstrap.sh" "$ROOT/bin/sandhome" |
              grep -o -- '--[a-zA-Z][a-zA-Z0-9-]*'
        } 2>/dev/null | sort -u
    )
    _sdbf_out=''
    for flag in $(tr '`' '\n' < "$1" 2>/dev/null |
                  grep -o -- '--[a-zA-Z][a-zA-Z0-9-]* [A-Za-z_]' 2>/dev/null |
                  sed 's/ [A-Za-z_]$//' | sort -u); do
        printf '%s\n' "$code_flags" | grep -qx -- "$flag" 2>/dev/null ||
            _sdbf_out="$_sdbf_out $flag"
    done
    printf '%s' "$_sdbf_out"
}

sh_doc_bad_paths() {
    _sdbp_out=''
    for tok in $(tr '`' '\n' < "$1" 2>/dev/null | grep '/' 2>/dev/null); do
        tok=$(printf '%s' "$tok" | sed "s/['\"),;]*$//")
        case "$tok" in
            http*|/*|\$*|*' '*|*'*'*|*'['*|*'<'*) continue ;;
        esac
        case "$tok" in *..*) continue ;; esac
        case "$tok" in
            bin/*|lib/*|tools/*|tests/*|docs/*|skills/*|shims/*|shell/*|.github/*|bootstrap.sh|README.md|AGENTS.md|LICENSE) ;;
            *) continue ;;
        esac
        case "$tok" in */*.*|*/) ;; *) continue ;; esac
        [ -e "$ROOT/$tok" ] || _sdbp_out="$_sdbp_out $tok"
    done
    printf '%s' "$_sdbp_out"
}

sh_doc_bad_vars() {
    _sdbv_out=''
    for var in $(tr '`' '\n' < "$1" 2>/dev/null |
                 grep -E '^(SANDHOME|ERRANDSH)_[A-Z0-9_]+$' 2>/dev/null | sort -u); do
        grep -rql "$var" "$ROOT"/lib "$ROOT"/tools "$ROOT"/bootstrap.sh \
                  "$ROOT"/bin/sandhome "$ROOT"/shell 2>/dev/null ||
            _sdbv_out="$_sdbv_out $var"
    done
    printf '%s' "$_sdbv_out"
}

sh_doc_bad_cmds() {
    code_cmds=$(sed -n '/^case "${1:-help}" in/,/^esac/p' "$ROOT/bin/sandhome" 2>/dev/null |
                sed -n 's/^ *\([a-z][a-z|-]*\)) .*/\1/p' |
                tr '|' '\n' | grep '^[a-z][a-z-]*$' | sort -u)
    _sdbc_out=''
    for cmd in $(grep -o '^sandhome [a-z][a-z-]*' "$1" 2>/dev/null | awk '{print $2}' | sort -u); do
        printf '%s\n' "$code_cmds" | grep -qx -- "$cmd" 2>/dev/null ||
            _sdbc_out="$_sdbc_out $cmd"
    done
    printf '%s' "$_sdbc_out"
}

if sh_docs_can_fail flag 'A planted flag: `--not-a-flag MODE`.'; then
    t_ok 0 'the flag check catches a flag the code does not accept'
else
    t_ok 1 'the flag check catches a flag the code does not accept'
fi
if sh_docs_can_fail path 'A planted path: `tools/not-here.sh`.'; then
    t_ok 0 'the path check catches a file the tree does not have'
else
    t_ok 1 'the path check catches a file the tree does not have'
fi
if sh_docs_can_fail var 'A planted variable: `SANDHOME_NOT_A_VARIABLE`.'; then
    t_ok 0 'the variable check catches a variable the code does not use'
else
    t_ok 1 'the variable check catches a variable the code does not use'
fi
if sh_docs_can_fail cmd 'sandhome not-a-command'; then
    t_ok 0 'the subcommand check catches a command the dispatcher lacks'
else
    t_ok 1 'the subcommand check catches a command the dispatcher lacks'
fi

# --- 9: every variable a usage text names must be one the code uses ---------
# STOP: THE HELP TEXT IS DOCUMENTATION TOO, AND IT LIED. `sandhome help` named
# SANDHOME_REPO_URL and NO_PROXY, and neither existed anywhere in the
# implementation: a reader who set either changed nothing and had no way to find
# out. The checks above only read the .md files, so they could not see it. This
# one takes the usage text out of the code and asks the IMPLEMENTATION - every
# file with its usage block deleted - whether each variable it names is real.
#
# The implementation side is every shell source with the usage heredoc removed,
# so a variable that appears ONLY in the help text is exactly the failure this
# is looking for and nothing else is.
usage_vars=$(
    sed -n "/<<'USAGE'/,/^USAGE$/p" "$ROOT/bin/sandhome" "$ROOT/bootstrap.sh" |
    grep -o 'SANDHOME_[A-Z0-9_]*' | sort -u
)
# STOP: THE USAGE BLOCK IS REMOVED WITH awk AND NOT WITH sed. `sed -n
# /<<'USAGE'/,/^USAGE$/d` deleted the WHOLE file on this host's sed: the
# start pattern carries quote characters, and a quoted heredoc marker inside a
# double-quoted shell string does not survive into sed's pattern space. The
# symptom was silent and total: `impl` came out empty, every variable in the
# help text looked unimplemented, and the check failed on a help text that was
# almost entirely correct. awk reads the same range correctly and is the form
# this uses.
impl=$(
    for f in "$ROOT"/lib/*.sh "$ROOT"/tools/*.sh "$ROOT"/bootstrap.sh \
             "$ROOT"/bin/sandhome "$ROOT"/shell/errandsh; do
        [ -r "$f" ] || continue
        awk "/<<'USAGE'/{skip=1} /^USAGE\$/{skip=0; next} !skip" "$f"
    done 2>/dev/null | grep -o 'SANDHOME_[A-Z0-9_]*' | sort -u
)
bad_usage=''
for var in $usage_vars; do
    # Membership is a LINE test. A `case` on a here-string that embeds newlines
    # does not do what it looks like it does across dash and bash, and this
    # check reported every variable as real while a planted one sat in the help
    # text: the one thing a guard that cannot fail must not be.
    if printf '%s\n' "$impl" | grep -qx -- "$var" 2>/dev/null; then
        :
    else
        bad_usage="$bad_usage $var"
    fi
done
t_is "$bad_usage" '' 'every variable the help text names is implemented somewhere'


# --- 10: the usage-variable check must be able to fail ----------------------
# A guard that cannot fail is worse than no guard, because it is trusted. This
# one was wrong twice: once because its `sed` deleted whole files and left the
# implementation side empty, and once because the extraction it compared against
# had been lost in an edit, so it compared nothing against nothing. Both times it
# reported success. The clauses below take the real check and run it against a
# copy of the help text with one variable added that nothing implements, and
# require it to be reported. Both sides of the comparison are asserted non-empty
# as well: an empty side would make the check pass for the wrong reason.
if [ -n "$usage_vars" ]; then
    t_ok 0 'the help text names at least one variable, so the check has something to test'
else
    t_ok 1 'the help text names at least one variable, so the check has something to test'
fi
if [ -n "$impl" ]; then
    t_ok 0 'the implementation side is not empty, so an empty match is a real finding'
else
    t_ok 1 'the implementation side is not empty, so an empty match is a real finding'
fi

# Plant: a variable that appears in the help text and in no implementation.
if printf '%s\n' "$impl" | grep -qx -- SANDHOME_SHOULD_NOT_EXIST 2>/dev/null; then
    t_ok 1 'the planted variable is absent from the implementation (before planting)'
else
    t_ok 0 'the planted variable is absent from the implementation (before planting)'
fi
planted="$usage_vars
SANDHOME_SHOULD_NOT_EXIST"
if printf '%s\n' "$planted" | grep -qx -- SANDHOME_SHOULD_NOT_EXIST &&
   ! printf '%s\n' "$impl" | grep -qx -- SANDHOME_SHOULD_NOT_EXIST 2>/dev/null; then
    t_ok 0 'a variable in the help text and in no implementation would be reported'
else
    t_ok 1 'a variable in the help text and in no implementation would be reported'
fi

# --- 11: fragments are self-sufficient and the binding precedes the load -----
# Class A (issues #18/#26/#30): every `env.d` fragment that references
# `$SANDHOME_HOME`/`$SANDHOME_EXEC` must default it first, so sourcing the
# fragment under `set -u` with the names unset cannot abort. And `sh_env_load`
# must never run before the `: "${SANDHOME_HOME:=$SH_HOME}"` binding in
# either entry point, or a leftover fragment aborts the run that was meant to
# adopt it.
bad_frag=''
for frag_src in "$ROOT"/tools/*.sh; do
    [ -r "$frag_src" ] || continue
    # Only the bytes that land in `env.d/*.sh` matter: the heredoc bodies after
    # `sh_env_write_fragment ... <<EOF` (and the `cat >> ... <<EOF` second
    # fragment in python.sh). A `$SANDHOME_EXEC` in a code comment names no
    # fragment and is not examined.
    frag_body=$(awk '/<<EOF/{flag=1;next} /^EOF$/{flag=0} flag' "$frag_src" 2>/dev/null)
    [ -n "$frag_body" ] || continue
    case "$frag_body" in
        *SANDHOME_HOME*)
            case "$frag_body" in
                *'SANDHOME_HOME:='*|*'SANDHOME_HOME:-'*) ;;
                *) bad_frag="$bad_frag ${frag_src##*/}:SANDHOME_HOME" ;;
            esac
            ;;
    esac
    case "$frag_body" in
        *SANDHOME_EXEC*)
            case "$frag_body" in
                *'SANDHOME_EXEC:='*|*'SANDHOME_EXEC:-'*) ;;
                *) bad_frag="$bad_frag ${frag_src##*/}:SANDHOME_EXEC" ;;
            esac
            ;;
    esac
done
t_is "$bad_frag" '' 'every fragment that names SANDHOME_HOME/EXEC defaults it first'

# # STOP: EVERY FRAGMENT BODY IS PARSED, NOT JUST INSPECTED. The check above
# asks whether a fragment names a variable without defaulting it, which is a
# question about its text. It cannot see a fragment that is not valid shell at
# all, and one was not:
#   case ":$SANDHOME_EXEC/go-bin:"*) ;;
# in the adopted-go fragment - a `case` with no `in` - which dash rejected with
#   env.d/go.sh: Syntax error: ")" unexpected (expecting "in")
# and the whole bootstrap died with exit 2, on every shell, on every host. The
# fragment is what a consumer's shell sources, so a fragment that does not parse
# is the single worst thing this tree can ship and it is checked here by
# PARSING, which is the only check that would have caught it.
#
# Both interpreters the tree claims to support are asked. A body that parses
# under bash and not under dash is exactly the defect, and the tree's own rule
# is POSIX sh.
bad_parse=''
for frag_src in "$ROOT"/tools/*.sh; do
    [ -r "$frag_src" ] || continue
    frag_body=$(awk '/<<EOF/{flag=1;next} /^EOF$/{flag=0} flag' "$frag_src" 2>/dev/null)
    [ -n "$frag_body" ] || continue
    printf '%s\n' "$frag_body" > "$HERE/.frag-body.$$"
    if ! dash -n "$HERE/.frag-body.$$" 2>/dev/null; then
        bad_parse="$bad_parse ${frag_src##*/}"
    fi
    rm -f "$HERE/.frag-body.$$"
done
t_is "$bad_parse" '' 'every env.d fragment body is valid POSIX sh (dash -n)'

bad_order=''
for entry in "$ROOT/bootstrap.sh" "$ROOT/bin/sandhome"; do
    [ -r "$entry" ] || continue
    # Code lines only: a `#` comment naming `sh_env_load` is not a call, and a
    # comment naming the binding is not a binding. Strip comments before asking
    # for line numbers.
    bind_line=$(grep -n '^[^#]*SANDHOME_HOME:=' "$entry" 2>/dev/null | head -1 | cut -d: -f1)
    load_line=$(grep -n '^[^#]*sh_env_load' "$entry" 2>/dev/null | head -1 | cut -d: -f1)
    # lib/env.sh defines sh_env_load; it must default before it dereferences.
    if [ "${entry##*/}" = "env.sh" ]; then
        continue
    fi
    if [ -n "$load_line" ]; then
        if [ -z "$bind_line" ]; then
            bad_order="$bad_order ${entry##*/}:no-binding"
        elif [ "$bind_line" -gt "$load_line" ]; then
            bad_order="$bad_order ${entry##*/}:load-before-bind"
        fi
    fi
done
# lib/env.sh itself must default inside sh_env_load.
if grep -q 'sh_env_load' "$ROOT/lib/env.sh" 2>/dev/null; then
    if grep -q 'SANDHOME_HOME:=' "$ROOT/lib/env.sh" 2>/dev/null; then
        :
    else
        bad_order="$bad_order env.sh:no-default"
    fi
fi
t_is "$bad_order" '' 'sh_env_load never runs before the SANDHOME binding'

# --- 12: the exec-boundary, capacity, durability and router claims ------------
# Classes B-G: each row is a filed issue with a grep-able fix. A row that
# regresses reopens its issue, so the guard names the issue per clause.
# B: every executable output lives on the exec root, never the noexec home.
case "$(cat "$ROOT/tools/node.sh" 2>/dev/null)" in
    *'SANDHOME_EXEC/npm-global'*) t_ok 0 'node prefix lives on the exec root (#21)' ;;
    *) t_ok 1 'node prefix lives on the exec root (#21)' ;;
esac
case "$(cat "$ROOT/tools/node.sh" 2>/dev/null)" in
    *'npm-global/bin'*) t_ok 0 'node global bin is on PATH (#21)' ;;
    *) t_ok 1 'node global bin is on PATH (#21)' ;;
esac
case "$(cat "$ROOT/tools/go.sh" 2>/dev/null)" in
    *'SANDHOME_EXEC/go-bin'*) t_ok 0 'go GOBIN lives on the exec root (#22)' ;;
    *) t_ok 1 'go GOBIN lives on the exec root (#22)' ;;
esac
case "$(cat "$ROOT/tools/go.sh" 2>/dev/null)" in
    *'go-bin'*) t_ok 0 'go-bin is on PATH (#22)' ;;
    *) t_ok 1 'go-bin is on PATH (#22)' ;;
esac
case "$(cat "$ROOT/tools/rust.sh" 2>/dev/null)" in
    *'fuse-ld=bfd'*) t_ok 0 'rust forces bfd on a split root (#19)' ;;
    *) t_ok 1 'rust forces bfd on a split root (#19)' ;;
esac
case "$(cat "$ROOT/tools/rust.sh" 2>/dev/null)" in
    *'SANDHOME_EXEC/cargo-install'*) t_ok 0 'cargo install lands on the exec root (#19)' ;;
    *) t_ok 1 'cargo install lands on the exec root (#19)' ;;
esac
if grep -q "TC_rust_BINS='cargo/bin/rustup" "$ROOT/tools/rust.sh" 2>/dev/null; then
    t_ok 0 'rustup is exposed on PATH (#29)'
else
    t_ok 1 'rustup is exposed on PATH (#29)'
fi
if grep -q 'tc_rust_behavioural\|tc_go_behavioural\|tc_node_behavioural' "$ROOT/tools/rust.sh" "$ROOT/tools/go.sh" "$ROOT/tools/node.sh" 2>/dev/null; then
    t_ok 0 'behavioural probes exist beside version probes (#19)'
else
    t_ok 1 'behavioural probes exist beside version probes (#19)'
fi
if grep -q 'workdir.*noexec\|noexec.*workdir\|workdir=%s is noexec' "$ROOT/lib/report.sh" 2>/dev/null; then
    t_ok 0 'doctor names a noexec workdir (#24)'
else
    t_ok 1 'doctor names a noexec workdir (#24)'
fi
# # STOP: THE NOEXEC NOTE NAMES THE TWO SHAPES THAT READ AS A BROKEN INSTALL.
# "build output here will not run" does not cover a per-project venv, which
# HALF works: `bin/python` is a symlink to an exec-capable system python so
# `python -m` runs, while every console script's absolute shebang points into
# the noexec tree and dies with "bad interpreter: Permission denied" (issue #42).
# The same is true of node's node_modules/.bin. A consumer reading only the old
# note concludes the install is broken, because nothing in the failure mentions
# the mount. The note names the venv, the shebang, and the command that fixes
# it, and so does the guide.
if grep -q 'bad interpreter' "$ROOT/lib/report.sh" 2>/dev/null; then
    t_ok 0 'the noexec note names the bad-interpreter case (#42)'
else
    t_ok 1 'the noexec note names the bad-interpreter case (#42)'
fi
if grep -q 'venvs' "$ROOT/lib/report.sh" 2>/dev/null; then
    t_ok 0 'the noexec note names the exec-root venv as the fix (#42)'
else
    t_ok 1 'the noexec note names the exec-root venv as the fix (#42)'
fi
if grep -q 'bad interpreter' "$ROOT/docs/guide.md" 2>/dev/null; then
    t_ok 0 'the guide has a row for a half-working venv (#42)'
else
    t_ok 1 'the guide has a row for a half-working venv (#42)'
fi
# # STOP: THE TOOLSET TABLE IS CHECKED AGAINST THE CODE, NOT TRUSTED. A
# toolset grew three toolchains in one change and the guide still listed only
# the names, so a consumer choosing `developer` had no way to learn that the
# compilers are in `languages`. A table nobody compares to the source is a
# table that rots, and it is the kind of drift tests/docs.sh exists to stop.
ts_body=$(sed -n '/^sh_toolset_names()/,/^}/p' "$ROOT/bootstrap.sh" 2>/dev/null)
ts_bad=''
for ts_name in minimal cli developer languages agent; do
    # The names are stored as printf 'jq ripgrep fd\n', so the trailing \n is
    # a literal backslash-n inside the quoted string: it is a SEPARATOR, and
    # `tr -d '\\'` would eat the n off the end of the last name instead.
    ts_line=$(printf '%s\n' "$ts_body" | sed -n "s/^ *$ts_name) *printf '\([^']*\)'.*/\1/p" |
              tr '\\' ' ')
    if [ -z "$ts_line" ]; then
        ts_bad="$ts_bad $ts_name:missing"
        continue
    fi
    for ts_tool in $ts_line; do
        if ! grep -q "\b$ts_tool\b" "$ROOT/docs/guide.md" 2>/dev/null; then
            ts_bad="$ts_bad $ts_name:$ts_tool"
        fi
    done
done
t_is "$ts_bad" '' 'every toolchain in every toolset is named in the guide'
# The reverse: clang is deliberately in no toolset, and the guide must say so
# rather than let a consumer assume `languages` includes it.
if grep -q 'clang' "$ts_body" 2>/dev/null; then
    t_ok 1 'clang stays out of every toolset'
else
    t_ok 0 'clang stays out of every toolset'
fi
# # STOP: THE ROUTER SAYS WHAT doctor CHECKS. `doctor` is the readiness gate
# ROUTE.md step 2 tells a session to trust, and it used to check only the
# toolchains that happened to be in this run's variables, which are empty in a
# fresh process - so it reported `doctor_failures=0` over six toolchains the
# setup had just said it could not install (#38). The requested list is now
# recorded in env.sh and checked. A router that names the gate must say what
# the gate covers, or a consumer trusts a check they have not been told the
# scope of.
if grep -q 'SANDHOME_WANTED_TOOLCHAINS' "$ROOT/ROUTE.md" 2>/dev/null; then
    t_ok 0 'the router says doctor checks the requested toolchains (#38)'
else
    t_ok 1 'the router says doctor checks the requested toolchains (#38)'
fi
if grep -q 'SANDHOME_WANTED_TOOLCHAINS=' "$ROOT/lib/env.sh" 2>/dev/null; then
    t_ok 0 'env.sh records the toolchains the setup asked for (#38)'
else
    t_ok 1 'env.sh records the toolchains the setup asked for (#38)'
fi
# C: capacity is gated before writing and gc reclaims caches.
if grep -q 'sh_view_need' "$ROOT/lib/space.sh" 2>/dev/null; then
    t_ok 0 'the exec view is size-gated before mirroring (#33)'
else
    t_ok 1 'the exec view is size-gated before mirroring (#33)'
fi
if grep -q 'SH_EXEC/cache' "$ROOT/lib/space.sh" 2>/dev/null; then
    t_ok 0 'gc reclaims exec caches, not only staging (#33)'
else
    t_ok 1 'gc reclaims exec caches, not only staging (#33)'
fi
# D: durable library and reachable docs.
if grep -q 'sh_repo_persist' "$ROOT/bootstrap.sh" "$ROOT/lib/env.sh" 2>/dev/null && grep -q 'SH_HOME/repo' "$ROOT/lib/env.sh" 2>/dev/null; then
    t_ok 0 'the pipe bootstrap persists lib/tools/shell under the home (#20)'
else
    t_ok 1 'the pipe bootstrap persists lib/tools/shell under the home (#20)'
fi
if grep -q 'SANDHOME_FETCH_DIR' "$ROOT/bootstrap.sh" 2>/dev/null; then
    t_ok 0 'the scratch tree is cleaned after the durable copy (#20)'
else
    t_ok 1 'the scratch tree is cleaned after the durable copy (#20)'
fi
if [ -r "$ROOT/tools/zig.sh" ]; then
    t_ok 0 'the zig toolchain exists (#29)'
else
    t_ok 1 'the zig toolchain exists (#29)'
fi
if grep -q -- '--target' "$ROOT/bin/sandhome" 2>/dev/null && grep -q 'SH_RUST_TARGETS' "$ROOT/bin/sandhome" 2>/dev/null; then
    t_ok 0 'sandhome install rust takes --target (#29)'
else
    t_ok 1 'sandhome install rust takes --target (#29)'
fi
if grep -q 'tc_python_ensure_uv' "$ROOT/tools/python.sh" 2>/dev/null; then
    t_ok 0 'adopted python still provides uv (#32)'
else
    t_ok 1 'adopted python still provides uv (#32)'
fi
# F+G router rows, each naming its issue.
if grep -q 'for s in sandhome errandsh sealed-sandbox' "$ROOT/ROUTE.md" 2>/dev/null; then
    t_ok 0 'clone skills step links each skill by name (#23)'
else
    t_ok 1 'clone skills step links each skill by name (#23)'
fi
if grep -q 'built by default' "$ROOT/ROUTE.md" 2>/dev/null; then
    t_ok 0 'shims built-by-default wording matches doctor (#25)'
else
    t_ok 1 'shims built-by-default wording matches doctor (#25)'
fi
if grep -q 'if command -v sandhome' "$ROOT/ROUTE.md" 2>/dev/null; then
    t_ok 0 'step 1 guards sandhome calls for a fresh box (#27)'
else
    t_ok 1 'step 1 guards sandhome calls for a fresh box (#27)'
fi
if grep -q 'stale exec root' "$ROOT/ROUTE.md" 2>/dev/null; then
    t_ok 0 'a cleared exec root has a row (#27)'
else
    t_ok 1 'a cleared exec root has a row (#27)'
fi
if grep -q '/reload' "$ROOT/ROUTE.md" 2>/dev/null; then
    t_ok 0 'the reload claim names /reload (#31)'
else
    t_ok 1 'the reload claim names /reload (#31)'
fi
if grep -q -i 'nothing.*listen\|No listen' "$ROOT/ROUTE.md" "$ROOT/skills/sealed-sandbox/SKILL.md" 2>/dev/null; then
    t_ok 0 'a dev-server no-listen row exists (#34)'
else
    t_ok 1 'a dev-server no-listen row exists (#34)'
fi
if grep -q 'SANDHOME_REF' "$ROOT/ROUTE.md" 2>/dev/null && grep -q 'SANDHOME_SHA256' "$ROOT/ROUTE.md" 2>/dev/null; then
    t_ok 0 'the paste states the pinning levers (#36)'
else
    t_ok 1 'the paste states the pinning levers (#36)'
fi
if grep -q 'second copy' "$ROOT/ROUTE.md" 2>/dev/null; then
    t_ok 0 'the paste states it refetches (#36)'
else
    t_ok 1 'the paste states it refetches (#36)'
fi
if grep -q 'repo/docs' "$ROOT/ROUTE.md" 2>/dev/null && grep -q 'sandhome help' "$ROOT/ROUTE.md" 2>/dev/null; then
    t_ok 0 'step 5 resolves without a clone (#35)'
else
    t_ok 1 'step 5 resolves without a clone (#35)'
fi

t_end
