#!/bin/sh
# fetch.sh - one download path, one checksum path, one unpack path. Sourced.
#
# NOTE: WHAT A RUN-TIME DIGEST PROVES IS TRANSPORT, NOT AUTHORSHIP. Where the
# expected digest comes from the same release as the bytes, whoever could replace
# one could replace the other. It is still the right check for a mirror that
# truncates a download; `SANDHOME_SHA256` adds the stronger pinned check back for
# a caller who holds the value.

# sh_tool_runs NAME [ARGS...] -> 0 when NAME resolves AND runs. `command -v`
# answers about PATH, not about whether the binary works: a BusyBox wget
# resolves and then rejects GNU flags, a function shadows a tool, a broken
# symlink resolves and then fails. Capability probes in this file go through
# here (issues #3, #9), with TWO named exceptions, both deliberate:
#   sh_downloader_ok fetch -> `sh_have fetch`: BSD fetch has no stable probe
#     flag, so resolution is the probe and the fetch itself is the test.
#   sh_curl_dns_exit -> opens with `sh_have curl`: a presence test before a
#     measured exit code, not a substitute for one; the DoH gate then runs the
#     real probe.
# A new capability probe belongs here unless it has a reason this good, stated
# beside it.
sh_tool_runs() {
    sh_tr_name=$1
    shift
    sh_have "$sh_tr_name" || return 1
    "$sh_tr_name" "$@" >/dev/null 2>&1
    return $?
}

# sh_wget_flavor -> gnu, busybox, toybox or unknown. Reads `wget --help` on
# stdout+stderr and picks the spelling by which literal appears (issue #3,
# hackshell hs_init_dl shape): GNU vs BusyBox take different option
# spellings, and trusting one spelling for all three is how a present
# downloader fails every download it is given.
sh_wget_flavor() {
    sh_wf_help=$(wget --help 2>&1) || { printf 'unknown'; return 0; }
    case "$sh_wf_help" in
        *BusyBox*) printf 'busybox'; return 0 ;;
        *toybox*) printf 'toybox'; return 0 ;;
        *'GNU Wget'*) printf 'gnu'; return 0 ;;
    esac
    printf 'unknown'
}

# sh_wget_fetch URL DEST FLAVOR -> 0 when the wget whose flavor is FLAVOR
# fetched URL. The flavor decides the argv, which is the whole point of
# detecting it (issue #3): GNU wget and BusyBox/toybox wget share `-q -O`,
# but a BusyBox build rejects `--tries`/`--timeout`, and a version whose
# --help names nothing (the `unknown` answer, e.g. a shadow that prints
# nothing) gets the lowest-common-denominator spelling and no retries, so
# a present-but-strict wget is never handed a flag it must reject.
sh_wget_fetch() {
    sh_wgf_url=$1
    sh_wgf_dest=$2
    case "$3" in
        gnu)
            wget -q --tries=3 --timeout=30 -O "$sh_wgf_dest" "$sh_wgf_url" 2>/dev/null
            ;;
        *)
            wget -q -O "$sh_wgf_dest" "$sh_wgf_url" 2>/dev/null
            ;;
    esac
}

# sh_downloader_ok NAME -> 0 when NAME can be used for a download here.
# curl must answer --version (a shadow that prints nothing is not curl);
# wget must answer --help (which also feeds sh_wget_flavor); BSD fetch has
# no stable probe flag, so resolution is the probe and the fetch itself is
# the test. Callers never branch on names: sh_fetch tries each in turn.
sh_downloader_ok() {
    case "$1" in
        curl) sh_tool_runs curl --version ;;
        wget) sh_tool_runs wget --help ;;
        fetch) sh_have fetch ;;
        *) return 1 ;;
    esac
}

# sh_downloader_hint -> one install line for this machine's provider, or
# nothing when the provider is unknown. A bootstrap that cannot say
# "apt-get install curl" wastes the session it was meant to save (issue #7:
# probe for the provider, then name what provides the prerequisite).
sh_downloader_hint() {
    sh_dh_p=${SH_PROVIDER:-}
    if [ -z "$sh_dh_p" ] && command -v sh_detect_provider >/dev/null 2>&1; then
        sh_dh_p=$(sh_detect_provider 2>/dev/null)
    fi
    case "$sh_dh_p" in
        apk) printf 'apk add curl' ;;
        apt) printf 'apt-get install curl' ;;
        dnf) printf 'dnf install curl' ;;
        yum) printf 'yum install curl' ;;
        pacman) printf 'pacman -S curl' ;;
        zypper) printf 'zypper install curl' ;;
        xbps) printf 'xbps-install -S curl' ;;
        emerge) printf 'emerge -a net-misc/curl' ;;
        tdnf) printf 'tdnf install curl' ;;
        pkg) printf 'pkg install curl' ;;
        pkg_add) printf 'pkg_add curl' ;;
        pkgin) printf 'pkgin install curl' ;;
        *) printf '' ;;
    esac
}

# ------------------------------------------------------- DoH fallback --
# A DoH bootstrap gated on a CONFIRMED resolver failure (issue #6, goecs.sh
# DOH_URL/DOH_RESOLVE/curl_supports_doh/system_dns_stably_unavailable shape).
#
# The endpoint is a variable and the fallback stays OFF unless asked for:
# SANDHOME_DOH_URL empty (the default) means this whole section refuses
# without touching the network. Set it to an IP-literal resolver such as
# https://1.1.1.1/dns-query so the retry itself cannot need DNS.
: "${SANDHOME_DOH_URL:-}"

