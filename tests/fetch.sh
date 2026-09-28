#!/bin/sh
# tests/fetch.sh - the sharded/streaming fetch, driven end to end without a
# network. A local `curl` function stands in for the server so the real range
# arithmetic, part naming, size check, stream digest and stream unpack all run.
#
# NOTE: THE SERVER IS A FUNCTION, NOT A LISTENING SOCKET. This sandbox denies
# bind(), so a local http.server cannot start; shadowing curl exercises the same
# code path with no socket and no dependency on a network stack.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space fetch; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_SELF=fetchtest
export SH_SELF

if ! command -v sha256sum >/dev/null 2>&1; then
    echo 'fetch: no sha256sum' >&2
    exit 2
fi

# The real sh_have is `command -v`, so an override below can delegate to that
# directly instead of to sh_have itself, which would recurse until the shell
# died. The xz section uses it to answer for every tool except the xz drivers.
_sh_real_have() { command -v "$1" >/dev/null 2>&1; }

t_begin fetch

work=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-fetch.XXXXXX")
trap 'rm -rf "$work"' EXIT
SH_HOME_TMP="$work/home-tmp"
export SH_HOME_TMP
mkdir -p "$work/srv" "$SH_HOME_TMP"

# Fixtures: a 3MB blob and a tar.gz of small files.
head -c 3145728 /dev/urandom > "$work/srv/blob.bin"
mkdir -p "$work/src/sub"
printf 'stream unpack\n' > "$work/src/sub/a.txt"
head -c 2097152 /dev/urandom > "$work/src/sub/big.bin"
tar -czf "$work/srv/arch.tgz" -C "$work/src" .
# An .xz fixture, for the decompressor gap below. python3's lzma module reads
# and writes xz, so the fixture is buildable on a host that has no `xz` binary,
# which is exactly the host the gap is about.
if command -v xz >/dev/null 2>&1; then
    tar -cJf "$work/srv/arch.tar.xz" -C "$work/src" . 2>/dev/null || true
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import lzma' 2>/dev/null; then
    ( cd "$work/src" && ARCHXZ="$work/srv/arch.tar.xz" python3 -c 'import lzma,os,tarfile
with lzma.open(os.environ["ARCHXZ"],"wb",format=lzma.FORMAT_XZ) as z:
    with tarfile.open(fileobj=z,mode="w|") as t:
        for r,ds,fs in os.walk("."):
            for f in fs:
                p=os.path.join(r,f); t.add(p,arcname=os.path.relpath(p,"."))' ) 2>/dev/null || true
fi
mkdir -p "$work/zipsrc"
printf 'zip payload\n' > "$work/zipsrc/z.txt"
head -c 1200000 /dev/urandom > "$work/zipsrc/z.bin"
# An EXECUTABLE entry, because a zip carries a Unix mode and the two extractors
# do not agree about it. Deno, Bun and every other single-binary release is a
# zip whose payload is 0755, so a fixture made only of data files cannot catch an
# extractor that drops the bit: the tool unpacks, the file lands 0644, and the
# module's own `[ -x ]` check then refuses a download that was perfect.
printf '#!/bin/sh\necho zipped-executable\n' > "$work/zipsrc/zrun.sh"
chmod 755 "$work/zipsrc/zrun.sh"
if command -v zip >/dev/null 2>&1; then
    ( cd "$work/zipsrc" && zip -q -r "$work/srv/arch.zip" . ) 2>/dev/null || true
elif command -v python3 >/dev/null 2>&1; then
    ( cd "$work/zipsrc" && ZOUT="$work/srv/arch.zip" python3 -c 'import zipfile,os
z=zipfile.ZipFile(os.environ["ZOUT"],"w",zipfile.ZIP_DEFLATED)
for r,d,fs in os.walk("."):
    for f in fs:
        p=os.path.join(r,f); z.write(p,os.path.relpath(p,"."))' ) 2>/dev/null || true
fi

# # STOP: THE STUB IS a curl THAT SERVES RANGES FROM $work/srv. It answers
# --version (sh_downloader_ok probes for it), -I (HEAD, with Content-Length),
# -r a-b (206 with the requested slice), and a plain GET. The URL's basename
# names the file, so one stub serves several fixtures.
curl() {
    sh_t_o=''; sh_t_range=''; sh_t_url=''; sh_t_head=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) printf 'curl 8.fake\n'; return 0 ;;
            -o) sh_t_o=$2; shift 2 ;;
            -r) sh_t_range=$2; shift 2 ;;
            -D) shift 2 ;;
            --retry|--retry-delay|--max-time|--connect-timeout|--doh-url) shift 2 ;;
            -*) case "$1" in *I*) sh_t_head=1 ;; esac; shift ;;
            *) sh_t_url=$1; shift ;;
        esac
    done
    sh_t_path="$work/srv/${sh_t_url##*/}"
    [ -r "$sh_t_path" ] || return 22
    if [ "$sh_t_head" = 1 ]; then
        # A redirect contributes its own Content-Length first; the real one is
        # last, and the parser must take the last.
        printf 'HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n'
        printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$(wc -c < "$sh_t_path")"
        return 0
    fi
    if [ -n "$sh_t_range" ]; then
        sh_t_s=${sh_t_range%%-*}; sh_t_e=${sh_t_range#*-}
        tail -c "+$((sh_t_s + 1))" "$sh_t_path" | head -c "$((sh_t_e - sh_t_s + 1))" > "$sh_t_o"
        return 0
    fi
    cat "$sh_t_path" > "$sh_t_o"
    return 0
}

