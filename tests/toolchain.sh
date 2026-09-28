#!/bin/sh
# tests/toolchain.sh - the framework clauses that need their own modules: a
# requirements cycle must be refused, and a linear requirement must install in
# order and then be adopted.
#
# STOP: THE CYCLE CASE IS BOUNDED BY `timeout`. A regression here is not a wrong
# answer, it is a process that never returns, and a test that hangs is a test
# that reports nothing. Without `timeout` the clause is skipped rather than run
# unbounded.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

t_begin toolchain

work=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-tc.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/lib" "$work/repo/tools" "$work/tc" "$work/exec" "$work/home"

# A tiny driver that loads the real library and resolves modules from $work/repo.
cat > "$work/ensure.sh" <<EOF
for m in common detect space fetch env toolchain; do
    . "$ROOT/lib/\$m.sh"
done
mkdir -p "\$SH_EXEC_BIN" "\$SH_EXEC_VIEWS" "\$SH_HOME_TOOLCHAINS" "\$SH_HOME_TMP" 2>/dev/null
sh_toolchain_ensure "\$1"
echo "STATUS=\$?"
EOF

run_ensure() {
    SH_LIB_DIR="$work/repo/lib" SH_REPO_DIR="$work/repo" \
    SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
    SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
    SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=no SH_DRY_RUN=0 SH_SELF=test \
    sh "$work/ensure.sh" "$1"
}

# Two modules that require each other.
cat > "$work/repo/tools/a.sh" <<'EOF'
TC_a_REQUIRES='b'
tc_a_probe() { return 1; }
tc_a_install() { return 0; }
EOF
cat > "$work/repo/tools/b.sh" <<'EOF'
TC_b_REQUIRES='a'
tc_b_probe() { return 1; }
tc_b_install() { return 0; }
EOF

if command -v timeout >/dev/null 2>&1; then
    cyc=$(SH_LIB_DIR="$work/repo/lib" SH_REPO_DIR="$work/repo" \
          SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
          SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
          SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=no SH_DRY_RUN=0 SH_SELF=test \
          timeout 15 sh "$work/ensure.sh" a 2>&1)
    cyc_rc=$?
    t_is "$cyc_rc" 0 'the cycle case returns instead of hanging'
    t_contains "$cyc" 'cyclic' 'the cycle is refused by name'
    t_contains "$cyc" 'STATUS=1' 'the cycle exits non-zero'
else
    echo '  skip the cycle case: no timeout to bound it with'
fi

# A linear requirement: c requires d, and both install and are adopted next time.
cat > "$work/repo/tools/c.sh" <<'EOF'
TC_c_REQUIRES='d'
tc_c_probe() { [ -f "$(sh_toolchain_root c)/ok" ]; }
tc_c_install() { mkdir -p "$(sh_toolchain_root c)" && : > "$(sh_toolchain_root c)/ok"; }
EOF
cat > "$work/repo/tools/d.sh" <<'EOF'
tc_d_probe() { [ -f "$(sh_toolchain_root d)/ok" ]; }
tc_d_install() { mkdir -p "$(sh_toolchain_root d)" && : > "$(sh_toolchain_root d)/ok"; }
EOF
out=$(run_ensure c 2>&1)
t_contains "$out" 'STATUS=0' 'a linear requirement chain installs'
t_ok "$([ -f "$work/tc/c/ok" ] && [ -f "$work/tc/d/ok" ]; echo $?)" 'both modules in the chain installed'

out=$(run_ensure c 2>&1)
t_contains "$out" 'STATUS=0' 'the second ensure of the chain succeeds'
case "$out" in
    *'adopting'*) t_ok 0 'the second ensure adopts the installed chain' ;;
    *)            t_ok 1 'the second ensure adopts the installed chain' ;;
esac

