#!/bin/sh
# Runs install.sh against fake releases served through file:// and checks
# that it installs only a telar that starts, keeps the previous install when
# anything fails, and stops on Ctrl-C. uname, sw_vers and ldconfig are
# stubbed, so the Linux cases run on any host; the --app case needs hdiutil.
#
#   packaging/release/test-install.sh
#   SH=dash packaging/release/test-install.sh    # the shell that runs install.sh
#   NOEXEC_TMPDIR=/mnt/noexec packaging/release/test-install.sh
#
# NOEXEC_TMPDIR names a directory on a noexec mount, as /tmp is on hardened
# servers; install.sh then gets it as TMPDIR. The http case needs python3.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
shell=${SH:-sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
version=1.0.0

pass() {
    printf 'ok - %s\n' "$1"
}

flunk() {
    printf 'not ok - %s\n' "$1"
    sed 's/^/#   /' "$work/log"
    failures=$((failures + 1))
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# A telar that reports LABEL, or one that dies the way the dynamic loader
# does when a library is missing.
write_telar() {
    if [ "$2" = starts ]; then
        cat >"$1" <<EOF
#!/bin/sh
case \${1:-} in
    --version) echo "telar $version ($3)" ;;
    cli) ln -sf "\$0" "\$4/telar" ;;
esac
EOF
    else
        cat >"$1" <<'EOF'
#!/bin/sh
echo "telar: error while loading shared libraries: libatk-1.0.so.0: cannot open shared object file: No such file or directory" >&2
exit 127
EOF
    fi

    chmod 755 "$1"
}

# A diagram helper that rejects the empty request it reads from stdin with
# status 2, as the real one does, or one the dynamic loader refuses.
write_renderer() {
    if [ "$2" = starts ]; then
        printf '#!/bin/sh\ncat >/dev/null\necho "invalid diagram input" >&2\nexit 2\n' >"$1"
    else
        printf '#!/bin/sh\necho "telar-diagram-renderer: error while loading shared libraries: libgcc_s.so.1" >&2\nexit 127\n' >"$1"
    fi

    chmod 755 "$1"
}