SANDHOME_FETCH_CHUNK_MB=1
export SANDHOME_FETCH_CHUNK_MB

st=$(sh_url_content_length http://x/blob.bin)
t_is "$st" "$(wc -c < "$work/srv/blob.bin")" 'the size is read from the final Content-Length of a redirect chain'

d="$work/stream"
if sh_fetch_stream http://x/blob.bin "$d" >/dev/null 2>&1; then
    t_ok 0 'a 3MB fetch with a 1MB chunk succeeds'
else
    t_ok 1 'a 3MB fetch with a 1MB chunk succeeds'
fi
n=0
for p in "$d"/part.*; do [ -e "$p" ] || continue; n=$((n + 1)); done
t_is "$n" 3 'the fetch is split into three ranges'
t_is "$(sh_stream_size "$d")" "$(wc -c < "$work/srv/blob.bin")" 'the parts reassemble to the full size'
t_is "$(sh_stream_sha256 "$d")" "$(sha256sum "$work/srv/blob.bin" | cut -d' ' -f1)" 'the stream digest matches the file digest'
t_is "$(sh_stream_cat "$d" | wc -c)" "$(wc -c < "$work/srv/blob.bin")" 'sh_stream_cat yields every byte once'

want=$(sha256sum "$work/srv/arch.tgz" | cut -d' ' -f1)
if sh_fetch_verified_stream http://x/arch.tgz "$work/good" "$want" >/dev/null 2>&1; then
    t_ok 0 'a stream with the right digest verifies'
else
    t_ok 1 'a stream with the right digest verifies'
fi
mkdir -p "$work/out"
if sh_stream_untar "$work/good" "$work/out" >/dev/null 2>&1 && cmp -s "$work/src/sub/big.bin" "$work/out/sub/big.bin"; then
    t_ok 0 'a sharded tar.gz unpacks from the stream and the bytes match'
else
    t_ok 1 'a sharded tar.gz unpacks from the stream and the bytes match'
fi

if sh_fetch_verified_stream http://x/arch.tgz "$work/bad" 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1; then
    t_ok 1 'a stream with the wrong digest is refused'
else
    t_ok 0 'a stream with the wrong digest is refused'
fi
[ -d "$work/bad" ] && t_ok 1 'refused bytes are removed' || t_ok 0 'refused bytes are removed'

# A zip under the limit still unpacks (it is materialised first).
if [ -r "$work/srv/arch.zip" ] && ( command -v unzip >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 ); then
    if sh_fetch_unpack http://x/arch.zip "$work/zipout" >/dev/null 2>&1 && [ -r "$work/zipout/z.txt" ]; then
        t_ok 0 'a small zip unpacks through the streaming path'
    else
        t_ok 1 'a small zip unpacks through the streaming path'
    fi
    # # STOP: AN EXECUTABLE INSIDE A ZIP MUST COME OUT EXECUTABLE. The mode is
    # in the archive: python3's zipfile.extractall writes every entry 0644 and
    # ignores external_attr, while unzip honours it. So the toolchain whose
    # payload is a single 0755 binary (deno, bun) installed by unzip worked and
    # the same archive on a host with no unzip but a python3 unpacked to a file
    # that could not run, and the module's own `[ -x $root/deno ]` check turned
    # that into "the deno archive did not put deno at .../deno" with a download
    # that had in fact arrived complete and verified. Measured here: the archive
    # says 0o100755, extractall produced 0644, and chmod +x made the very same
    # bytes run (deno 2.9.7). This clause fails against that extractor.
    if [ -e "$work/zipout/zrun.sh" ]; then
        if [ -x "$work/zipout/zrun.sh" ]; then
            t_ok 0 'an executable entry in a zip is unpacked executable'
        else
            t_ok 1 'an executable entry in a zip is unpacked executable'
        fi
        t_is "$("$work/zipout/zrun.sh" 2>/dev/null)" 'zipped-executable' \
            'the unpacked executable from a zip actually runs'
    else
        t_skip 'zip executable mode (fixture has no zrun.sh)'
    fi
else
    t_skip 'zip unpack (no unzip/python3 or fixture)'
fi

# A zip bigger than the file-size limit is refused by name, not half-read.
if [ -r "$work/srv/arch.zip" ]; then
    got=$( ( sh_fsize_cap_bytes() { printf 1000000; }; sh_fetch_stream http://x/arch.zip "$work/bigzip" >/dev/null 2>&1
             mkdir -p "$work/bigout"
             sh_stream_untar "$work/bigzip" "$work/bigout" >/dev/null 2>&1; printf '%s' "$?" ) )
    t_is "$got" 1 'a zip above the file-size limit is refused'
else
    t_skip 'zip limit refusal (no fixture)'
fi

# The chunk never exceeds the cap: with a fake 1,000,000-byte cap it drops to
# 750,000, so a part cannot touch the limit.
got=$( sh_fsize_cap_bytes() { printf 1000000; }; sh_fetch_chunk_bytes )
t_is "$got" 750000 'the chunk is capped at three quarters of the file-size limit'

# # STOP: A SERVER THAT ANSWERS NO SIZE ON HEAD IS REAL, AND IT DISABLES
# SHARDING ENTIRELY. The stub above always sends Content-Length on HEAD, which
# is the friendly case. Measured against a public registry through an HTTP
# CONNECT proxy, `curl -I` returned no Content-Length at all while a 1-byte
# ranged GET returned `content-range: bytes 0-0/3053355`: the size was there all
# along, behind a method the probe used. sh_url_content_length only asked HEAD,
# so it answered "no Content-Length", sh_fetch_stream took the
# "fetching it in one piece" branch, and on a host with a pinned RLIMIT_FSIZE
# that single piece died with SIGXFSZ at the cap. The whole feature was dead on
# exactly the hosts that need it, and the warning it printed reads like a
# property of the server rather than a hole in the probe.
#
# This is that server: HEAD carries no size, a ranged GET carries Content-Range.
# The total must be found from the range, or a low cap cannot be honoured.
curl() {
    sh_t_o=''; sh_t_range=''; sh_t_url=''; sh_t_head=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) printf 'curl 8.fake\n'; return 0 ;;
            -o) sh_t_o=$2; shift 2 ;;
            -r) sh_t_range=$2; shift 2 ;;
            -D) shift 2 ;;
            --retry|--retry-delay|--max-time|--connect-timeout|--doh-url) shift 2 ;;
            -*) case "$1" in *I*) sh_t_head=1 ;; esac; shift ;;
            *) sh_t_url=$1; shift ;;
        esac
    done
    sh_t_path="$work/srv/${sh_t_url##*/}"
    [ -r "$sh_t_path" ] || return 22
    sh_t_all=$(wc -c < "$sh_t_path")
    if [ "$sh_t_head" = 1 ]; then
        # No Content-Length and no Content-Range: a proxy-preamble answer, or a
        # CDN that simply does not size a HEAD.
        printf 'HTTP/1.1 200 Connection Established\r\n\r\n'
        printf 'HTTP/2 200 \r\naccept-ranges: bytes\r\n\r\n'
        return 0
    fi
    if [ -n "$sh_t_range" ]; then
        sh_t_s=${sh_t_range%%-*}; sh_t_e=${sh_t_range#*-}
        printf 'HTTP/1.1 206 Partial Content\r\ncontent-length: %s\r\ncontent-range: bytes %s-%s/%s\r\n\r\n' \
            "$((sh_t_e - sh_t_s + 1))" "$sh_t_s" "$sh_t_e" "$sh_t_all"
        tail -c "+$((sh_t_s + 1))" "$sh_t_path" | head -c "$((sh_t_e - sh_t_s + 1))" > "$sh_t_o"
        return 0
    fi
    cat "$sh_t_path" > "$sh_t_o"
    return 0
}
t_is "$(sh_url_content_length http://x/blob.bin)" "$(wc -c < "$work/srv/blob.bin")" \
    'the size is still found from a range when HEAD carries none'