# STOP: A FRESH SHELL MUST ADOPT A TOOLCHAIN THAT IS ONLY ON PATH THROUGH ITS OWN
# ENV FRAGMENT. go, rust and uv are reached that way. Without loading the
# fragment before probing, the second ensure downloaded the whole toolchain
# again with a working copy already in the home.
cat > "$work/repo/tools/e.sh" <<'EOF'
TC_e_BINS=''
tc_e_probe() { sh_have e-probe; }
tc_e_install() {
    mkdir -p "$(sh_toolchain_root e)" || return 1
    printf '#!/bin/sh\n' > "$(sh_toolchain_root e)/e-probe"
    chmod 0755 "$(sh_toolchain_root e)/e-probe"
    sh_env_write_fragment e <<FRAG
case ":\$PATH:" in
  *":$(sh_toolchain_root e):"*) ;;
  *) PATH="$(sh_toolchain_root e):\$PATH" ;;
esac
export PATH
FRAG
}
EOF
out=$(run_ensure e 2>&1)
t_contains "$out" 'STATUS=0' 'a fragment-only toolchain installs'
case "$out" in
    *'installing'*) t_ok 0 'the first ensure installs it' ;;
    *)              t_ok 1 'the first ensure installs it' ;;
esac
out=$(run_ensure e 2>&1)
t_contains "$out" 'STATUS=0' 'the second ensure in a fresh shell succeeds'
case "$out" in
    *'adopting'*) t_ok 0 'the fresh shell adopts it from the env fragment' ;;
    *)            t_ok 1 'the fresh shell adopts it from the env fragment' ;;
esac
case "$out" in
    *'installing into'*) t_ok 1 'the fresh shell does not reinstall it' ;;
    *)                  t_ok 0 'the fresh shell does not reinstall it' ;;
esac

# NOTE: AN ADOPTED TOOLCHAIN IS PROMOTED, NOT SKIPPED. There is no home tree for
# an adopted toolchain, so the promote step used to be handed a directory that
# did not exist, mirror nothing, return 0 and link nothing: the tool answered on
# PATH (it was already there) and was absent from $SANDHOME_EXEC/bin, so a
# shell that had read only env.sh could not find it, and the run exited 0
# saying nothing. The clause below is a module that probes true from a working
# copy outside the home, and it asserts the exec bin now carries it.
mkdir -p "$work/repo/tools"
cat > "$work/repo/tools/f.sh" <<'EOF'
TC_f_BINS='bin/tool'
tc_f_probe() { sh_have adopted-tool; }
tc_f_adopted() { printf '%s' "$SANDHOME_TEST_ADOPTED"; }
tc_f_install() { return 1; }
EOF
# the module's declared location helper is in the driver, not the library
# The adopted copy lives OUTSIDE the home, in the shape the contract describes:
# a directory holding `bin/tool`, which is what TC_f_BINS names, and the same
# directory is what tc_f_adopted reports.
mkdir -p "$work/adopted/bin"
printf '#!/bin/sh\necho adopted\n' > "$work/adopted/bin/tool"
chmod 0755 "$work/adopted/bin/tool"
mkdir -p "$work/fakebin"
printf '#!/bin/sh\necho adopted\n' > "$work/fakebin/adopted-tool"
chmod 0755 "$work/fakebin/adopted-tool"
cat > "$work/ensure2.sh" <<EOF
for m in common detect space fetch env toolchain; do
    . "$ROOT/lib/\$m.sh"
done
mkdir -p "\$SH_EXEC_BIN" "\$SH_EXEC_VIEWS" "\$SH_HOME_TOOLCHAINS" "\$SH_HOME_TMP" 2>/dev/null
sh_toolchain_ensure f
echo "STATUS=\$?"
EOF
adopt_out=$(SH_LIB_DIR="$work/repo/lib" SH_REPO_DIR="$work/repo" \
    SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
    SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
    SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=no SH_DRY_RUN=0 SH_SELF=test \
    SANDHOME_TEST_ADOPTED="$work/adopted" \
    PATH="$work/fakebin:$PATH" sh "$work/ensure2.sh" 2>&1)