# sh_doh_host_of URL -> the host part of an https URL, or nothing.
sh_doh_host_of() {
    sh_dh_u=${1#https://}
    sh_dh_u=${sh_dh_u#http://}
    sh_dh_u=${sh_dh_u%%/*}
    printf '%s' "$sh_dh_u"
}

# sh_doh_pinned URL -> 0 when URL pins its resolver by IP literal, so the
# retry cannot itself need DNS. A hostname here reintroduces the failure it
# is meant to route around and is warned about, not silently used.
sh_doh_pinned() {
    sh_dp_host=$(sh_doh_host_of "$1")
    [ -n "$sh_dp_host" ] || return 1
    case "$sh_dp_host" in
        *[a-zA-Z]*) return 1 ;;
        *) return 0 ;;
    esac
}

# sh_curl_dns_exit URL -> curl's exit code for a cheap header fetch, or 99
# when curl is absent. Only exit 6 (could not resolve host) counts as a DNS
# failure; every other code means the resolver answered and the failure is
# elsewhere. The body goes to /dev/null; what is read is the status.
sh_curl_dns_exit() {
    sh_have curl || { printf '99'; return 0; }
    curl -fsS -o /dev/null --max-time 8 --connect-timeout 5 "$1" 2>/dev/null
    printf '%s' "$?"
    return 0
}

# sh_resolver_failed_twice [CANARY_URL] -> 0 only when curl answers exit 6
# twice in a row against a known host. One exit 6 is a coincidence not yet
# noticed; a resolver answering for any known host means 'not our problem' and
# refuses. The canary is the URL that just failed when the caller hands one
# in (sh_fetch_via_doh passes its URL), so the two probes spend their time on
# the host that matters and prove the thing that failed; a canary like github
# on a cage where github is unreachable answered 'network dead', not 'DNS
# dead', and the gate then refused a retry that would have worked. Override:
# SANDHOME_DOH_CANARY. Each probe is bounded by sh_curl_dns_exit's timeouts.
# The canary default is a real variable with a real default, and NOT a nested
# expression, so the generated reference can read it (the extractor greps a
# `:=` assignment; a default buried in ${1:-${VAR:-...}} parsed as unset and
# the table lied).
: "${SANDHOME_DOH_CANARY:=https://github.com}"
sh_resolver_failed_twice() {
    sh_rf_canary=${1:-$SANDHOME_DOH_CANARY}
    sh_rf_first=$(sh_curl_dns_exit "$sh_rf_canary")
    [ "$sh_rf_first" = 6 ] || return 1
    sh_rf_second=$(sh_curl_dns_exit "$sh_rf_canary")
    [ "$sh_rf_second" = 6 ] || return 1
    return 0
}

# sh_fetch_via_doh URL DEST -> 0 when the DoH retry fetched the URL. Refuses
# (return 1, no network beyond two confirmatory probes) unless ALL hold:
# curl exists and supports --doh-url, SANDHOME_DOH_URL is set, the resolver
# failure is confirmed twice, and the retry verifies. Nothing here changes
# the plain path: callers reach this only after every downloader failed.
sh_fetch_via_doh() {
    sh_fd_url=$1
    sh_fd_dest=$2
    [ -n "${SANDHOME_DOH_URL:-}" ] || return 1
    sh_have curl || return 1
    if ! curl --help 2>&1 | grep -q -- '--doh-url' 2>/dev/null; then
        sh_warn "curl does not support --doh-url here, so SANDHOME_DOH_URL is ignored"
        return 1
    fi
    if ! sh_doh_pinned "$SANDHOME_DOH_URL"; then
        sh_warn "SANDHOME_DOH_URL names a host ($(sh_doh_host_of "$SANDHOME_DOH_URL")), which still needs DNS; prefer an IP literal such as https://1.1.1.1/dns-query"
    fi
    if ! sh_resolver_failed_twice "$sh_fd_url"; then
        return 1
    fi
    if curl -fSL --retry 2 --retry-delay 2 --doh-url "$SANDHOME_DOH_URL" \
            -o "$sh_fd_dest" "$sh_fd_url" 2>/dev/null && [ -s "$sh_fd_dest" ]; then
        sh_step "Downloaded from: $sh_fd_url with curl via DoH ($SANDHOME_DOH_URL)"
        return 0
    fi
    sh_warn "DoH retry via $SANDHOME_DOH_URL could not fetch $sh_fd_url"
    return 1
}

# sh_fetch URL DEST -> 0 on a complete download. curl, then wget, then BSD fetch.
#
# STOP: EVERY FALLBACK IS TRIED, AND A FAILED ATTEMPT FALLS THROUGH LOUDLY.
# The old form ran one tool and returned its status, so a machine whose curl
# exists but fails (no resolver, TLS refusal, proxy 403) never tried wget,
# and a BusyBox wget that rejects the flags it was passed failed the only
# attempt it got. Each attempt below is a capability probe that ran, and a
# failure names the tool and moves on (issues #3, #13). The success line names
# the route the bytes came from, because a later failure is diagnosed against
# it (issue #13, nt_install.sh shape).
sh_fetch() {
    sh_f_url=$1
    sh_f_dest=$2
    if sh_downloader_ok curl; then
        if curl -fSL --retry 3 --retry-delay 2 -o "$sh_f_dest" "$sh_f_url" 2>/dev/null; then
            [ -s "$sh_f_dest" ] && { sh_step "Downloaded from: $sh_f_url with curl"; return 0; }
        fi
        sh_warn "curl could not fetch $sh_f_url; trying the next downloader"
    fi
    if sh_downloader_ok wget; then
        sh_f_flavor=$(sh_wget_flavor)
        # STOP: THE FLAVOR DECIDES THE ARGV. A first version had a `case` whose
        # arms were byte-for-byte identical, so the tree detected the flavor,
        # printed it, and did not act on it - the defect the issue was filed
        # about, wearing the costume of a fix. sh_wget_fetch owns the spelling;
        # see its comment for why each arm differs.
        if sh_wget_fetch "$sh_f_url" "$sh_f_dest" "$sh_f_flavor"; then
            [ -s "$sh_f_dest" ] && { sh_step "Downloaded from: $sh_f_url with wget ($sh_f_flavor)"; return 0; }
        fi
        sh_warn "wget ($sh_f_flavor) could not fetch $sh_f_url; trying the next downloader"
    fi
    if sh_downloader_ok fetch; then
        if fetch -q -o "$sh_f_dest" "$sh_f_url" 2>/dev/null && [ -s "$sh_f_dest" ]; then
            sh_step "Downloaded from: $sh_f_url with fetch"
            return 0
        fi
        sh_warn "fetch could not fetch $sh_f_url"
    fi
    # Gated DoH retry (issue #6): the plain downloaders are exhausted, so a
    # confirmed resolver failure may still be recoverable through DNS over
    # HTTPS. Off unless SANDHOME_DOH_URL is set; see sh_fetch_via_doh.
    if sh_fetch_via_doh "$sh_f_url" "$sh_f_dest"; then
        return 0
    fi
    sh_f_hint=$(sh_downloader_hint)
    # # STOP: "NO DOWNLOADER COULD FETCH" NAMED THE WRONG THING. A downloader
    # that is present and failing is not a missing downloader, and the message
    # sent a consumer to install a tool they already had. Measured here by
    # stripping the egress from a shell that had every downloader installed:
    #   nodejs.org could not be resolved (curl exit 6, twice, on a known host)
    #   bootstrap: [!] no downloader could fetch https://nodejs.org/dist/index.json
    #              (tried curl, wget, fetch); install one first: xbps-install -S curl
    # ...with curl on PATH the whole time, and the real cause - a resolver that
    # answers nothing - nowhere in the message. A cage with no resolver is the
    # situation this tree has a DoH path for, and the message walked past it.
    #
    # So the last word is the reason, and the reason is measured rather than
    # guessed: a downloader that cannot resolve a known host is told so, and the
    # DoH lever is named. Only when there is genuinely no downloader does the
    # install-one line appear, because then it is the truth.
    sh_f_dns=$(sh_curl_dns_exit "$sh_f_url")
    if [ "$sh_f_dns" = 6 ]; then
        sh_warn "curl could not resolve the host for $sh_f_url (exit 6): this sandbox has no working resolver"
        sh_warn "if that is a cage without DNS, set SANDHOME_DOH_URL to a DoH resolver and retry; see docs/guide.md"
        return 1
    fi
    if [ -n "$sh_f_hint" ]; then
        sh_warn "a downloader is present but could not fetch $sh_f_url (tried curl, wget, fetch); the exit was not a DNS failure, so check the URL and this sandbox's egress"
    else
        sh_warn "no curl, wget or fetch is present, so nothing can be downloaded; install one first: ${sh_f_hint:-your package manager}"
    fi
    return 1
}

# sh_redirect_target URL -> the URL a redirect lands on. This is how a `latest`
# release names its tag without parsing JSON anywhere.
sh_redirect_target() {
    if sh_have curl; then
        curl -fsSL -o /dev/null -w '%{url_effective}' "$1" 2>/dev/null
        return 0
    fi
    if sh_have wget; then
        # wget --spider prints the chain; the last Location is the target.
        wget -q -S --spider "$1" 2>&1 | {
            sh_rt_last=''
            while read -r sh_rt_line; do
                case "$sh_rt_line" in
                    Location:*) sh_rt_last=$(sh_trim "${sh_rt_line#Location:}") ;;
                esac
            done
            printf '%s' "$sh_rt_last"
        }
        return 0
    fi
    printf ''
}

# sh_github_latest_tag OWNER/REPO -> the tag the `latest` release points at, or
# nothing. The redirect is what names the tag without parsing JSON anywhere.
# STOP: `${url##*/tag/}` AND NOT `${url##*/}`: a tag that itself contains a slash
# (`release/1.2`) is returned whole, where the short form would truncate it.
sh_github_latest_tag() {
    sh_glt_url=$(sh_redirect_target "https://github.com/$1/releases/latest")
    case "$sh_glt_url" in
        */releases/tag/*) printf '%s' "${sh_glt_url##*/releases/tag/}" ;;
        */tag/*)          printf '%s' "${sh_glt_url##*/tag/}" ;;
        *)                printf '' ;;
    esac
}

# sh_sha256_which -> the name of the tool that will take a digest here, or
# nothing. It is asked BEFORE the digest is taken so the report can name it.
sh_sha256_which() {
    if sh_have sha256sum; then printf 'sha256sum'; return 0; fi
    if sh_have sha256;    then printf 'sha256';    return 0; fi
    if sh_have shasum;    then printf 'shasum';    return 0; fi
    if sh_have openssl;   then printf 'openssl';   return 0; fi
    if sh_have python3;  then printf 'python3';   return 0; fi
    if sh_have node;     then printf 'node';      return 0; fi
    printf ''
}

# sh_sha256_stream_which -> the name of a tool that can hash a STREAM here, or
# nothing. It is a different list from sh_sha256_which because the streaming
# tools must read stdin, and the choice is asked before the bytes move for the
# same reason SANDHOME_REQUIRE_DIGEST asks before a download.
sh_sha256_stream_which() {
    if sh_have sha256sum; then printf 'sha256sum'; return 0; fi
    if sh_have sha256;    then printf 'sha256';    return 0; fi
    if sh_have shasum;    then printf 'shasum';    return 0; fi
    if sh_have openssl;   then printf 'openssl';   return 0; fi
    if sh_have python3; then printf 'python3'; return 0; fi
    if sh_have node;    then printf 'node';    return 0; fi
    printf ''
}

# sh_sha256 FILE -> the lowercase hex digest, or nothing when no tool can take
# it. Five candidates, and every one is absent somewhere: sha256sum is coreutils,
# a BSD base has `sha256`, a minimal image may have only openssl, and python3
# arrives with the toolchain rather than before it.
sh_sha256() {
    if sh_have sha256sum; then sh_first_word sha256sum "$1"; return 0; fi
    if sh_have sha256;    then sha256 -q "$1" 2>/dev/null; return 0; fi
    if sh_have shasum;    then sh_first_word shasum -a 256 "$1"; return 0; fi
    if sh_have openssl;   then sh_first_word openssl dgst -sha256 -r "$1"; return 0; fi
    if sh_have python3; then
        python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null
        return 0
    fi
    if sh_have node; then
        node -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' "$1"
        return 0
    fi
    printf ''
}

# -------------------------------------------------------------- pinned digests --
# THE PIN IS PER DOWNLOAD, AND ONE VARIABLE CANNOT PIN A TOOLSET.
#
# `SANDHOME_SHA256` was documented as "pin a sha256 for every download this run
# makes" and it was passed to EVERY download, so a `cli` toolset (three
# downloads) could only ever match the first one: the other two were compared
# against a digest belonging to a different file and failed with a message that
# blamed the mirror. The result was ORDER-DEPENDENT, which is how a reader knows
# a check is broken rather than strict. It also silently discarded the digests
# go.dev and nodejs.org publish, because those modules pass the published value
# through the SAME third argument.
#
# There is one pin per download, resolved in this order:
#   1. SANDHOME_SHA256_<name>   the toolchain name, upper-cased (JQ, RIPGREP)
#   2. SANDHOME_SHA256_<file>   the URL's last path segment, upper-cased and
#                               stripped of its extension (JQ-LINUX-AMD64,
#                               UV-X86_64-UNKNOWN-LINUX-GNU)
#   3. the EXPECTED argument the caller passed, i.e. a digest the PUBLISHER
#      published beside the bytes
#   4. SANDHOME_SHA256          the bare value, which is a DEFAULT and not an
#                               override: it applies only where nothing more
#                               specific was found
#
# Rule 3 above rule 4 is the load-bearing one. A caller who sets
# SANDHOME_SHA256 to pin one download no longer silently disables go.dev's own
# digest for another, which was the worst part of the old behaviour: a stronger
# check quietly turned off by a weaker one. See docs/decisions/pinning.md.

# sh_pin_key URL -> the upper-cased basename of URL with its extension removed.
# `jq-linux-amd64` and `uv-x86_64-unknown-linux-gnu.tar.gz` both answer as
# themselves, so a caller can pin a URL-only asset with no toolchain name.
#
# # STOP: THE BASENAME IS CUT BY HAND AND NOT WITH `${url##*/}`, BECAUSE THE
# PATTERN IS GLOB SYNTAX AND AN URL IS NOT A GLOB. `${1##*/}` on
# `https://x/jq-linux-amd64?a=1` finds no `/` after the last one it matches and
# answers the WHOLE URL, and the pin key it then built was
# `HTTPS://X/JQ-LINUX-AMD64?A=1`. A query string has to come off before the
# extension does, or a key for `...tar.gz?token=abc` kept its `?token`. Both
# were measured against this function before the walk below replaced the
# arithmetic.
sh_pin_key() {
    sh_pk_all=$1
    sh_pk_all=${sh_pk_all%%\?*}
    sh_pk_all=${sh_pk_all%%\#*}
    sh_pk_last=''
    sh_pk_rest=$sh_pk_all
    while :; do
        case "$sh_pk_rest" in
            */*) sh_pk_last=${sh_pk_rest%%/*}
                 sh_pk_rest=${sh_pk_rest#*/} ;;
            *)   sh_pk_last=$sh_pk_rest
                 break ;;
        esac
    done
    sh_pk_last=${sh_pk_last%.*}
    # # STOP: THE KEY IS UPPER-CASED WITH ITS HYPHENS KEPT, AND THE `case` IN
    # sh_pin_for HAS AN ARM FOR EACH SPELLING. The first design underscored the
    # key as well, and then the `case` arms were written with hyphens and never
    # matched; the second underscored the arms and they never matched either.
    # The key is what a FILE is called and keeps the file's own hyphens; the
    # variable is what a CALLER can spell in POSIX sh and cannot hold a hyphen.
    # The two are joined by the arms, and tests/unit.sh checks both spellings
    # answer for the same URL so they cannot drift apart again.
    printf '%s' "$(sh_upper "$sh_pk_last")"
}