d2="$work/stream-nohead"
if sh_fetch_stream http://x/blob.bin "$d2" >/dev/null 2>&1; then
    t_ok 0 'a fetch is split into ranges even when HEAD carries no size'
else
    t_ok 1 'a fetch is split into ranges even when HEAD carries no size'
fi
n2=0
for p in "$d2"/part.*; do [ -e "$p" ] || continue; n2=$((n2 + 1)); done
t_is "$n2" 3 'the headless server is still fetched as three ranges'
t_is "$(sh_stream_size "$d2")" "$(wc -c < "$work/srv/blob.bin")" \
    'the ranges from a headless server reassemble to the full size'
t_is "$(sh_stream_sha256 "$d2")" "$(sha256sum "$work/srv/blob.bin" | cut -d' ' -f1)" \
    'the stream from a headless server matches the file digest'

r=$(sh_fetch_ranges 10 4)
t_is "$r" '000000 0 3
000001 4 7
000002 8 9' 'ranges tile the total with an inclusive end'
t_is "$(sh_fetch_ranges 5 100)" '000000 0 4' 'one range covers a total under the chunk'

# # STOP: AN .xz ARCHIVE UNPACKS WITHOUT AN `xz` BINARY, LIKE EVERY OTHER
# FORMAT ALREADY GUARDS ITSELF. sh_stream_untar checks sh_have bzip2 and sh_have
# zstd before using them, and then calls `tar -xJf -` for xz, which shells out
# to a decompressor it never checked for. On a host with python3 and no xz that
# is not a degradation, it is a hard stop, and it is the format Rust, Zig and
# LLVM all ship:
#   tar (grandchild): xz: Cannot exec: No such file or directory
#   sandhome: [-] toolchain zig could not be installed
# after a download that had already matched Zig's published digest. The same
# asymmetry is in sh_untar. The tree's own rule (AGENTS.md, working rule 4) is
# that a bootstrap whose job is installing missing tools cannot require them
# first, and python3 is the one interpreter a host like this already has.
if [ -s "$work/srv/arch.tar.xz" ]; then
    # Hide every xz driver from sh_have, which is what a host without one sees.
    sh_have() {
        case "$1" in
            xz|unxz|xzcat|lzma) return 1 ;;
            *) _sh_real_have "$1" ;;
        esac
    }
    # Build a stream directory holding the fixture, the way a fetch would.
    mkdir -p "$work/xzdir"
    cp "$work/srv/arch.tar.xz" "$work/xzdir/part.000000"
    printf 'tar.xz\n' > "$work/xzdir/.suffix"
    if sh_stream_untar "$work/xzdir" "$work/xzout" >/dev/null 2>&1 && [ -r "$work/xzout/sub/a.txt" ]; then
        t_ok 0 'an .xz stream unpacks with no xz binary present'
    else
        t_ok 1 'an .xz stream unpacks with no xz binary present'
    fi
    t_is "$(cat "$work/xzout/sub/a.txt" 2>/dev/null)" 'stream unpack' \
        'the .xz stream unpacked the right bytes'
    if sh_untar "$work/srv/arch.tar.xz" "$work/xzout2" >/dev/null 2>&1 && [ -r "$work/xzout2/sub/a.txt" ]; then
        t_ok 0 'an .xz tarball unpacks with no xz binary present'
    else
        t_ok 1 'an .xz tarball unpacks with no xz binary present'
    fi
    # `sh_have` is RESTORED, not merely removed: `unset -f` leaves the name
    # unbound, and every later clause that asks whether a tool is present fails
    # with "sh_have: not found" instead of answering no. The function is defined
    # again here for that reason.
    sh_have() { command -v "$1" >/dev/null 2>&1; }