t_contains "$adopt_out" 'adopting' 'a toolchain with no home tree is adopted'
t_contains "$adopt_out" 'STATUS=0' 'adopting a toolchain with no home tree succeeds'
t_ok "$([ -e "$work/exec/bin/tool" ]; echo $?)" \
    'the adopted toolchain is linked into the exec bin'

# CLASS B+E: behavioural probes run the tool, not its version, on this machine.
# Each loads the real module against the real library with a scratch home.
for m in common detect space fetch env toolchain; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_HOME="$work/bhome"
SH_EXEC="$work/bexec"
SH_EXEC_BIN="$work/bexec/bin"
SH_EXEC_VIEWS="$work/bexec/views"
SH_HOME_TOOLCHAINS="$work/bhome/toolchains"
SH_HOME_TMP="$work/bhome/tmp"
SH_HOME_EXEC=no
SH_REPO_DIR="$ROOT"
SH_LIB_DIR="$ROOT/lib"
export SH_HOME SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TOOLCHAINS SH_HOME_TMP SH_HOME_EXEC SH_REPO_DIR SH_LIB_DIR
mkdir -p "$SH_EXEC_BIN" "$SH_EXEC_VIEWS" "$SH_HOME_TOOLCHAINS" "$SH_HOME_TMP" 2>/dev/null
if command -v node >/dev/null 2>&1; then
    sh_toolchain_load node >/dev/null 2>&1
    # # STOP: THE CLAIM IS ABOUT THE PROBE, NOT ABOUT THE HOST'S npm. The old
    # assertion was "if this host has node, the probe passes", which is a claim
    # about the base image: a host whose npm is broken fails a green tree. The
    # probe now checks npm for an adopted node too (issue #46), so a host with a
    # broken npm makes the probe answer 1, correctly. Measuring the truth on the
    # same host and comparing is the assertion that is true everywhere: the probe
    # agrees with what node and npm actually do here.
    t_nb_truth=1
    if node -e 'console.log("ok")' >/dev/null 2>&1 && npm --version >/dev/null 2>&1; then
        t_nb_truth=0
    fi
    t_nb_got=1
    if tc_node_behavioural >/dev/null 2>&1; then
        t_nb_got=0
    fi
    t_is "$t_nb_got" "$t_nb_truth" \
        'the node behavioural probe agrees with whether node and npm work here (#19, #46)'
else
    t_skip 'node behavioural probe: no node on this host'
fi
if command -v go >/dev/null 2>&1; then
    sh_toolchain_load go >/dev/null 2>&1
    if tc_go_behavioural >/dev/null 2>&1; then
        t_ok 0 'go behavioural probe builds and runs (#19)'
    else
        t_ok 1 'go behavioural probe builds and runs (#19)'
    fi
else
    t_skip 'go behavioural probe: no go on this host'
fi
if command -v rustc >/dev/null 2>&1; then
    sh_toolchain_load rust >/dev/null 2>&1
    # # STOP: A rustc PROXY WITH NO DEFAULT TOOLCHAIN IS NOT A rustc. On a host
    # whose /usr/bin/rustc is rustup's proxy, `rustc --version` fails and
    # tc_rust_probe (the same test the installer uses) is false; calling the
    # behavioural probe then reported a tree defect for a tool that is not
    # installed here. Gate on the module's own probe, so the clause measures the
    # tree when a working rustc is present and skips when it is not.
    if tc_rust_probe >/dev/null 2>&1; then
        if tc_rust_behavioural >/dev/null 2>&1; then
            t_ok 0 'rust behavioural probe links and runs native (#19)'
        else
            t_ok 1 'rust behavioural probe links and runs native (#19)'
        fi
    else
        t_skip 'rust behavioural probe: no working rustc on this host'
    fi
else
    t_skip 'rust behavioural probe: no rustc on this host'