# sh_pin_for URL [NAME] [PUBLISHED] -> the digest this URL must match, or
# nothing. Nothing is a real answer: it means the download is hashed and printed
# with no value to compare against, which is what happens for the five modules
# whose publisher does not publish a digest this can read.
#
# # STOP: THE LOOKUP IS A `case` AND NOT `eval`, BECAUSE A DERIVED VARIABLE NAME
# CANNOT BE AN INDIRECT REFERENCE IN POSIX SH, AND A NAME BUILT FROM AN URL
# CANNOT BE WRITTEN AT ALL. `eval "x=\${$var:-}"` is the only indirect read
# POSIX sh has, and it is a `case` pattern or a COMMAND as soon as the name
# contains a hyphen, a `*` or a `/`. Both happened here:
#   SANDHOME_SHA256_JQ-LINUX-AMD64=bbb  -> dash: SANDHOME_SHA256_JQ-LINUX-AMD64: not found
#   eval with a key built from an url  -> Bad substitution
# The names this has to read are a CLOSED SET: seven toolchain names and a dozen
# asset basenames, all written below. Naming them makes the lookup a `case` over
# literals, so no URL is ever spliced into a command, and a new toolchain that
# wants a name pin adds one line here. `sh_pin_names` prints the list and
# tests/unit.sh checks it against the modules, so the two cannot drift.
sh_pin_for() {
    sh_pf_url=$1
    sh_pf_name=${2:-}
    sh_pf_published=${3:-}
    if [ -n "$sh_pf_name" ]; then
        case "$sh_pf_name" in
            bun)     [ -n "${SANDHOME_SHA256_BUN:-}" ] && { printf '%s' "$SANDHOME_SHA256_BUN"; return 0; } ;;
            clang)   [ -n "${SANDHOME_SHA256_CLANG:-}" ] && { printf '%s' "$SANDHOME_SHA256_CLANG"; return 0; } ;;
            deno)    [ -n "${SANDHOME_SHA256_DENO:-}" ] && { printf '%s' "$SANDHOME_SHA256_DENO"; return 0; } ;;
            fd)      [ -n "${SANDHOME_SHA256_FD:-}" ] && { printf '%s' "$SANDHOME_SHA256_FD"; return 0; } ;;
            go)      [ -n "${SANDHOME_SHA256_GO:-}" ] && { printf '%s' "$SANDHOME_SHA256_GO"; return 0; } ;;
            jq)      [ -n "${SANDHOME_SHA256_JQ:-}" ] && { printf '%s' "$SANDHOME_SHA256_JQ"; return 0; } ;;
            mold)    [ -n "${SANDHOME_SHA256_MOLD:-}" ] && { printf '%s' "$SANDHOME_SHA256_MOLD"; return 0; } ;;
            node)    [ -n "${SANDHOME_SHA256_NODE:-}" ] && { printf '%s' "$SANDHOME_SHA256_NODE"; return 0; } ;;
            python)  [ -n "${SANDHOME_SHA256_PYTHON:-}" ] && { printf '%s' "$SANDHOME_SHA256_PYTHON"; return 0; } ;;
            ripgrep) [ -n "${SANDHOME_SHA256_RIPGREP:-}" ] && { printf '%s' "$SANDHOME_SHA256_RIPGREP"; return 0; } ;;
            rust)    [ -n "${SANDHOME_SHA256_RUST:-}" ] && { printf '%s' "$SANDHOME_SHA256_RUST"; return 0; } ;;
            zig)     [ -n "${SANDHOME_SHA256_ZIG:-}" ] && { printf '%s' "$SANDHOME_SHA256_ZIG"; return 0; } ;;
        esac
    fi
    case "$(sh_pin_key "$sh_pf_url")" in
        FD)      [ -n "${SANDHOME_SHA256_FD:-}" ] && { printf '%s' "$SANDHOME_SHA256_FD"; return 0; } ;;
        FD-V*)   [ -n "${SANDHOME_SHA256_FD:-}" ] && { printf '%s' "$SANDHOME_SHA256_FD"; return 0; } ;;
        GO)      [ -n "${SANDHOME_SHA256_GO:-}" ] && { printf '%s' "$SANDHOME_SHA256_GO"; return 0; } ;;
        GO1)     [ -n "${SANDHOME_SHA256_GO:-}" ] && { printf '%s' "$SANDHOME_SHA256_GO"; return 0; } ;;
        GO-*)    [ -n "${SANDHOME_SHA256_GO:-}" ] && { printf '%s' "$SANDHOME_SHA256_GO"; return 0; } ;;
        JQ)      [ -n "${SANDHOME_SHA256_JQ:-}" ] && { printf '%s' "$SANDHOME_SHA256_JQ"; return 0; } ;;
        # # STOP: THE ASSET ARMS ARE EXACT, AND A WILDCARD HERE PINS THE WRONG
        # ARCHITECTURE. A first version matched `JQ-LINUX-*` and read
        # SANDHOME_SHA256_JQ_LINUX_AMD64 out of it, so a caller who pinned the
        # amd64 jq binary had that same digest applied to the arm64 download on
        # an arm64 machine - a check that passes for the wrong bytes, which is
        # worse than no check because it looks like a check. Measured:
        #   SANDHOME_SHA256_JQ_LINUX_AMD64=amd64digest
        #   sh_pin_for https://x/jq-linux-arm64   ->  amd64digest   (wrong)
        # Each asset is named outright. A new platform asset adds one line here.
        #
        # The variable is UNDERSCORED because a POSIX sh assignment cannot hold
        # a hyphen in its name at all - `SANDHOME_SHA256_JQ-LINUX-AMD64=bbb`
        # answers "not found" - while the KEY keeps the file's own hyphens,
        # because it is derived from a file name. The two are joined by these
        # arms, and tests/unit.sh requires both spellings to answer for the
        # same URL, so the join cannot rot.
        JQ-LINUX-AMD64) [ -n "${SANDHOME_SHA256_JQ_LINUX_AMD64:-}" ] && { printf '%s' "${SANDHOME_SHA256_JQ_LINUX_AMD64}"; return 0; } ;;
        JQ-LINUX-ARM64) [ -n "${SANDHOME_SHA256_JQ_LINUX_ARM64:-}" ] && { printf '%s' "${SANDHOME_SHA256_JQ_LINUX_ARM64}"; return 0; } ;;
        JQ-LINUX-I386)  [ -n "${SANDHOME_SHA256_JQ_LINUX_I386:-}" ] && { printf '%s' "${SANDHOME_SHA256_JQ_LINUX_I386}"; return 0; } ;;
        JQ-MACOS-AMD64) [ -n "${SANDHOME_SHA256_JQ_MACOS_AMD64:-}" ] && { printf '%s' "${SANDHOME_SHA256_JQ_MACOS_AMD64}"; return 0; } ;;
        NODE)    [ -n "${SANDHOME_SHA256_NODE:-}" ] && { printf '%s' "$SANDHOME_SHA256_NODE"; return 0; } ;;
        NODE-V*) [ -n "${SANDHOME_SHA256_NODE:-}" ] && { printf '%s' "$SANDHOME_SHA256_NODE"; return 0; } ;;
        PYTHON)  [ -n "${SANDHOME_SHA256_PYTHON:-}" ] && { printf '%s' "$SANDHOME_SHA256_PYTHON"; return 0; } ;;
        RIPGREP) [ -n "${SANDHOME_SHA256_RIPGREP:-}" ] && { printf '%s' "$SANDHOME_SHA256_RIPGREP"; return 0; } ;;
        RIPGREP-*) [ -n "${SANDHOME_SHA256_RIPGREP:-}" ] && { printf '%s' "$SANDHOME_SHA256_RIPGREP"; return 0; } ;;
        RUSTUP-*) [ -n "${SANDHOME_SHA256_RUST:-}" ] && { printf '%s' "$SANDHOME_SHA256_RUST"; return 0; } ;;
        ZIG)     [ -n "${SANDHOME_SHA256_ZIG:-}" ] && { printf '%s' "$SANDHOME_SHA256_ZIG"; return 0; } ;;
        ZIG-*)   [ -n "${SANDHOME_SHA256_ZIG:-}" ] && { printf '%s' "$SANDHOME_SHA256_ZIG"; return 0; } ;;
        MOLD)    [ -n "${SANDHOME_SHA256_MOLD:-}" ] && { printf '%s' "$SANDHOME_SHA256_MOLD"; return 0; } ;;
        MOLD-*)  [ -n "${SANDHOME_SHA256_MOLD:-}" ] && { printf '%s' "$SANDHOME_SHA256_MOLD"; return 0; } ;;
        CLANG)   [ -n "${SANDHOME_SHA256_CLANG:-}" ] && { printf '%s' "$SANDHOME_SHA256_CLANG"; return 0; } ;;
        CLANG-*) [ -n "${SANDHOME_SHA256_CLANG:-}" ] && { printf '%s' "$SANDHOME_SHA256_CLANG"; return 0; } ;;
        LLVM-*)  [ -n "${SANDHOME_SHA256_CLANG:-}" ] && { printf '%s' "$SANDHOME_SHA256_CLANG"; return 0; } ;;
        DENO)    [ -n "${SANDHOME_SHA256_DENO:-}" ] && { printf '%s' "$SANDHOME_SHA256_DENO"; return 0; } ;;
        DENO-*)  [ -n "${SANDHOME_SHA256_DENO:-}" ] && { printf '%s' "$SANDHOME_SHA256_DENO"; return 0; } ;;
        BUN)     [ -n "${SANDHOME_SHA256_BUN:-}" ] && { printf '%s' "$SANDHOME_SHA256_BUN"; return 0; } ;;
        BUN-*)   [ -n "${SANDHOME_SHA256_BUN:-}" ] && { printf '%s' "$SANDHOME_SHA256_BUN"; return 0; } ;;
        UV)      [ -n "${SANDHOME_SHA256_PYTHON:-}" ] && { printf '%s' "$SANDHOME_SHA256_PYTHON"; return 0; } ;;
        UV-*)    [ -n "${SANDHOME_SHA256_PYTHON:-}" ] && { printf '%s' "$SANDHOME_SHA256_PYTHON"; return 0; } ;;
    esac
    # # NOTE: THE BARE VALUE IS A DEFAULT AND NOT AN OVERRIDE, AND THE ORDER
    # IS THE WHOLE FIX. It used to be `${SANDHOME_SHA256:-$published}` in every
    # module, so a caller who set it to pin ONE download silently replaced the
    # digest go.dev publishes for a DIFFERENT one. Measured: with
    # SANDHOME_SHA256 set, the go module compared go.dev's tarball against the
    # caller's value and failed with a message naming the mirror. A weaker check
    # the caller set for something else had disabled a stronger one.
    if [ -n "$sh_pf_published" ]; then
        printf '%s' "$sh_pf_published"
        return 0
    fi
    if [ -n "${SANDHOME_SHA256:-}" ]; then
        printf '%s' "$SANDHOME_SHA256"
        return 0
    fi
    printf ''
}