# Writes a release whose desktop and headless builds start or not, and
# whose desktop diagram helper starts unless RENDERER says fails.
release() {
    gui=$1
    headless=$2
    renderer=${3:-starts}
    dir=$work/releases/download/v$version
    rm -rf "$work/releases" "$work/tree"
    mkdir -p "$dir"
    for name in gui headless; do
        asset=telar-linux-x86_64
        behavior=$gui
        if [ "$name" = headless ]; then
            asset=$asset-headless
            behavior=$headless
        fi

        mkdir -p "$work/tree/$asset/bin"
        write_telar "$work/tree/$asset/bin/telar" "$behavior" "$name"
        if [ "$name" = gui ]; then
            write_renderer "$work/tree/$asset/bin/telar-diagram-renderer" "$renderer"
        fi

        tar -czf "$dir/$asset.tar.gz" -C "$work/tree" "$asset"
    done

    : >"$dir/SHA256SUMS"
    for file in "$dir"/*.tar.gz; do
        printf '%s  %s\n' "$(sha256 "$file")" "$(basename "$file")" >>"$dir/SHA256SUMS"
    done
}

# PATH entries that answer for a Linux x86_64 host with or without the
# desktop libraries in the linker cache, or for a macOS 26 host.
stubs() {
    rm -rf "${work:?}/stub"
    mkdir -p "$work/stub"
    system=Linux
    machine=x86_64
    if [ "$1" = macos ]; then
        system=Darwin
        machine=arm64
    fi

    cat >"$work/stub/uname" <<EOF
#!/bin/sh
if [ "\${1:-}" = -m ]; then
    echo $machine
else
    echo $system
fi
EOF
    printf '#!/bin/sh\necho 26.0\n' >"$work/stub/sw_vers"
    printf '#!/bin/sh\n' >"$work/stub/ldconfig"
    if [ "$1" = linux-desktop ]; then
        printf 'echo "libwayland-client.so.0 => /lib/libwayland-client.so.0"\necho "libvulkan.so.1 => /lib/libvulkan.so.1"\n' >>"$work/stub/ldconfig"
    fi

    chmod 755 "$work/stub"/*
}

# Leaves an earlier install in the bin directory.
previous() {
    rm -rf "${work:?}/bin"
    mkdir -p "$work/bin"
    write_telar "$work/bin/telar" starts previous
}

install() {
    PATH="$work/stub:$PATH" HOME="$work/home" TELAR_RELEASES_URL="file://$work/releases" \
        "$shell" "$root/install.sh" --version "$version" --bin-dir "$work/bin" "$@" >"$work/log" 2>&1
}

installed() {
    "$work/bin/telar" --version 2>/dev/null
}

# True when a refused install left no staged copy behind.
clean() {
    for staged in "$work/bin"/.*.new; do
        if [ -e "$staged" ]; then
            return 1
        fi
    done
}

stubs linux-desktop
release starts starts
previous
if install && [ "$(installed)" = "telar $version (gui)" ] && [ -x "$work/bin/telar-diagram-renderer" ]; then
    pass "a desktop gets the native client when it starts"
else
    flunk "a desktop gets the native client when it starts"
fi

release fails starts
previous
if install && [ "$(installed)" = "telar $version (headless)" ] && grep -q 'libatk-1.0.so.0' "$work/log"; then
    pass "a native client that does not start falls back to headless and says why"
else
    flunk "a native client that does not start falls back to headless and says why"
fi

release fails starts
previous
if ! install --gui && [ "$(installed)" = "telar $version (previous)" ] && [ ! -e "$work/bin/telar-diagram-renderer" ] && clean; then
    pass "--gui with a native client that does not start keeps the previous install"
else
    flunk "--gui with a native client that does not start keeps the previous install"
fi

release starts starts fails
previous
if ! install --gui && [ "$(installed)" = "telar $version (previous)" ] && [ ! -e "$work/bin/telar-diagram-renderer" ] && clean; then
    pass "--gui with a diagram helper that does not start keeps the previous install"
else
    flunk "--gui with a diagram helper that does not start keeps the previous install"
fi

release starts starts fails
previous
if install && [ "$(installed)" = "telar $version (headless)" ] && [ ! -e "$work/bin/telar-diagram-renderer" ] && clean; then
    pass "a diagram helper that does not start falls back to headless"
else
    flunk "a diagram helper that does not start falls back to headless"
fi

stubs linux-server
release starts fails
previous
if ! install && [ "$(installed)" = "telar $version (previous)" ]; then
    pass "a headless build that does not start keeps the previous install"
else
    flunk "a headless build that does not start keeps the previous install"
fi

release starts starts
previous
if install && [ "$(installed)" = "telar $version (headless)" ]; then
    pass "a server without the desktop libraries gets headless"
else
    flunk "a server without the desktop libraries gets headless"
fi

release starts starts
printf 'corrupt' >>"$work/releases/download/v$version/telar-linux-x86_64-headless.tar.gz"
previous
if ! install && [ "$(installed)" = "telar $version (previous)" ]; then
    pass "a checksum mismatch keeps the previous install"
else
    flunk "a checksum mismatch keeps the previous install"
fi

release starts starts
previous
pinned=$(sha256 "$work/releases/download/v$version/telar-linux-x86_64-headless.tar.gz")
if install --headless --sha256 "$pinned" && [ "$(installed)" = "telar $version (headless)" ]; then
    pass "--sha256 installs the archive that has that hash"
else
    flunk "--sha256 installs the archive that has that hash"
fi

release starts starts
previous
if ! install --headless --sha256 "$(printf '0%.0s' $(seq 64))" && [ "$(installed)" = "telar $version (previous)" ] && grep -q -- '--sha256 expected' "$work/log" && clean; then
    pass "an archive that matches SHA256SUMS but not --sha256 keeps the previous install"
else
    flunk "an archive that matches SHA256SUMS but not --sha256 keeps the previous install"
fi

stubs linux-desktop
release starts starts
previous
if ! install --sha256 "$pinned" && [ "$(installed)" = "telar $version (previous)" ]; then
    pass "--sha256 without a variant is refused where two archives could be tried"
else
    flunk "--sha256 without a variant is refused where two archives could be tried"
fi

stubs linux-server
rm -rf "${work:?}/releases"
write_telar "$work/built-telar" starts binary
previous
if install --binary "$work/built-telar" --sha256 "$(sha256 "$work/built-telar")" && [ "$(installed)" = "telar $version (binary)" ] && clean; then
    pass "--binary installs a build that has no release"
else
    flunk "--binary installs a build that has no release"
fi

previous
if ! install --binary "$work/built-telar" --sha256 "$(printf '0%.0s' $(seq 64))" && [ "$(installed)" = "telar $version (previous)" ] && clean; then
    pass "--binary with another hash keeps the previous install"
else
    flunk "--binary with another hash keeps the previous install"
fi

write_telar "$work/built-telar" fails binary
previous
if ! install --binary "$work/built-telar" --sha256 "$(sha256 "$work/built-telar")" && [ "$(installed)" = "telar $version (previous)" ] && clean; then
    pass "--binary that does not start keeps the previous install"
else
    flunk "--binary that does not start keeps the previous install"
fi

previous
if ! install --binary "$work/built-telar" && [ "$(installed)" = "telar $version (previous)" ]; then
    pass "--binary without --sha256 is refused"
else
    flunk "--binary without --sha256 is refused"
fi

# An http server that would serve the release, so only --proto refuses it.
if command -v python3 >/dev/null 2>&1; then
    release starts starts
    previous
    python3 -c '
import http.server, sys
server = http.server.HTTPServer(("127.0.0.1", 0), lambda *a: http.server.SimpleHTTPRequestHandler(*a, directory=sys.argv[1]))
print(server.server_address[1], flush=True)
server.serve_forever()
' "$work" >"$work/port" 2>/dev/null &
    server=$!
    while [ ! -s "$work/port" ]; do
        sleep 0.1
    done

    url=http://127.0.0.1:$(cat "$work/port")/releases
    served=no
    if curl -fsS -o /dev/null "$url/download/v$version/SHA256SUMS"; then
        served=yes
    fi

    if [ "$served" = yes ] && ! PATH="$work/stub:$PATH" HOME="$work/home" TELAR_RELEASES_URL="$url" \
        "$shell" "$root/install.sh" --version "$version" --bin-dir "$work/bin" >"$work/log" 2>&1 && [ "$(installed)" = "telar $version (previous)" ]; then
        pass "a plain http release URL is refused although it serves the release"
    else
        printf 'served over http: %s\n' "$served" >>"$work/log"
        flunk "a plain http release URL is refused although it serves the release"
    fi

    {
        kill "$server"
        wait "$server"
    } 2>/dev/null || true
fi

# The installer gets SIGNAL while curl finishes its download, as with a
# `kill PID` or a Ctrl-C that the running child survives. This curl logs
# each call, signals its parent and then downloads.
curl=$(command -v curl)
for signal in INT TERM; do
    release starts starts
    previous
    cat >"$work/stub/curl" <<EOF
#!/bin/sh
echo call >>"$work/curl-calls"
kill -$signal "\$PPID"
exec "$curl" "\$@"
EOF
    chmod 755 "$work/stub/curl"
    rm -f "$work/curl-calls"
    status=0
    install || status=$?
    calls=$(wc -l <"$work/curl-calls" | tr -d ' ')
    rm -f "$work/stub/curl"
    if [ "$status" -gt 128 ] && [ "$calls" = 1 ] && [ "$(installed)" = "telar $version (previous)" ]; then
        pass "SIG$signal stops the installer"
    else
        printf 'exit %s after %s curl calls\n' "$status" "$calls" >>"$work/log"
        flunk "SIG$signal stops the installer"
    fi
done

# Writes a disk image whose Telar.app starts or not, next to a previous app.
disk_image() {
    dir=$work/releases/download/v$version
    rm -rf "${work:?}/releases" "${work:?}/volume" "${work:?}/home" "${work:?}/bin"
    mkdir -p "$dir" "$work/volume/Telar.app/Contents/Resources/bin" "$work/home/Applications/Telar.app"
    write_telar "$work/volume/Telar.app/Contents/Resources/bin/telar" "$1" app
    write_renderer "$work/volume/Telar.app/Contents/Resources/bin/telar-diagram-renderer" starts
    hdiutil create -quiet -volname Telar -srcfolder "$work/volume" -format UDZO "$dir/Telar-macos-aarch64.dmg"
    printf '%s  Telar-macos-aarch64.dmg\n' "$(sha256 "$dir/Telar-macos-aarch64.dmg")" >"$dir/SHA256SUMS"
    : >"$work/home/Applications/Telar.app/previous"
}

if command -v hdiutil >/dev/null 2>&1; then
    stubs macos
    disk_image starts
    if install --app && [ ! -e "$work/home/Applications/Telar.app/previous" ] && [ "$(installed)" = "telar $version (app)" ]; then
        pass "--app installs Telar.app and links telar to it"
    else
        flunk "--app installs Telar.app and links telar to it"
    fi

    disk_image fails
    if ! install --app && [ -e "$work/home/Applications/Telar.app/previous" ]; then
        pass "--app with an app that does not start keeps the previous Telar.app"
    else
        flunk "--app with an app that does not start keeps the previous Telar.app"
    fi
fi

# Hardened servers mount /tmp noexec, where nothing downloaded can run.
if [ -n "${NOEXEC_TMPDIR:-}" ]; then
    printf '#!/bin/sh\n' >"$NOEXEC_TMPDIR/probe"
    chmod 755 "$NOEXEC_TMPDIR/probe"
    if "$NOEXEC_TMPDIR/probe" 2>/dev/null; then
        printf '%s runs executables\n' "$NOEXEC_TMPDIR" >"$work/log"
        flunk "NOEXEC_TMPDIR is a noexec mount"
    fi

    rm -f "$NOEXEC_TMPDIR/probe"
    stubs linux-desktop
    for build in gui headless; do
        release starts starts
        previous
        flag=--$build
        if TMPDIR=$NOEXEC_TMPDIR install "$flag" && [ "$(installed)" = "telar $version ($build)" ] && clean; then
            pass "$flag installs with a noexec temporary directory"
        else
            flunk "$flag installs with a noexec temporary directory"
        fi
    done
fi

if [ "$failures" -gt 0 ]; then
    printf '%s failed\n' "$failures"
    exit 1
fi