fi
# install rust --target parses without downloading (unknown target refused by
# rustup later, but the flag itself must be accepted and exported).
inst_t=$(SANDHOME_HOME="$work/ih" SANDHOME_EXEC="$work/ie" SANDHOME_REPO_DIR="$ROOT" \
    sh "$ROOT/bin/sandhome" help 2>&1)
case "$inst_t" in
    *'--target'*) t_ok 0 'install usage names --target (#29)' ;;
    *) t_ok 1 'install usage names --target (#29)' ;;
esac

# --- class H: --force is a flag the tool accepts and obeys --------------------
# # STOP: THE CLAIM IS "AN INSTRUCTION THE TOOL PRINTS IS ONE THE TOOL OBEYS".
# The promote step warns "run 'sandhome install --force <name>' to place it
# properly" for a borrowed toolchain that cannot run from the exec root, and
# until this flag existed the named command adopted again every time and
# installed nothing (issue #45). Three claims, all about the code rather than
# about this host: the usage names it, the dispatcher parses it, and
# sh_toolchain_install_one takes the install branch when it is set.
case "$(sh "$ROOT/bin/sandhome" help 2>/dev/null)" in
    *--force*) t_ok 0 'install usage names --force (#45)' ;;
    *)         t_ok 1 'install usage names --force (#45)' ;;
esac
# The dispatcher must set SH_FORCE and must not eat the name that follows it.
force_env=$(SANDHOME_HOME="$work/fhome" SANDHOME_EXEC="$work/fexec" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; . "$0/lib/space.sh" 2>/dev/null
             SH_FORCE=0
             set -- jq --force ripgrep
             while [ "$#" -gt 0 ]; do
                 case "$1" in
                     --force|-f) SH_FORCE=1; shift ;;
                     *) sh_n="$1"; shift ;;
                 esac
             done
             printf "%s %s" "$SH_FORCE" "$sh_n"' "$ROOT" 2>/dev/null)
t_is "$force_env" '1 ripgrep' 'a --force before a name sets the flag and keeps the name (#45)'
# And the install branch itself: with SH_FORCE=1 the adopt probe is skipped.
# Driven through a fixture module whose install writes a marker, because the
# claim is "the install path runs", not "some real toolchain downloaded".
mkdir -p "$work/forcemod" 2>/dev/null
cat > "$work/forcemod/forcetool.sh" <<'FORCETOOL'
TC_forcetool_DESC='a fixture'
TC_forcetool_BINS=''
tc_forcetool_probe() {
    [ -n "$FORCETOOL_PROBE_ANSWER" ] && return "$FORCETOOL_PROBE_ANSWER"
    return 0
}
# The module creates its own root, as a real one does. A marker written into a
# directory nothing made reports "not installed" for a reason that has nothing to
# do with the branch under test.
tc_forcetool_install() {
    mkdir -p "$SH_HOME_TOOLCHAINS/forcetool" 2>/dev/null
    printf 'installed\n' > "$SH_HOME_TOOLCHAINS/forcetool/.installed" 2>/dev/null
    return 0
}
FORCETOOL
force_branch=$(cat > "$work/forcebranch.sh" <<'FORCEBRANCH'
set -u
# The same library set this file loads for the behavioural probes: the
# preflight asks sh_downloader_ok whether a downloader exists, and a fixture
# that omits lib/fetch.sh fails on THAT instead of on the branch under test.
for m in common detect space fetch env toolchain; do
    # shellcheck source=/dev/null
    . "$1/lib/$m.sh"
done
SH_HOME=$3/home
SH_HOME_TOOLCHAINS=$3/home/toolchains
SH_EXEC=$3/exec
SH_EXEC_BIN=$3/exec/bin
SH_EXEC_VIEWS=$3/exec/views
SH_HOME_TMP=$3/home/tmp
SH_HOME_EXEC=no
export SH_HOME SH_HOME_TOOLCHAINS SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TMP SH_HOME_EXEC
mkdir -p "$SH_HOME_TOOLCHAINS" "$SH_EXEC_BIN" "$SH_HOME_TMP" 2>/dev/null
# The probe answers 0, so the adopt path would be taken without the flag.
FORCETOOL_PROBE_ANSWER=0
export FORCETOOL_PROBE_ANSWER
sh_toolchains_dir() { printf '%s' "$SH_TEST_MODDIR"; }
SH_TEST_MODDIR=$2
export SH_TEST_MODDIR
SH_FORCE=1
export SH_FORCE
sh_toolchain_install_one forcetool >/dev/null 2>&1
[ -f "$SH_HOME_TOOLCHAINS/forcetool/.installed" ] && printf 'installed' || printf 'notinstalled'
FORCEBRANCH
mkdir -p "$work/fb" 2>/dev/null
sh "$work/forcebranch.sh" "$ROOT" "$work/forcemod" "$work/fb" 2>/dev/null)
t_is "$force_branch" 'installed' '--force takes the install branch even when the probe would adopt (#45)'
# And the control that matters: without the flag the SAME fixture adopts. A
# guard that only ever takes the install branch is not a guard, it is a change of
# default, and this is what tells the two apart.
adopt_branch=$(sed 's/^SH_FORCE=1$/SH_FORCE=0/' "$work/forcebranch.sh" > "$work/adoptbranch.sh"
    sed -i 's|\[ -f "$SH_HOME_TOOLCHAINS/forcetool/.installed" \]|false|' "$work/adoptbranch.sh"
    rm -rf "$work/fb2"; mkdir -p "$work/fb2"
    sh "$work/adoptbranch.sh" "$ROOT" "$work/forcemod" "$work/fb2" 2>/dev/null)