# sh_pin_names -> every toolchain name a `SANDHOME_SHA256_<NAME>` pin answers to.
# Printed so tests/unit.sh can require one entry per module in tools/, which is
# what keeps the closed `case` above from going stale when a module is added.
sh_pin_names() { printf ' fd go jq node python ripgrep rust zig mold clang deno bun\n'; }

# sh_pin_from URL [NAME] [PUBLISHED] -> the NAME of the pin that answered for
# this URL, or nothing. The provenance line in the report names it, because a
# caller holding four pins needs to know which of them a given download was held
# to, and "the release" when the value came from SANDHOME_SHA256_RIPGREP is a
# claim that is false in the only direction that matters.
sh_pin_from() {
    sh_pfr_url=$1
    sh_pfr_name=${2:-}
    sh_pfr_published=${3:-}
    sh_pfr_pin=$(sh_pin_for "$sh_pfr_url" "$sh_pfr_name" "$sh_pfr_published")
    [ -n "$sh_pfr_pin" ] || return 0
    if [ -n "$sh_pfr_name" ]; then
        # # STOP: THE NAME IS CHECKED AGAINST sh_pin_names BEFORE IT BECOMES A
        # VARIABLE NAME, BECAUSE AN ARBITRARY STRING IS NOT A SAFE NAME TO eval.
        # `sh_pin_from "https://x/go.tar.gz" go` built `SANDHOME_SHA256_GO` and
        # read it, which was fine; the same call with a name that is not a
        # toolchain built a name no one had set and dash answered "Bad
        # substitution" from inside the eval. The closed list is the same one
        # sh_pin_for's `case` uses, so the two cannot disagree about what a name
        # is.
        case " $(sh_pin_names) " in
            *" $sh_pfr_name "*)
                sh_pfr_var="SANDHOME_SHA256_$(sh_upper "$sh_pfr_name")"
                # shellcheck disable=SC1090
                eval "sh_pfr_had=\${$sh_pfr_var:-}"
                if [ "$sh_pfr_had" = "$sh_pfr_pin" ]; then
                    printf '%s' "$sh_pfr_var"
                    return 0
                fi
                ;;
        esac
    fi
    # Not the toolchain-named pin: it came from an asset-named pin, the bare
    # value, or the publisher. Each is one more `case` over literals, and the
    # report reads whichever answers.
    sh_pfr_key=$(sh_pin_key "$sh_pfr_url")
    # Hyphen to underscore with the shell, not with sed: this library is loaded
    # on userlands that carry no sed, and a helper that reaches for one dies on
    # the machines the tool exists for.
    sh_pfr_under=''
    sh_pfr_rest=$sh_pfr_key
    while [ -n "$sh_pfr_rest" ]; do
        sh_pfr_c=${sh_pfr_rest%"${sh_pfr_rest#?}"}
        sh_pfr_rest=${sh_pfr_rest#?}
        if [ "$sh_pfr_c" = '-' ]; then
            sh_pfr_under="${sh_pfr_under}_"
        else
            sh_pfr_under="$sh_pfr_under$sh_pfr_c"
        fi
    done
    sh_pfr_var_asset="SANDHOME_SHA256_$sh_pfr_under"
    # # STOP: AN ASSET VAR IS ONLY READ WHEN IT IS A VALID IDENTIFIER. The key is
    # a FILE name, so it can carry a dot: `go.tar.gz` yields the key `GO.TAR`,
    # the underscored asset variable is `SANDHOME_SHA256_GO.TAR`, and
    # `eval "x=\${SANDHOME_SHA256_GO.TAR:-}"` is not a parameter expansion at
    # all - dash answers "Bad substitution" and the whole provenance lookup dies
    # on any URL whose asset name has more than one extension. The `case` below
    # is the same test the shell performs, written out, and the empty answer it
    # produces is correct: there is no variable by that name.
    case "$sh_pfr_var_asset" in
        *[!A-Za-z0-9_]*) sh_pfr_var_asset='' ;;
    esac
    if [ -n "$sh_pfr_var_asset" ]; then
        # shellcheck disable=SC1090
        eval "sh_pfr_had_asset=\${$sh_pfr_var_asset:-}"
        if [ "$sh_pfr_had_asset" = "$sh_pfr_pin" ]; then
            printf '%s' "$sh_pfr_var_asset"
            return 0
        fi
    fi
    if [ -n "${SANDHOME_SHA256:-}" ] && [ "$SANDHOME_SHA256" = "$sh_pfr_pin" ]; then
        printf 'SANDHOME_SHA256'
        return 0
    fi
    # # STOP: THE PUBLISHED CHECK COMES AFTER THE BARE ONE, OR A CALLER WHO SET
    # BOTH IS TOLD THE WRONG SOURCE. `sh_pin_for` ranks the bare default BELOW a
    # published digest, and `sh_pin_from` has to rank them the same way, or the
    # report names one and the resolver used the other - which is a check whose
    # provenance is false in the one direction that matters.
    if [ -n "$sh_pfr_published" ] && [ "$sh_pfr_published" = "$sh_pfr_pin" ]; then
        printf 'the published digest'
        return 0
    fi
    printf ''
}