else
    t_skip 'xz unpack (no xz and no python3 lzma for a fixture)'
fi

# # STOP: A RESOLVER FAILURE IS NAMED AS ONE. The last thing sh_fetch said when
# it could not download was "no downloader could fetch URL (tried curl, wget,
# fetch); install one first". A downloader that is present and failing is not a
# missing downloader, and that message sends a consumer to install a tool they
# already have. Measured by taking the egress away from a shell with every
# downloader installed: curl answered exit 6 twice on a known host, and the
# message named curl, wget and fetch and none of the resolver. This cage
# without DNS is exactly the case the tree has a DoH lever for, and the message
# walked straight past it.
# The stub below answers every request with the DNS failure, so the diagnostic
# itself is what is measured.
curl() {
    sh_t_o=''; sh_t_range=''; sh_t_url=''; sh_t_head=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) printf 'curl 8.fake\n'; return 0 ;;
            -o) sh_t_o=$2; shift 2 ;;
            -r) sh_t_range=$2; shift 2 ;;
            -D) shift 2 ;;
            --retry|--retry-delay|--max-time|--connect-timeout|--doh-url) shift 2 ;;
            -*) case "$1" in *I*) sh_t_head=1 ;; esac; shift ;;
            *) sh_t_url=$1; shift ;;
        esac
    done
    # Exit 6 is curl's "could not resolve host".
    return 6
}
dns_msg=$(sh_fetch http://x/blob.bin "$work/dnsdest" 2>&1)
case "$dns_msg" in
    *"could not resolve"*) t_ok 0 'a resolver failure is named as a resolver failure' ;;
    *) t_ok 1 "a resolver failure is named as a resolver failure (got $dns_msg)" ;;
esac
case "$dns_msg" in
    *"install one first"*) t_ok 1 'a resolver failure does not tell the consumer to install a downloader' ;;
    *) t_ok 0 'a resolver failure does not tell the consumer to install a downloader' ;;
esac
case "$dns_msg" in
    *SANDHOME_DOH_URL*) t_ok 0 'a resolver failure names the DoH lever' ;;
    *) t_ok 1 'a resolver failure names the DoH lever' ;;
esac

t_end