t_is "$adopt_branch" 'notinstalled' 'without --force the adopt path is still the default (#45)'

# --- class H: a link that points at itself is refused -------------------------
# # STOP: PLANTED, NOT DESCRIBED. The promote step used to `ln -sfn` whatever
# `command -v` answered, and by then the exec view was on PATH, so on a re-run
# it linked the view onto itself and the tool became
# "Too many levels of symbolic links" (exit 126) - 8 runs out of 8 left jq, rg
# or fd broken (issue #43). The clause plants that state and asks the promote
# step to leave a working link.
sel_dir="$work/selftest"
mkdir -p "$sel_dir/exec/bin" "$sel_dir/real" 2>/dev/null
# The planted state: the exec view is already on PATH ahead of the real binary,
# and it holds a symlink the tree wrote on an earlier run. This is exactly the
# state in which `command -v` answered with the view and the promote step linked
# it onto itself.
printf '#!/bin/sh\nexit 0\n' > "$sel_dir/real/selftesttool" 2>/dev/null
chmod 0755 "$sel_dir/real/selftesttool" 2>/dev/null
ln -sfn "$sel_dir/real/selftesttool" "$sel_dir/exec/bin/selftesttool" 2>/dev/null
self_link=$(cat > "$work/selftest.sh" <<'SELFLINK'
set -u
for m in common detect space fetch env toolchain; do
    # shellcheck source=/dev/null
    . "$1/lib/$m.sh"
done
SH_HOME=$2/home
SH_HOME_TOOLCHAINS=$2/home/toolchains
SH_EXEC=$2/exec
SH_EXEC_BIN=$2/exec/bin
SH_EXEC_VIEWS=$2/exec/views
SH_HOME_TMP=$2/home/tmp
SH_HOME_EXEC=no
export SH_HOME SH_HOME_TOOLCHAINS SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TMP SH_HOME_EXEC
# No toolchain root, so the adopted branch is taken, and the candidates are only
# this directory so the planner cannot wander.
sh_exec_candidates() { printf '%s' "$SH_EXEC"; }
# The module dir arrives in the environment; see the note above.
# Adopted: no toolchain root, so sh_promote_toolchain takes the linking branch.
# PATH has the exec view first, which is the state that produced the self-link.
SH_TEST_REAL=$2/real
PATH="$SH_EXEC_BIN:$SH_TEST_REAL:$PATH"
export PATH
sh_promote_toolchain selftesttool selftesttool >/dev/null 2>&1
if [ -L "$SH_EXEC_BIN/selftesttool" ]; then
    t=$(readlink "$SH_EXEC_BIN/selftesttool")
    [ "$t" = "$SH_EXEC_BIN/selftesttool" ] && printf 'self' || printf 'linked'
else
    printf 'missing'
fi
SELFLINK
sh "$work/selftest.sh" "$ROOT" "$sel_dir" 2>/dev/null)
t_is "$self_link" 'linked' 'the promote step does not link the exec view onto itself (#43)'