# ------------------------------------------------- manifest shapes --
# Validate every field of a downloaded manifest by shape and drop the record
# if any one fails (issue #10, TcpQuality runTcpQuality-rootfs.sh shape): a
# non-empty name and a 64-char all-hex digest. The reference also validates an
# all-digit size; sandhome's manifests (go.dev JSON, nodejs.org SHASUMS256.txt)
# carry no size field, so that third validator would have no caller here and
# one was not written: a validator that exists only to be tested is a guard
# that cannot fail. Add one beside these if a module ever parses a size.
# The length is counted and the class is matched WITHOUT an interval
# quantifier: the reference's own PR #13 is titled 'make rootfs manifest
# parsing portable' because `{64}` is not portable across awks, and a
# validator written with one implementation's regex is itself the portability
# bug.
sh_is_nonempty() { [ -n "${1:-}" ]; }

sh_is_hex64() {
    sh_hx=${1:-}
    [ "${#sh_hx}" = 64 ] || return 1
    case "$sh_hx" in
        *[!0-9a-fA-F]*) return 1 ;;
        *) return 0 ;;
    esac
}

# sh_digest_matches ACTUAL EXPECTED_LIST -> 0 when ACTUAL equals any entry of
# EXPECTED_LIST. More than one accepted digest is legitimate (a re-release
# must not brick the install, issue #17 kejilion shape), so the list is
# space or comma separated and any entry may answer. md5 (32 hex) is refused
# by name: sandhome standardises on sha256 (issue #4).
sh_digest_matches() {
    sh_dm_actual=$1
    sh_dm_list=$(sh_split_on ',' "$2")
    for sh_dm_e in $sh_dm_list; do
        [ -n "$sh_dm_e" ] || continue
        if [ "$sh_dm_actual" = "$sh_dm_e" ]; then
            return 0
        fi
    done
    return 1
}

# sh_expected_wellformed EXPECTED_LIST -> 0 when every non-empty entry is a
# 64-char hex digest. A malformed pin is a caller bug and is refused loudly
# rather than compared and reported as a mirror mismatch.
sh_expected_wellformed() {
    sh_ew_list=$(sh_split_on ',' "${1:-}")
    sh_ew_any=0
    for sh_ew_e in $sh_ew_list; do
        [ -n "$sh_ew_e" ] || continue
        sh_ew_any=1
        if ! sh_is_hex64 "$sh_ew_e"; then
            case "$sh_ew_e" in
                *)
                    sh_ew_len=${#sh_ew_e}
                    if [ "$sh_ew_len" = 32 ]; then
                        case "$sh_ew_e" in
                            *[!0-9a-fA-F]*) : ;;
                            *) sh_fail "an expected digest is 32 hex chars, which is md5; sandhome standardises on sha256 and does not accept md5"; return 1 ;;
                        esac
                    fi
                    sh_fail "an expected digest is not a 64-char hex sha256 (got '$sh_ew_e'); refusing rather than fetching against it"
                    return 1
                    ;;
            esac
        fi
    done
    [ "$sh_ew_any" = 1 ]
}

# sh_fetch_verified URL DEST [EXPECTED_SHA256] -> fetch and, when a digest tool
# is present, prove the bytes. A missing digest tool is reported, not ignored:
# `SANDHOME_REQUIRE_DIGEST=1` turns that into a refusal.
sh_fetch_verified() {
    sh_fv_url=$1
    sh_fv_dest=$2
    # STOP: THE DIGEST TOOL IS RESOLVED BEFORE THE BYTES MOVE (issues #4, #5).
    # `SANDHOME_REQUIRE_DIGEST=1` used to refuse only AFTER the download had
    # run, so a machine with no sha256 tool paid the whole transfer and then
    # failed - the LemonBench shape, failing part-way through instead of
    # naming the prerequisite up front. One lookup here, before anything
    # expensive; the preflight discipline of issue #5, one line of it.
    if [ "${SANDHOME_REQUIRE_DIGEST:-0}" = 1 ] && [ -z "$(sh_sha256_which)" ]; then
        sh_fail "SANDHOME_REQUIRE_DIGEST is set and no sha256 tool is present; refusing $sh_fv_url before downloading it"
        return 1
    fi
    # # STOP: EVERY OPERAND IS BRACED, BECAUSE `set -u` IS A RUNTIME ABORT AND NOT
    # A LINT WARNING. Three shapes of this line were live at once. `X=the
    # release` with an unquoted value is word-split by dash into a command:
    # `dash -uc 'x=the release; echo "[$x]"'` prints "release: not found",
    # leaves x UNSET, and the next reader dies with "sh: 134: sh_fv_from:
    # parameter not set". Because `sh_step` is a printf to stderr, that
    # expansion failure EXITS THE PROCESS, so the caller's
    # `if ! sh_fetch_verified ...` never sees a status at all and the install
    # dies mid-run with no env.sh written. shellcheck does not flag it: it is a
    # dash runtime behaviour, so the guard has to be an EXECUTED clause.
    # Pinned in tests/unit.sh.
    sh_fv_expected=${3:-}
    [ -n "$sh_fv_expected" ] || sh_fv_expected=''
    # STOP: UNVERIFIED BYTES NEVER OCCUPY THE FINAL NAME (issues #4, #17).
    # sh_fetch used to write straight to DEST and sh_fetch_verified checked
    # afterwards, so a failed download sat at the real destination until a
    # caller noticed, and a retry could overwrite a file that had failed its
    # check (leitbogioro lib.sh order, inverted here). The download goes to a
    # sibling temp path; only verified bytes are renamed into place, and a
    # mismatch removes the temp file and returns non-zero.
    sh_fv_tmp="$sh_fv_dest.tmp.$$"
    rm -f "$sh_fv_tmp" 2>/dev/null
    if ! sh_fetch "$sh_fv_url" "$sh_fv_tmp"; then
        rm -f "$sh_fv_tmp" 2>/dev/null
        return 1
    fi
    if [ ! -s "$sh_fv_tmp" ]; then
        sh_fail "$sh_fv_url fetched nothing"
        rm -f "$sh_fv_tmp" 2>/dev/null
        return 1
    fi
    sh_fv_tool=$(sh_sha256_which)
    sh_fv_actual=$(sh_sha256 "$sh_fv_tmp")
    if [ -z "$sh_fv_actual" ]; then
        if [ "${SANDHOME_REQUIRE_DIGEST:-0}" = 1 ]; then
            sh_fail "no sha256 tool is present, and SANDHOME_REQUIRE_DIGEST is set; refusing $sh_fv_url"
            rm -f "$sh_fv_tmp" 2>/dev/null
            return 1
        fi
        sh_warn "no sha256 tool is present, so $sh_fv_url could not be verified"
        mv "$sh_fv_tmp" "$sh_fv_dest" 2>/dev/null || { rm -f "$sh_fv_tmp" 2>/dev/null; return 1; }
        return 0
    fi
    # # NOTE: THE REPORT NAMES THE TOOL THAT ANSWERED AND WHERE THE EXPECTED
    # DIGEST CAME FROM. Both were claimed by the documentation and neither was
    # true: the line said "matches the release digest" even when the value had
    # been pinned by the caller, and it never said which of sha256sum, sha256,
    # shasum, openssl, python3 or node produced the hash. A digest check whose
    # provenance is invisible is a check nobody can reproduce.
    #
    # # STOP: THE PROVENANCE IS THE PIN THAT ANSWERED, AND IT IS READ FROM THE
    # EXPECTED VALUE RATHER THAN GUESSED FROM WHICH VARIABLES ARE SET. A first
    # version said "SANDHOME_SHA256" whenever the bare variable was non-empty,
    # which is true for a run with four pins and false about every one of them:
    # the download was held to SANDHOME_SHA256_RIPGREP and the report named
    # SANDHOME_SHA256. A provenance that cannot be wrong is not a provenance.
    sh_fv_from='the release'
    sh_fv_pinned_by=$(sh_pin_from "$sh_fv_url" '' "$sh_fv_expected")
    if [ -n "$sh_fv_pinned_by" ]; then
        sh_fv_from="$sh_fv_pinned_by (pinned by the caller)"
    fi
    if [ -z "$sh_fv_expected" ]; then
        sh_step "sha256 $sh_fv_actual (taken with $sh_fv_tool; no digest to compare against)"
        mv "$sh_fv_tmp" "$sh_fv_dest" 2>/dev/null || { rm -f "$sh_fv_tmp" 2>/dev/null; return 1; }
        return 0
    fi
    # A malformed pin is refused by name before any comparison, so a typo
    # never reads as a mirror truncating a download.
    if ! sh_expected_wellformed "$sh_fv_expected"; then
        rm -f "$sh_fv_tmp" 2>/dev/null
        return 1
    fi
    if ! sh_digest_matches "$sh_fv_actual" "$sh_fv_expected"; then
        sh_fail "$sh_fv_url does not match the expected sha256 (got $sh_fv_actual with $sh_fv_tool, wanted $sh_fv_expected)"
        rm -f "$sh_fv_tmp" 2>/dev/null
        return 1
    fi
    sh_step "sha256 matches the value from $sh_fv_from (taken with $sh_fv_tool)"
    mv "$sh_fv_tmp" "$sh_fv_dest" 2>/dev/null || { rm -f "$sh_fv_tmp" 2>/dev/null; return 1; }
    return 0
}

# ------------------------------------------------------- the file-size limit --
# A sandbox can cap the size of any one file a process writes (RLIMIT_FSIZE).
# Measured on this host: a 2GB GitHub release asset stopped at exactly
# 1,000,000,000 bytes, curl died with `File size limit exceeded`, and the same
# transfer split into ranges landed whole. Nothing inside the sandbox can raise
# the limit (the hard limit is fixed too), and resuming appends to a file that is
# already at the cap, so a single file larger than the limit is unreachable by
# construction. The answer is to never make one: fetch ranges into part files
# that each stay under the limit, and read them back as a stream.

# sh_fsize_cap_bytes -> the soft RLIMIT_FSIZE in bytes, or 0 when unlimited.
# POSIX defines `ulimit -f` in 512-byte blocks, and dash reports it that way;
# bash reports the same limit in 1024-byte blocks, so a bash caller gets a
# conservative (smaller) answer rather than a wrong one.
sh_fsize_cap_bytes() {
    sh_fsc_v=$(ulimit -f 2>/dev/null) || { printf '0'; return 0; }
    case "$sh_fsc_v" in
        ''|*[!0-9]*) printf '0'; return 0 ;;
    esac
    if [ "$sh_fsc_v" -ge 2147483648 ]; then
        printf '0'
        return 0
    fi
    printf '%s' "$((sh_fsc_v * 512))"
}

# sh_fetch_chunk_bytes -> the range size the sharded fetcher uses: the caller's
# SANDHOME_FETCH_CHUNK_MB (default 256), capped at three quarters of the
# file-size limit so neither a part nor the digest's own read touches the cap.
: "${SANDHOME_FETCH_CHUNK_MB:=256}"
sh_fetch_chunk_bytes() {
    sh_fch_n=${SANDHOME_FETCH_CHUNK_MB:-256}
    case "$sh_fch_n" in
        ''|*[!0-9]*) sh_fch_n=256 ;;
    esac
    sh_fch_chunk=$((sh_fch_n * 1048576))
    [ "$sh_fch_chunk" -gt 0 ] || sh_fch_chunk=268435456
    sh_fch_cap=$(sh_fsize_cap_bytes)
    if [ "$sh_fch_cap" -gt 0 ]; then
        sh_fch_lim=$((sh_fch_cap / 4 * 3))
        [ "$sh_fch_lim" -gt 0 ] || sh_fch_lim=65536
        if [ "$sh_fch_chunk" -gt "$sh_fch_lim" ]; then
            sh_fch_chunk=$sh_fch_lim
        fi
    fi
    printf '%s' "$sh_fch_chunk"
}

# sh_fetch_ranges TOTAL CHUNK -> "INDEX START END" per range, inclusive. The
# index is zero-padded, so `part.*` sorts in order even past a thousand parts: a
# plain %03d put part.1000 before part.999 in a shell glob.
sh_fetch_ranges() {
    sh_frng_total=$1
    sh_frng_chunk=$2
    case "$sh_frng_total" in ''|*[!0-9]*) return 1 ;; esac
    case "$sh_frng_chunk" in ''|*[!0-9]*) return 1 ;; esac
    [ "$sh_frng_chunk" -gt 0 ] || return 1
    sh_frng_i=0
    sh_frng_start=0
    while [ "$sh_frng_start" -lt "$sh_frng_total" ]; do
        sh_frng_end=$((sh_frng_start + sh_frng_chunk - 1))
        if [ "$sh_frng_end" -ge "$sh_frng_total" ]; then
            sh_frng_end=$((sh_frng_total - 1))
        fi
        printf '%06d %s %s\n' "$sh_frng_i" "$sh_frng_start" "$sh_frng_end"
        sh_frng_start=$((sh_frng_end + 1))
        sh_frng_i=$((sh_frng_i + 1))
    done
    return 0
}

# sh_url_total_from_headers -> the total byte size from a header block, or
# nothing. Content-Range is preferred over Content-Length, because the length on
# a ranged reply is the length of the RANGE, not of the file; and a later
# Content-Length overwrites an earlier one, because a redirect chain has one
# Content-Length per response and the LAST is the file (the first is often the
# 302's zero). Measured: a first version kept the first Content-Length and read a
# redirect's `0` as the size of a 2GB asset.
sh_url_total_from_headers() {
    sh_uth_cr=$(printf '\r')
    sh_uth_total=''
    sh_uth_saw_range=0
    while IFS= read -r sh_uth_l; do
        sh_uth_l=${sh_uth_l%"$sh_uth_cr"}
        case "$sh_uth_l" in
            HTTP/*)
                # A new response in the chain resets the answer, so the size
                # comes from the LAST response and a final chunked reply leaves
                # it empty rather than inheriting a redirect's zero.
                sh_uth_total=''
                sh_uth_saw_range=0
                ;;
            [Cc]ontent-[Rr]ange:*)
                sh_uth_t=$(sh_trim "${sh_uth_l##*/}")
                case "$sh_uth_t" in
                    ''|*[!0-9]*) : ;;
                    *) sh_uth_total=$sh_uth_t; sh_uth_saw_range=1 ;;
                esac
                ;;
            [Cc]ontent-[Ll]ength:*)
                if [ "$sh_uth_saw_range" = 0 ]; then
                    sh_uth_v=$(sh_trim "${sh_uth_l#*:}")
                    case "$sh_uth_v" in
                        ''|*[!0-9]*) : ;;
                        *) sh_uth_total=$sh_uth_v ;;
                    esac
                fi
                ;;
        esac
    done
    printf '%s' "$sh_uth_total"
}

# sh_url_content_length URL -> the total byte size, or nothing.
#
# TWO METHODS, IN THIS ORDER, BECAUSE HEAD ALONE IS NOT ENOUGH.
#
# A HEAD is asked first: it is cheap, and a server that ignores ranges would
# answer a range request with the WHOLE file, so measuring a 2GB download that
# way would download it. The reason a range cannot be the only method is that
# "every release host here answers a HEAD" was measured on one host behind no
# proxy, and it does not hold generally. Measured here, through the HTTP
# CONNECT proxy this sandbox egresses through:
#
#   $ curl -fsSLI -D - -o /dev/null .../npm-12.1.0.tgz | grep -i content-length
#   (nothing: an "HTTP/1.1 200 Connection Established" preamble and an
#    "HTTP/2 200" with no length)
#   $ curl -fsSL -r 0-0 -D - -o /dev/null .../npm-12.1.0.tgz | grep -i content-range
#   content-range: bytes 0-0/3053355
#
# The size was there all along, behind a method the probe did not use. Because
# sh_fetch_stream treats "no Content-Length" as "fetch it in one piece", the
# sharding this whole change exists for was silently disabled on any host whose
# egress adds that preamble, and on a host with a pinned RLIMIT_FSIZE that one
# piece then died with SIGXFSZ at the cap. So when HEAD says nothing, a ONE-BYTE
# range is asked, and its Content-Range carries the total.
#
# The byte is discarded and the request is bounded by --max-time, so the cost of
# the fallback is one byte, never the file. A server that ignores the range
# answers 200 with a Content-Length for the whole file, which this parser
# accepts as the total, and the sharding path then downloads that file in
# pieces and checks every piece's byte count, so an ignoring server is caught
# rather than silently mis-assembled.
sh_url_content_length() {
    sh_ucl_url=$1
    sh_have curl || { printf ''; return 0; }
    sh_ucl_total=$(curl -fsSLI -D - -o /dev/null --max-time 30 "$sh_ucl_url" 2>/dev/null |
        sh_url_total_from_headers)
    case "$sh_ucl_total" in
        ''|*[!0-9]*) ;;
        *) printf '%s' "$sh_ucl_total"; return 0 ;;
    esac
    sh_ucl_total=$(curl -fsSL -r 0-0 -D - -o /dev/null --max-time 30 "$sh_ucl_url" 2>/dev/null |
        sh_url_total_from_headers)
    case "$sh_ucl_total" in
        ''|*[!0-9]*) printf '' ;;
        *) printf '%s' "$sh_ucl_total" ;;
    esac
    return 0
}