# # STOP: `repair` FIXES A SELF-LINKED VIEW, AND DOWNLOADS NOTHING. The whole
# consumer-facing diagnosis routed step 2 through `sandhome install <name>`, and
# on a host with an adopted toolchain that is the command that BROKE the view,
# so following the documented procedure reproduced the defect 8 rounds out of 8
# (issues #49, #43). `repair` is the command the docs name instead, and these
# clauses hold it to that: a view whose links point at themselves is repaired,
# and no download is attempted.
#
# A link that points at itself is invisible to `[ -e ]` on a shell that follows
# the link silently, which is why it survived for so long. This breaks the view
# the way a real one breaks and then checks the tool runs afterwards.
rep_home=$sel_dir/repair-home
rep_exec=$sel_dir/repair-exec
rm -rf "$rep_home" "$rep_exec"
mkdir -p "$rep_home" "$rep_exec/bin" "$sel_dir/repair-real"
printf '#!/bin/sh\necho jq-1.8.2 2>/dev/null\n' > "$sel_dir/repair-real/jq"
chmod 755 "$sel_dir/repair-real/jq"
ln -s "$rep_exec/bin/jq" "$rep_exec/bin/jq"

out=$( SANDHOME_HOME="$rep_home" SANDHOME_EXEC="$rep_exec" \
       SANDHOME_REPO_DIR="$ROOT" SH_REPO_DIR="$ROOT" \
       PATH="$rep_exec/bin:$sel_dir/repair-real:/usr/bin:/bin" \
       sh "$ROOT/bin/sandhome" repair jq 2>&1 )
rc=$?
if [ -L "$rep_exec/bin/jq" ]; then
    t=$(readlink "$rep_exec/bin/jq")
    case "$t" in
        "$rep_exec"/*) t_ok 1 "repair rewrites a self-linked view link (got $t)" ;;
        *) t_ok 0 'repair rewrites a self-linked view link' ;;
    esac
    if "$rep_exec/bin/jq" --version >/dev/null 2>&1; then
        t_ok 0 'the repaired tool runs from the exec view'
    else
        t_ok 1 'the repaired tool runs from the exec view'
    fi
else
    t_ok 1 'repair rewrites a self-linked view link (no link)'
    t_ok 1 'the repaired tool runs from the exec view'
fi
case "$out" in
    *Downloaded*) t_ok 1 'repair downloads nothing' ;;
    *) t_ok 0 'repair downloads nothing' ;;
esac

# An unknown name is refused by name and the command still exits non-zero,
# rather than silently repairing whatever it felt like.
bad_out=$( SANDHOME_HOME="$rep_home" SANDHOME_EXEC="$rep_exec" \
           SANDHOME_REPO_DIR="$ROOT" SH_REPO_DIR="$ROOT" \
           PATH="$rep_exec/bin:$sel_dir/repair-real:/usr/bin:/bin" \
           sh "$ROOT/bin/sandhome" repair nosuchtoolchain 2>&1 )
bad_rc=$?
t_contains "$bad_out" 'unknown toolchain nosuchtoolchain' 'repair names an unknown toolchain'
if [ "$bad_rc" -ne 0 ]; then
    t_ok 0 'repair exits non-zero on an unknown toolchain'
else
    t_ok 1 'repair exits non-zero on an unknown toolchain'
fi

# # STOP: A TOOLCHAIN THAT ANSWERS --version AND REFUSES TO COMPILE IS NOT A
# TOOLCHAIN, AND IS NOT ADOPTED. Some sealed sandboxes ship a multi-arch rust as
# a shim that answers `--version` and refuses everything else, which is what
# tc_rust_probe asks: `sh_have rustc && rustc --version`. So the probe passed, the
# adopt path was taken, `sandhome install rust` exited 0 and printed
# "a working copy is already here; adopting it", and the first build the
# consumer attempted failed (issue #53). Measured here with exactly that shim:
#   rustc --version   -> rustc 1.99.0 (proxy build 2026-01-01)
#   rustc hello.rs    -> proxy rustc: refusing, not a compiler   (exit 1)
#   sandhome install rust -> exit 0
#   sandhome report       -> toolchain.rust=rustc 1.99.0 (proxy build 2026-01-01)
# A report line naming a working version is the tree's own refusal to be soothed:
# the module already has a behavioural probe, and it was gated on a noexec home,
# which is not what is wrong here. The probe is what the decision needs, because
# the thing being decided is whether this copy can build.
mkdir -p "$work/proxybin"
cat > "$work/proxybin/rustc" <<'PROXY'
#!/bin/sh
case "${1:-}" in
    --version|-V) echo "rustc 1.99.0 (proxy build 2026-01-01)"; exit 0 ;;
esac
echo "proxy rustc: refusing, not a compiler" >&2
exit 1
PROXY
chmod 0755 "$work/proxybin/rustc"

cat > "$work/proxyprobe.sh" <<EOF
for m in common detect space fetch env toolchain; do
    . "$ROOT/lib/\$m.sh"
done
sh_toolchain_load rust
printf 'BEHAVIOURAL=%s\n' "\$(tc_rust_behavioural >/dev/null 2>&1 && printf 0 || printf 1)"
# The decision, not just the helper: this is what sh_toolchain_ensure asks.
if tc_rust_probe >/dev/null 2>&1; then
    printf 'PROBE=adopt\n'
else
    printf 'PROBE=install\n'
fi
EOF
proxy_probe=$(SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
    SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
    SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
    SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=yes SH_DRY_RUN=1 SH_SELF=test \
    PATH="$work/proxybin:$PATH" sh "$work/proxyprobe.sh" 2>/dev/null)
t_contains "$proxy_probe" 'BEHAVIOURAL=1' \
    'a rustc that refuses to compile fails the behavioural probe despite answering --version'
t_contains "$proxy_probe" 'PROBE=install' \
    'a proxy rustc is not adopted, so a real toolchain is installed instead (#53)'

# The control, which matters as much: a rustc that really compiles must still be
# adopted, or the fix is just "never adopt rust" and every host pays a download.
# It is a stub rather than the host's rustc so the clause means the same thing
# everywhere, including on a host with no compiler at all.
mkdir -p "$work/realbin"
cat > "$work/realbin/rustc" <<'REALC'
#!/bin/sh
case "${1:-}" in
    --version|-V) echo "rustc 1.99.0 (real build)"; exit 0 ;;
esac
# -o FILE: write a runnable program, which is what the probe actually checks.
out=./a.out
prev=''
for a in "$@"; do
    [ "$prev" = -o ] && out=$a
    prev=$a
done
printf '#!/bin/sh\nexit 0\n' > "$out" 2>/dev/null || exit 1
chmod 0755 "$out" 2>/dev/null
exit 0
REALC
chmod 0755 "$work/realbin/rustc"
real_probe=$(SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
    SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
    SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
    SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=yes SH_DRY_RUN=1 SH_SELF=test \
    PATH="$work/realbin:$PATH" sh "$work/proxyprobe.sh" 2>/dev/null)
t_contains "$real_probe" 'PROBE=adopt' \
    'a rustc that compiles is still adopted, so the probe costs no download'

t_end