# sh_fetch_stream URL DIR -> fetch URL into DIR as part.000000, sharding when the
# total is known and exceeds the chunk. A small download is one part.000000, so
# every caller reads a stream the same way. The URL's suffix is recorded in
# DIR/.suffix (a dotfile, so `part.*` never mistakes it for data) for the
# unpacker, which cannot recover an archive's format from a part name.
sh_fetch_stream() {
    sh_fs_url=$1
    sh_fs_dir=$2
    mkdir -p "$sh_fs_dir" 2>/dev/null || { sh_fail "cannot create the fetch directory $sh_fs_dir"; return 1; }
    sh_fs_name=${sh_fs_url%%\#*}
    sh_fs_name=${sh_fs_name%%\?*}
    sh_fs_name=${sh_fs_name##*/}
    case "$sh_fs_name" in
        *.tar.gz)  sh_fs_suffix='tar.gz' ;;
        *.tgz)     sh_fs_suffix='tgz' ;;
        *.tar.xz)  sh_fs_suffix='tar.xz' ;;
        *.txz)     sh_fs_suffix='txz' ;;
        *.tar.zst) sh_fs_suffix='tar.zst' ;;
        *.tzst)    sh_fs_suffix='tzst' ;;
        *.tar.bz2) sh_fs_suffix='tar.bz2' ;;
        *.tbz2)    sh_fs_suffix='tbz2' ;;
        *.tbz)     sh_fs_suffix='tbz' ;;
        *.tar)     sh_fs_suffix='tar' ;;
        *.zip)     sh_fs_suffix='zip' ;;
        *.gz)      sh_fs_suffix='gz' ;;
        *.xz)      sh_fs_suffix='xz' ;;
        *)         sh_fs_suffix='' ;;
    esac
    printf '%s\n' "$sh_fs_suffix" > "$sh_fs_dir/.suffix" 2>/dev/null || true
    rm -f "$sh_fs_dir"/part.* 2>/dev/null
    sh_fs_total=$(sh_url_content_length "$sh_fs_url")
    case "$sh_fs_total" in ''|*[!0-9]*) sh_fs_total='' ;; esac
    sh_fs_chunk=$(sh_fetch_chunk_bytes)
    if [ -z "$sh_fs_total" ]; then
        sh_warn "no Content-Length for $sh_fs_url; fetching it in one piece"
        sh_fetch "$sh_fs_url" "$sh_fs_dir/part.000000" || { rm -f "$sh_fs_dir"/part.* 2>/dev/null; return 1; }
        return 0
    fi
    if [ "$sh_fs_total" -le "$sh_fs_chunk" ]; then
        sh_fetch "$sh_fs_url" "$sh_fs_dir/part.000000" || { rm -f "$sh_fs_dir"/part.* 2>/dev/null; return 1; }
        return 0
    fi
    if ! sh_have curl; then
        sh_warn "a ${sh_fs_total}-byte download needs ranged fetching, and only curl provides it; trying one piece"
        sh_fetch "$sh_fs_url" "$sh_fs_dir/part.000000" || { rm -f "$sh_fs_dir"/part.* 2>/dev/null; return 1; }
        return 0
    fi
    sh_fs_ranges="$sh_fs_dir/.ranges"
    if ! sh_fetch_ranges "$sh_fs_total" "$sh_fs_chunk" > "$sh_fs_ranges"; then
        rm -f "$sh_fs_ranges" 2>/dev/null
        return 1
    fi
    sh_fs_parts=$(( (sh_fs_total + sh_fs_chunk - 1) / sh_fs_chunk ))
    sh_step "fetching $sh_fs_total bytes from $sh_fs_url in $sh_fs_parts ranges"
    while read -r sh_fs_i sh_fs_start sh_fs_end; do
        [ -n "$sh_fs_i" ] || continue
        sh_fs_part="$sh_fs_dir/part.$sh_fs_i"
        if ! curl -fsSL --retry 3 --retry-delay 2 -r "$sh_fs_start-$sh_fs_end" \
                -o "$sh_fs_part" "$sh_fs_url" 2>/dev/null; then
            sh_warn "range $sh_fs_start-$sh_fs_end of $sh_fs_url did not download"
            rm -f "$sh_fs_ranges" "$sh_fs_dir"/part.* 2>/dev/null
            return 1
        fi
        sh_fs_want=$((sh_fs_end - sh_fs_start + 1))
        sh_fs_got=$(sh_file_bytes "$sh_fs_part")
        if [ "$sh_fs_got" != "$sh_fs_want" ]; then
            sh_warn "range $sh_fs_start-$sh_fs_end of $sh_fs_url returned $sh_fs_got bytes, not $sh_fs_want"
            rm -f "$sh_fs_ranges" "$sh_fs_dir"/part.* 2>/dev/null
            return 1
        fi
    done < "$sh_fs_ranges"
    rm -f "$sh_fs_ranges" 2>/dev/null
    return 0
}

# sh_stream_cat DIR -> the concatenated bytes of every part, in order.
sh_stream_cat() {
    cat "$1"/part.* 2>/dev/null
}

# sh_stream_size DIR -> the total bytes across the parts.
sh_stream_size() {
    sh_ssz_total=0
    for sh_ssz_p in "$1"/part.*; do
        [ -e "$sh_ssz_p" ] || continue
        sh_ssz_n=$(sh_file_bytes "$sh_ssz_p")
        case "$sh_ssz_n" in ''|*[!0-9]*) continue ;; esac
        sh_ssz_total=$((sh_ssz_total + sh_ssz_n))
    done
    printf '%s' "$sh_ssz_total"
}

# sh_stream_sha256 DIR -> the digest of the concatenated stream, or nothing.
sh_stream_sha256() {
    sh_ssd_dir=$1
    if sh_have sha256sum; then sh_stream_cat "$sh_ssd_dir" | sh_first_word sha256sum; return 0; fi
    if sh_have sha256;    then sh_stream_cat "$sh_ssd_dir" | sha256 -q; return 0; fi
    if sh_have shasum;    then sh_stream_cat "$sh_ssd_dir" | sh_first_word shasum -a 256; return 0; fi
    if sh_have openssl;   then sh_stream_cat "$sh_ssd_dir" | sh_first_word openssl dgst -sha256 -r; return 0; fi
    if sh_have python3; then
        sh_stream_cat "$sh_ssd_dir" | python3 -c 'import hashlib,sys;h=hashlib.sha256()
for b in iter(lambda: sys.stdin.buffer.read(1048576), b""): h.update(b)
print(h.hexdigest())'
        return 0
    fi
    if sh_have node; then
        sh_stream_cat "$sh_ssd_dir" | node -e 'const c=require("crypto"),h=c.createHash("sha256");process.stdin.on("data",d=>h.update(d)).on("end",()=>process.stdout.write(h.digest("hex")))'
        return 0
    fi
    printf ''
}

# sh_stream_rm DIR -> discard a fetched stream.
sh_stream_rm() { rm -rf "$1" 2>/dev/null; }

# sh_fetch_verified_stream URL DIR [EXPECTED] -> sh_fetch_stream then prove the
# bytes, the streaming twin of sh_fetch_verified. The digest is taken over the
# concatenation in one pass, so a >1GB archive is never a file on disk.
sh_fetch_verified_stream() {
    sh_fvs_url=$1
    sh_fvs_dir=$2
    if [ "${SANDHOME_REQUIRE_DIGEST:-0}" = 1 ] && [ -z "$(sh_sha256_stream_which)" ]; then
        sh_fail "SANDHOME_REQUIRE_DIGEST is set and no sha256 tool can read a stream; refusing $sh_fvs_url"
        return 1
    fi
    sh_fvs_expected=${3:-}
    [ -n "$sh_fvs_expected" ] || sh_fvs_expected=''
    if ! sh_fetch_stream "$sh_fvs_url" "$sh_fvs_dir"; then
        return 1
    fi
    sh_fvs_actual=$(sh_stream_sha256 "$sh_fvs_dir")
    if [ -z "$sh_fvs_actual" ]; then
        if [ "${SANDHOME_REQUIRE_DIGEST:-0}" = 1 ]; then
            sh_fail "no sha256 tool can read a stream, and SANDHOME_REQUIRE_DIGEST is set; refusing $sh_fvs_url"
            sh_stream_rm "$sh_fvs_dir"
            return 1
        fi
        sh_warn "no sha256 tool can read a stream, so $sh_fvs_url could not be verified"
        return 0
    fi
    if [ -z "$sh_fvs_expected" ]; then
        sh_step "sha256 $sh_fvs_actual (taken over the stream; no digest to compare against)"
        return 0
    fi
    if ! sh_expected_wellformed "$sh_fvs_expected"; then
        sh_stream_rm "$sh_fvs_dir"
        return 1
    fi
    if ! sh_digest_matches "$sh_fvs_actual" "$sh_fvs_expected"; then
        sh_fail "$sh_fvs_url does not match the expected sha256 (got $sh_fvs_actual over the stream, wanted $sh_fvs_expected)"
        sh_stream_rm "$sh_fvs_dir"
        return 1
    fi
    sh_step "sha256 matches the expected value (taken over the stream)"
    return 0
}

# sh_stream_untar DIR DEST -> unpack the stream without ever writing the archive
# as one file. The format is the .suffix sh_fetch_stream recorded; a .zip cannot
# be streamed (its directory sits at the end) and is refused by name.
sh_stream_untar() {
    sh_sut_dir=$1
    sh_sut_dest=$2
    mkdir -p "$sh_sut_dest" 2>/dev/null || return 1
    sh_sut_suffix=''
    if [ -r "$sh_sut_dir/.suffix" ]; then
        sh_sut_suffix=$(sh_first_line cat "$sh_sut_dir/.suffix")
    fi
    case "$sh_sut_suffix" in
        zip)
            # # STOP: A ZIP IS MATERIALISED ONLY WHEN IT FITS UNDER THE FILE-SIZE
            # LIMIT, BECAUSE ITS CENTRAL DIRECTORY SITS AT THE END AND CANNOT BE
            # READ AS A STREAM. Deno, Bun and every other small zip still unpack;
            # a >1GB zip is refused by name rather than half-read.
            sh_sut_cap=$(sh_fsize_cap_bytes)
            sh_sut_size=$(sh_stream_size "$sh_sut_dir")
            if [ "$sh_sut_cap" -gt 0 ] && [ "$sh_sut_size" -gt "$sh_sut_cap" ]; then
                sh_warn "a ${sh_sut_size}-byte zip cannot be unpacked here: its directory is at the end, and the file-size limit is ${sh_sut_cap} bytes"
                return 1
            fi
            sh_sut_zip="$sh_sut_dir/.archive.zip"
            sh_stream_cat "$sh_sut_dir" > "$sh_sut_zip" || return 1
            if sh_have unzip; then
                unzip -q -o "$sh_sut_zip" -d "$sh_sut_dest"
                sh_sut_rc=$?
            elif sh_have python3; then
                # # STOP: THE ARCHIVE'S MODE IS RESTORED, NOT python3's DEFAULT.
                # zipfile.extractall writes every entry 0644 and ignores
                # external_attr; unzip honours the same field. So the two
                # extractors disagree, and the disagreement is invisible until a
                # toolchain is a zip holding one 0755 binary: deno and bun are
                # exactly that. Measured here, on the real deno-x86_64-unknown-
                # linux-gnu.zip:
                #   external_attr >> 16 == 0o100755, extractall produced 0644,
                #   and chmod +x on the same bytes ran `deno 2.9.7`.
                # The module's own `[ -x $root/deno ]` then reported "the deno
                # archive did not put deno at .../deno" about a download that had
                # arrived complete and verified. Only a host with a python3 and no
                # unzip ever saw it, which is why it survived a passing suite.
                # The mode comes from the archive when it carries one; entries
                # made by a tool that records no Unix mode keep extractall's
                # default, so this cannot make a data file executable.
                python3 -c 'import os,sys,zipfile
z=zipfile.ZipFile(sys.argv[1])
for i in z.infolist():
    p=z.extract(i, sys.argv[2])
    m=(i.external_attr>>16)&0xFFFF
    if m & 0o7777:
        os.chmod(p, m & 0o7777)' "$sh_sut_zip" "$sh_sut_dest"
                sh_sut_rc=$?
            else
                sh_warn 'a .zip arrived and neither unzip nor python3 can open it'
                sh_sut_rc=1
            fi
            rm -f "$sh_sut_zip" 2>/dev/null
            return $sh_sut_rc ;;
        tar.gz|tgz|gz)
            sh_stream_cat "$sh_sut_dir" | tar -xzf - -C "$sh_sut_dest" ;;
        tar.xz|txz|xz)
            # # STOP: xz IS GUARDED LIKE bzip2 AND zstd, AND FALLS BACK TO python3.
            # `tar -xJf` shells out to a decompressor that may simply not be
            # there, and the tree's rule 4 is that a bootstrap installing the
            # missing tools cannot require one first. The gap was measured on a
            # host with python3 and no xz at all, and it is the format Rust, Zig
            # and LLVM all ship:
            #   tar (grandchild): xz: Cannot exec: No such file or directory
            #   sandhome: [-] toolchain zig could not be installed
            # after the download had already matched Zig's published digest.
            if sh_have xz; then
                sh_stream_cat "$sh_sut_dir" | tar -xJf - -C "$sh_sut_dest"
            elif sh_have python3; then
                sh_sut_xz="$sh_sut_dir/.archive.tar.xz"
                sh_stream_cat "$sh_sut_dir" > "$sh_sut_xz" || return 1
                python3 -c 'import lzma,sys,tarfile
with lzma.open(sys.argv[1],"rb") as z:
    with tarfile.open(fileobj=z,mode="r|") as t:
        t.extractall(sys.argv[2])' "$sh_sut_xz" "$sh_sut_dest"
                sh_sut_rc=$?
                rm -f "$sh_sut_xz" 2>/dev/null
                return $sh_sut_rc
            else
                sh_warn 'an xz stream arrived and neither xz nor python3 can read it'
                return 1
            fi ;;
        tar.bz2|tbz2|tbz)
            if sh_have bzip2; then
                sh_stream_cat "$sh_sut_dir" | tar -xjf - -C "$sh_sut_dest"
            else
                sh_warn 'a bzip2 stream arrived and no bzip2 is present'
                return 1
            fi ;;
        tar.zst|tzst)
            if sh_have zstd; then
                sh_stream_cat "$sh_sut_dir" | zstd -dc | tar -xf - -C "$sh_sut_dest"
            else
                sh_warn 'a zstd stream arrived and no zstd is present'
                return 1
            fi ;;
        tar|'')
            sh_stream_cat "$sh_sut_dir" | tar -xf - -C "$sh_sut_dest" ;;
        *)
            sh_warn "cannot pick a decompressor for the stream suffix '$sh_sut_suffix'"
            return 1 ;;
    esac
}

# sh_untar TARBALL DEST -> unpack .tar.gz, .tgz, .tar.xz, .txz, .tar.zst or .zip
# by reading the file, not the URL. A tar that cannot read the compression is
# reported rather than half-unpacking.
sh_untar() {
    sh_ut_file=$1
    sh_ut_dest=$2
    mkdir -p "$sh_ut_dest" 2>/dev/null || return 1
    case "$sh_ut_file" in
        *.zip)
            if sh_have unzip; then
                unzip -q -o "$sh_ut_file" -d "$sh_ut_dest"
                return $?
            fi
            if sh_have python3; then
                python3 -c 'import os,sys,zipfile
z=zipfile.ZipFile(sys.argv[1])
for i in z.infolist():
    p=z.extract(i, sys.argv[2])
    m=(i.external_attr>>16)&0xFFFF
    if m & 0o7777:
        os.chmod(p, m & 0o7777)' "$sh_ut_file" "$sh_ut_dest"
                return $?
            fi
            sh_warn 'a .zip arrived and neither unzip nor python3 can open it'
            return 1
            ;;
    esac
    sh_ut_flags=''
    case "$sh_ut_file" in
        *.tar.gz|*.tgz) sh_ut_flags='-xzf' ;;
        *.tar.xz|*.txz)
            # The same guard the streaming unpacker carries, for the same
            # measured reason: a host with python3 and no xz stopped here with
            # "xz: Cannot exec" on an archive that had already been verified.
            if sh_have xz; then
                sh_ut_flags='-xJf'
            elif sh_have python3; then
                python3 -c 'import lzma,sys,tarfile
with lzma.open(sys.argv[1],"rb") as z:
    with tarfile.open(fileobj=z,mode="r|") as t:
        t.extractall(sys.argv[2])' "$sh_ut_file" "$sh_ut_dest"
                return $?
            else
                sh_warn 'an xz tarball arrived and neither xz nor python3 can read it'
                return 1
            fi ;;
        *.tar.zst|*.tzst)
            if sh_have zstd; then
                sh_ut_flags='--zstd -xvf'
            else
                sh_warn 'a zstd tarball arrived and no zstd is present'
                return 1
            fi
            ;;
        *.tar.bz2|*.tbz|*.tbz2)
            if sh_have bzip2; then
                sh_ut_flags='-xjf'
            else
                sh_warn 'a bzip2 tarball arrived and no bzip2 is present'
                return 1
            fi
            ;;
        *.tar) sh_ut_flags='-xf' ;;
        *)
            sh_ut_flags='-xf'
            ;;
    esac
    # shellcheck disable=SC2086
    tar $sh_ut_flags "$sh_ut_file" -C "$sh_ut_dest"
    return $?
}

# sh_fetch_unpack URL DEST_DIR [EXPECTED] [NAME] -> download to the home staging
# area, unpack, and answer the one top-level directory the archive made in
# MODULE_UNPACK_DIR. A tarball that makes several top-level entries is reported,
# because guessing which one is the toolchain is how a wrong tree gets moved
# into place. EXPECTED is a publisher digest used when the caller holds one and
# no named pin resolved; NAME lets a toolchain pin (SANDHOME_SHA256_<NAME>) rank
# above it, exactly as sh_pin_for's order requires.
#
# The fetch is SHARDED AND THE UNPACK IS STREAMED (sh_fetch_verified_stream,
# sh_stream_untar), so a >1GB archive is never written as one file. The zip
# branch materialises the archive first, because a zip's directory is at the
# end; that is refused above the file-size limit.
sh_fetch_unpack() {
    sh_fu_url=$1
    sh_fu_dest=$2
    sh_fu_expected=${3:-}
    [ -n "$sh_fu_expected" ] || sh_fu_expected=''
    sh_fu_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_fu_stage" 2>/dev/null || return 1
    sh_fu_tmp="$sh_fu_stage/.fetch.$$"
    rm -rf "$sh_fu_tmp" 2>/dev/null
    mkdir -p "$sh_fu_tmp/parts" 2>/dev/null || return 1
    if ! sh_fetch_verified_stream "$sh_fu_url" "$sh_fu_tmp/parts" "$(sh_pin_for "$sh_fu_url" "${4:-}" "$sh_fu_expected")"; then
        rm -rf "$sh_fu_tmp" 2>/dev/null
        return 1
    fi
    sh_fu_out="$sh_fu_tmp/out"
    if ! sh_stream_untar "$sh_fu_tmp/parts" "$sh_fu_out"; then
        rm -rf "$sh_fu_tmp" 2>/dev/null
        return 1
    fi
    # Count the top-level entries without `ls | wc`.
    sh_fu_n=0
    sh_fu_one=''
    for sh_fu_e in "$sh_fu_out"/* "$sh_fu_out"/.[!.]*; do
        [ -e "$sh_fu_e" ] || continue
        sh_fu_n=$((sh_fu_n + 1))
        sh_fu_one=$sh_fu_e
    done
    if [ "$sh_fu_n" -eq 0 ]; then
        sh_warn "the archive from $sh_fu_url unpacked nothing"
        rm -rf "$sh_fu_tmp" 2>/dev/null
        return 1
    fi
    # The parent of DEST without dirname, which a minimal userland lacks.
    case "$sh_fu_dest" in
        */*) mkdir -p "${sh_fu_dest%/*}" 2>/dev/null || true ;;
    esac
    if [ "$sh_fu_n" -eq 1 ] && [ -d "$sh_fu_one" ]; then
        rm -rf "$sh_fu_dest" 2>/dev/null
        mv "$sh_fu_one" "$sh_fu_dest" || { rm -rf "$sh_fu_tmp" 2>/dev/null; return 1; }
    else
        rm -rf "$sh_fu_dest" 2>/dev/null
        mv "$sh_fu_out" "$sh_fu_dest" || { rm -rf "$sh_fu_tmp" 2>/dev/null; return 1; }
    fi
    rm -rf "$sh_fu_tmp" 2>/dev/null
    return 0
}
