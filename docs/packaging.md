# Packaging

Telar ships the `telar` executable and its isolated `telar-diagram-renderer`
helper. Building the GUI also requires Cargo and Rust 1.93.1 or newer; packaged
applications do not need that toolchain. See the [helper build and protocol](../tools/diagram-renderer/README.md).
Packaging adds what a desktop expects around
it: something to double-click, an icon, and a way for shells and agents to
find `telar` afterwards. `telar` typed in a terminal opens the same window as
the launchers; without a display (an SSH login, or Linux without
`WAYLAND_DISPLAY`) it says so and names the CLI commands to use instead.

## Install a local build

No releases are published yet. The release, installer and Homebrew sections
below describe packaging infrastructure; use a local build today.
Start with the [build dependencies](development.md#build-requirements).

On macOS, build the app, copy it to a location you will keep, and open it:

```sh
zig build bundle -Doptimize=ReleaseFast
mkdir -p "$HOME/Applications"
```

Use Finder to copy `zig-out/Telar.app` to `~/Applications`. If another copy
already exists there, quit its window and decide whether to replace it. This
does not itself stop its runtime. Then launch and link the installed executable:

```sh
open "$HOME/Applications/Telar.app"
"$HOME/Applications/Telar.app/Contents/Resources/bin/telar" cli install --dir "$HOME/.local/bin"
```

On Linux, install into a user-owned prefix:

```sh
zig build -Doptimize=ReleaseFast --prefix "$HOME/.local"
"$HOME/.local/bin/telar" --version
```

This installs the binary, diagram helper, desktop entry and icon. It can
replace a previous build at that prefix. Ensure `~/.local/bin` is on PATH.
The app menu entry opens the GUI through the login shell.

A running runtime keeps its existing build. After updating, save/finish the
work in its panes before stopping that runtime and starting the new build.
Reinstall agent integrations if their executable path changed; see
[agents](agents.md#install-an-integration).

## macOS

```sh
zig build bundle -Doptimize=ReleaseFast   # zig-out/Telar.app
zig build dmg -Doptimize=ReleaseFast      # zig-out/Telar.dmg
just install-gui                          # bundle into ~/Applications, telar into ~/.local/bin
```

`just install-gui` builds the bundle in ReleaseFast, replaces
`~/Applications/Telar.app` and links `~/.local/bin/telar` to the bundled
executable through `telar cli install`; both directories are recipe
parameters. On Linux the same recipe runs `zig build --prefix ~/.local` in
ReleaseFast. A running runtime keeps its old executable until it is
restarted, and hooks installed with `telar integration install` keep the
path they were installed with.

The bundle layout:

```
Telar.app/Contents/
  Info.plist                 packaging/macos/Info.plist.in, version from build.zig.zon
  MacOS/Telar                launcher, src/launcher/main.zig
  Resources/telar.icns       packaging/macos/telar.icns
  Resources/bin/telar        the executable
  Resources/bin/telar-diagram-renderer   native Mermaid rasterizer
  Resources/licenses/        notices of every library compiled in
```

Finder starts `MacOS/Telar` with no arguments. The launcher execs
`Resources/bin/telar gui --login-shell` and nothing else, which keeps the
CLI's argument grammar untouched. The executable lives under `Resources`
because macOS file systems fold case: `Telar` and `telar` cannot share
`Contents/MacOS`.

The icon comes from two sources drawn for different sizes:
`src/assets/telar-mark.svg` for 16 to 64 px and `src/assets/telar-icon.svg`
for 128 to 1024 px. One script renders the iconset, runs `iconutil` and
also writes `packaging/linux/telar.png`, the top bar mark and the site's
brand files:

```sh
uv run --no-project --with pillow==12.2.0 python tools/build_brand_icons.py
```

`zig build` signs nothing beyond the linker's ad hoc signature, which is
enough on the machine that built it. The [release workflow](#releases) signs
and notarizes for other Macs.

## Linux

`zig build` installs, next to `bin/telar`, a desktop entry at
`share/applications/telar.desktop` and the icon at
`share/icons/hicolor/512x512/apps/telar.png`. `zig build package-linux`
tars `bin` and `share` into `zig-out/telar-<arch>-linux.tar.gz`; unpack it
over a prefix such as `/usr/local` or `~/.local`.

`zig build -Dgui=false` leaves the window out. The result has the runtime
and every command line control, links no Wayland, Vulkan, ATK or GLib
library, and builds without Cargo. `telar` and `telar gui` then exit with an
error. This is the build for servers, which is where remote mode runs the
runtime. The release adds `-Dtarget=<arch>-linux-musl`, which makes it a
static executable that needs no library of the host
([why](#why-the-headless-build-is-static-musl)).

The desktop entry runs `telar gui --login-shell`, so the menu launch is the
same path as the macOS bundle.

## The login shell

An app started from Finder or a desktop menu inherits the session's
environment, not the user's: no PATH additions, usually no `EDITOR`, and no
`SHELL` beyond what the session sets. `telar gui --login-shell` fixes that
once, before anything else runs: it replaces itself with

```sh
$SHELL -l -c 'exec "$0" "$@"' /path/to/telar gui ARGS...
```

using `SHELL`, else the account's shell from the passwd database, else
`/bin/sh`; fish gets `exec $argv` because it has no `$0`. The relaunched
process carries `TELAR_LOGIN_SHELL=1` so it never relaunches again. The
interactive rc file is not read: a login, non-interactive shell is what
`.zprofile`, `.bash_profile` and `config.fish` are for, and what keeps a
`tmux` or `fzf` line in `.zshrc` from running under the app.

## The command line

A bundled Telar is invisible to shells and agents until `telar` is on the
PATH. `telar agent`, `telar pane` and the agent hooks all depend on it.

```sh
telar cli install                 # symlink /usr/local/bin/telar -> this executable
telar cli install --dir ~/.local/bin
telar cli status
telar cli uninstall
```

`install` replaces a previous symlink and refuses to touch anything that is
not one. When the default directory is not writable it says so and suggests
`sudo` or `--dir`.

## Native libraries

The standalone libraries link three C libraries. `build/native_libraries.zig`
compiles each from a source archive pinned by hash in `build.zig.zon` and
links it statically, the way `build/freetype.zig` builds FreeType and
HarfBuzz.

| Library | Pinned source | Used by |
| --- | --- | --- |
| brotli 1.2.0, decoder only | GitHub tag archive | `exchangecapture` |
| nghttp2 1.70.0 | release tarball | `httprelay` |
| SQLite 3.53.4 amalgamation, with FTS5 | sqlite.org | `sqlite`, Linux only |

macOS keeps its own `/usr/lib/libsqlite3.dylib`. Every macOS ships it and
Apple patches it with the OS. On Linux the system SQLite is often missing
from minimal server images, and its FTS5 support depends on how the
distribution built it, so every Linux release carries the same amalgamation.
It is built without extension loading, which nothing in telar uses.
`zig build cross` builds all three from source for the targets it checks.

A distribution package can link system copies instead:

```sh
zig build -Dbrotli=/usr -Dnghttp2=/usr -Dsqlite=/usr
```

Each option names the prefix holding `include/` and `lib/`. Third-party C
stays optimized in Debug builds, as the emulator does.

The notices of these libraries, FreeType and HarfBuzz install under
`share/telar/licenses` and `Telar.app/Contents/Resources/licenses`.

## Releases

A tag `vX.Y.Z` runs [`.github/workflows/release.yml`](../.github/workflows/release.yml).
The tag must equal `.version` in `build.zig.zon`; `telar --version` and the
bundle's `Info.plist` read it from there.

To publish a version:

1. Set `.version` in `build.zig.zon`, commit and merge to `main`.
2. Tag that commit `vX.Y.Z` and push the tag.
3. Watch the workflow. It publishes the release once every platform built.

Every pull request and push to `main` runs [`ci.yml`](../.github/workflows/ci.yml):
`zig build`, `zig build check` and `zig build test` on macOS arm64 and Linux
x86_64 with Node 22 for the integration scripts' `node --test`, the headless linkage check, shellcheck on the release scripts and
the installer tests.

### Assets

Asset names carry no version, so `releases/latest/download/NAME` always
points at the newest one.

| Asset | Contents |
| --- | --- |
| `telar-macos-aarch64.tar.gz`, `telar-macos-x86_64.tar.gz` | `bin/telar`, `bin/telar-diagram-renderer`, notices |
| `Telar-macos-aarch64.dmg`, `Telar-macos-x86_64.dmg` | `Telar.app` and a link to `/Applications` |
| `telar-linux-x86_64.tar.gz`, `telar-linux-aarch64.tar.gz` | the tree `zig build` installs, desktop entry included |
| `telar-linux-x86_64-headless.tar.gz`, `telar-linux-aarch64-headless.tar.gz` | `bin/telar` built with `-Dgui=false`, notices |
| `install.sh` | the installer from the tagged commit |
| `SHA256SUMS` | SHA-256 of every asset above |

Each asset also gets a build provenance attestation signed through
Sigstore. `gh attestation verify FILE --repo adriangs1996/telar` checks one.

### What each build pins

| Build | Runner | Target | Links |
| --- | --- | --- | --- |
| macOS arm64 | `macos-26` | `aarch64-macos.26.0`, Apple M1 | `/usr/lib` and `/System/Library` only |
| macOS x86_64 | `macos-26-intel` | `x86_64-macos.26.0`, core2 | same |
| Linux desktop | `ubuntu-24.04`, `ubuntu-24.04-arm` | host glibc, baseline CPU | glibc, Wayland, Vulkan, xkbcommon, Fontconfig, ATK, GLib; glibc 2.38 or newer |
| Linux headless | same | `<arch>-linux-musl`, baseline CPU | nothing: static musl, Linux 5.10 or newer |

The labels come from GitHub's
[hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Both Linux architectures build on native runners, so every archive is built
and smoke-tested on the architecture it ships for.

The macOS deployment target is 26.0 because the native client needs Metal 4.
Left alone, Zig targets the host's exact version, which on a runner is
whatever macOS 26.x it has. With a pinned version Zig treats the target as
foreign and stops finding the SDK, so `packaging/macos/sdk-libc.sh` writes a
libc file for `--libc` and `build/macos_sdk.zig` adds the SDK's frameworks
and `usr/lib`.

Linux builds pin the baseline CPU of their architecture. A native build
would use whatever AVX-512 or SVE the runner has and crash on older
machines.

`packaging/release/check-linkage.sh` fails the build when a binary links
anything outside that table, when the desktop build asks for glibc newer
than 2.38, or when the headless build has any `NEEDED` entry or program
interpreter. It reads `otool -L` on macOS and `readelf` on Linux.

The desktop build's glibc floor is the runner's. On `ubuntu-24.04-arm`,
glibc 2.38 headers turn `strtol` and `strtoul` into `__isoc23_strtol` and
`__isoc23_strtoul`, the only `GLIBC_2.38` symbols of the aarch64 `telar`;
its `telar-diagram-renderer` stops at 2.35. The x86_64 build was not
measured outside CI, where the same check holds it to 2.38. Debian 12 ships
glibc 2.36, so there `install.sh` finds that the desktop build does not
start and installs the headless one.

### Why the headless build is static musl

A server gets whatever Linux it has: Alpine, an old enterprise release, a
container without a desktop. A static binary needs no libc of the host at
all, so the headless build targets `<arch>-linux-musl`, which Zig links
statically. What differs from glibc, checked in this code:

- Name resolution, TLS and the trust store never go through libc. The
  proxy resolves upstream hosts with `std.Io.net.HostName.lookup`, Zig's
  own resolver that reads `/etc/hosts` and `/etc/resolv.conf` on either
  libc; `lib/localca` finds roots through `std.crypto.Certificate.Bundle`.
  Neither reads `nsswitch.conf` under glibc either.
- The passwd database appears once, in `src/cli/login_shell.zig`, as the
  fallback after `SHELL` for `telar gui --login-shell`, which a headless
  build refuses. musl reads only `/etc/passwd` there, without NSS, so an
  LDAP or SSSD account would fall back to `/bin/sh` if it ever reached it.
- A C `struct stat` cannot come through `@cImport` on musl: its `timespec`
  pads with bit-fields, so translate-c makes the struct opaque. Ownership
  checks read `privatefile.Inode` instead, which asks `statx` on Linux,
  the call `std.Io` already makes for every stat, and `fstatat` elsewhere.
  CI builds the headless binary for musl, so an import that brings the
  struct back fails there.
- The kernel floor is Zig's, not libc's. Without a version in the target,
  Zig 0.16 builds Linux executables for 5.10 or newer
  (`default_min` in `std/Target.zig`), and the standard library may use
  what that version has without a fallback. The release does not lower
  it, so it supports Linux 5.10 and later; `statx` alone would need only
  4.11. Every run described here used OrbStack's 7.0 kernel; no older
  kernel was tried.
- `malloc` is not musl's. Zig 0.16 links its own `malloc` into musl
  builds (`c/malloc.zig` in its lib directory), a wrapper over
  `std.heap.SmpAllocator`; the binary's `malloc` is `c.malloc.malloc`.
  That allocator keeps one free list per thread slot, never unmaps a slab
  of 64 KiB or less, and searches only one other slot before mapping a
  new slab. The runtime allocates a history batch on one thread and frees
  it on the history worker, and threads move between slots under
  contention, so freed memory piled up on slots the allocating threads
  never searched: at 150,000 commands a counting build had 72 MiB of
  slabs, most of it on free lists. Its own symbol cannot be replaced
  either: a second `export fn malloc` collides inside the Zig compilation,
  and a C definition is not used by Zig's calls.

  Release builds for musl therefore start through `mainOnSlabHeap` in
  `src/main.zig`, with `lib/slabheap` as the process's general allocator
  and its `std.Io`'s. That allocator is the same one, except that a thread
  whose slot is empty visits every other slot before it maps a slab,
  spinning up to 128 times for a busy one, and maps outside every lock.
  The C libraries allocate from the caller's allocator, not `malloc`:
  SQLite through `sqlite.routeMemory`, and Lua, brotli and nghttp2 through
  the hooks each takes, over `lib/cblocks`. Debug builds, glibc and macOS
  keep the standard start, where the general allocator is libc's or Zig's
  leak-checking one.

  Measured in one Debian 12 container with 4 CPUs, feeding the runtime
  commands through `telar history import`, 1000 at a time, with aarch64
  ReleaseFast builds, two runs each, alternating builds. The "before" rows
  come from an earlier batch of the same binary:

  | Build | Commands | Resident at the end | Runtime CPU |
  | --- | --- | --- | --- |
  | glibc | 150,000 | 21.2 and 21.2 MiB | 23.0 and 23.4 s |
  | musl, Zig's `malloc` (before) | 150,000 | 118 and 188 MiB | 24.0 and 24.0 s |
  | musl, `slabheap` | 150,000 | 19.4 and 19.4 MiB | 23.2 and 23.0 s |
  | glibc | 300,000 | 20.6 and 20.8 MiB | 66.2 and 66.2 s |
  | musl, Zig's `malloc` (before) | 300,000 | 85 and 80 MiB | 65.7 and 65.4 s |
  | musl, `slabheap` | 300,000 | 18.8 and 19.2 MiB | 66.7 and 67.3 s |

  Searches took 0.01 to 0.03 s for 20 in every build. Before, resident
  memory varied from run to run and still grew by 5 to 19 MiB per 50,000
  commands between 200,000 and 300,000. With `slabheap`, anonymous memory
  went from 10,132 to 10,164 KiB between 150,000 and 300,000 commands in
  one run and from 10,368 to 10,560 KiB in the other. SQLite reported
  2.1 MiB in use from the first 10,000 commands on and a high-water mark
  of 4.2 MiB.

  How long a thread may wait for a busy slot was measured with a scratch
  program on the macOS host (8 cores, 1 µs clock), three runs each: one
  thread allocating 400 batches of 2000 blocks of 16 to 3000 bytes, which
  six or 24 threads free.

  | Busy slot | Worst allocation | 99.99th percentile | Slabs mapped |
  | --- | --- | --- | --- |
  | waited for without bound | 277 to 477 µs | 2 to 85 µs | 92 to 373 |
  | skipped after 128 spins | 16 to 30 µs | 7 µs | 103 to 147 |

  With six freeing threads and ten times as many batches, 128 spins mapped
  214 to 572 slabs and the unbounded wait 438 to 560. In the container,
  where up to 25 threads share 4 CPUs, the worst allocation reached 43 ms
  with 128 spins and 51 ms with the wait: the allocating thread itself was
  descheduled.

  The proxy's pattern was measured apart, since no end-to-end proxy load
  ran: a scratch aarch64 musl program in the same container ran six
  threads that each, 60,000 times, encoded and decoded an HPACK block of
  twelve headers through nghttp2 with `header_memory` hooks, decoded a
  brotli body through `exchangecapture.decode`, and allocated a capture
  record of 64 to 8192 bytes, two runs per allocator:

  | Capture records freed by | Zig's `malloc` | `slabheap` |
  | --- | --- | --- |
  | one consumer thread | 2,282 and 1,855 MiB, still growing | 2.7 and 3.0 MiB |
  | the thread that made them | 198 and 205 MiB | 1.6 and 1.6 MiB |

  Both allocators took 9.3 to 11.2 s. The second row has no handoff
  between threads at all: threads moving between slots under contention
  are enough to strand memory under Zig's `malloc`.

The binary was also started on Alpine 3.22, where `telar server`,
`telar runtime status`, `telar agent list` and `telar server stop` worked
with no library installed. The glibc build it replaces does not start
there: Alpine has no `ld-linux-aarch64.so.1`.

To reproduce a release build locally:

```sh
packaging/release/macos.sh build /tmp/stage && packaging/release/macos.sh package /tmp/stage dist
packaging/release/linux.sh dist   # Ubuntu 24.04, after install-linux-deps.sh
```

### Signing and notarization

The macOS release runs in two jobs per architecture. `macos` builds and
uploads the stage as an artifact; `macos-sign` downloads it on a fresh
runner, signs, packages and notarizes. The build runs Cargo build scripts
and other third-party code, and a step can reach every later step of its
job through `GITHUB_ENV`, `GITHUB_PATH` or the checkout, so the build job
sees no secret. In `macos-sign` each secret is in the `env` of only the
steps that use it, and nothing is built there.

It signs and notarizes only when the secrets exist. Without them it still
publishes. The Linux and command line assets are unaffected, and the
release notes say the disk images are not notarized. The three signing
secrets go together, and so do the three notary secrets: a job with only
some of a group fails, instead of publishing an ad hoc signature as if it
were signed. The notes' "signed" comes from the bundle itself:
`packaging/release/signed-by-developer-id.sh` requires a valid signature
whose chain `codesign -dvv` reports as Developer ID Application, Developer
ID Certification Authority and Apple Root CA.

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application certificate and private key, as a base64 `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | password of that `.p12` |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: Name (TEAMID)` |
| `NOTARY_KEY_P8` | text of an App Store Connect API key, `AuthKey_XXXX.p8` |
| `NOTARY_KEY_ID` | that key's ID |
| `NOTARY_ISSUER_ID` | the issuer ID shown above the list of keys |
| `HOMEBREW_TAP_TOKEN` | fine-grained token with Contents read and write on `adriangs1996/homebrew-tap` only |

To create them with an Apple Developer Program membership:

1. In Xcode, Settings, Accounts, Manage Certificates, add a Developer ID
   Application certificate. Only the Account Holder can create one.
2. Export it with its private key from Keychain Access as a `.p12` with a
   strong password, then `base64 -i cert.p12 | pbcopy` into the secret.
3. `security find-identity -v -p codesigning` prints the identity string.
4. In App Store Connect, Users and Access, Integrations, App Store Connect
   API, create a team key with the Developer role and download the `.p8`.
   Apple allows one download. Paste its text, header lines included.
5. `gh secret set NAME` stores each value in the repository.

`packaging/release/sign-macos.sh` signs the helper, `telar`, the launcher and
the bundle, in that order, with the hardened runtime and a secure timestamp.
Apple requires both for notarization and rejects the
`com.apple.security.get-task-allow` entitlement
([Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)).
Telar needs no entitlement. It runs no JIT and loads no library at runtime,
and its notifications run `/usr/bin/osascript` as a separate process rather
than sending Apple Events. Check that notifications still appear on the
first signed build.

`packaging/release/notarize-macos.sh` signs the disk image, submits it with
`notarytool --wait`, staples the ticket and validates it. Then it submits
the command line binaries as a zip. `stapler` only staples disk images,
bundles and installer packages, so a bare `telar` relies on Gatekeeper
finding its ticket online. The workflow imports the certificate into a
temporary keychain with a random password and deletes it when the job ends.

### Gatekeeper

Gatekeeper assesses files that carry the `com.apple.quarantine` attribute.
Browsers and Homebrew casks set it; `curl` does not. On macOS 26.6.2 the ad
hoc signed `shellcheck` 0.11.0 from GitHub, downloaded with `curl`, had no
quarantine attribute and ran, even though `spctl --assess` rejected it. A
copy with the attribute added did not start. An ad hoc signed `Telar.app`
installed by `install.sh --app` also opened through `open` without a
prompt. So without an Apple Developer membership, 99 USD a year, the
archives and `install.sh --app` still work; only a DMG opened from a
browser needs the user to click Open Anyway in System Settings, Privacy &
Security ([Apple](https://support.apple.com/en-us/102445)). Apple waives
the fee only for nonprofits, accredited schools and governments, never for
individuals ([fee waivers](https://developer.apple.com/help/account/membership/fee-waivers/)).

Without the Developer ID secrets, `sign-macos.sh` signs the bundle ad hoc,
so its signature seals the resources instead of stopping at the linker's
signatures of each executable.

### install.sh

```sh
curl -fsSL https://github.com/adriangs1996/telar/releases/latest/download/install.sh | sh
curl -fsSL https://github.com/adriangs1996/telar/releases/latest/download/install.sh | sh -s -- --app
curl -fsSL https://github.com/adriangs1996/telar/releases/latest/download/install.sh | sh -s -- --version 0.3.0 --headless
```

With `--app` on macOS it downloads the DMG instead, checks it, mounts it
read-only, copies `Telar.app` into `~/Applications` or `--app-dir`, and runs
the bundled `telar cli install` to link `telar` in the bin directory to the
executable inside the app. It refuses to replace a regular `telar` file left
by a command line install.

It picks the asset for the system and architecture, downloads it with
`SHA256SUMS` and aborts unless the checksum matches. It copies `telar` and
`telar-diagram-renderer` beside their targets in `~/.local/bin` or
`--bin-dir` as `.telar.new` and `.telar-diagram-renderer.new`, and runs them
from there with `LD_BIND_NOW=1`: `telar --version`, and the helper on an
empty request, which it rejects with status 2 while a loader failure exits
127. A build that the dynamic loader cannot load, for a missing library or
symbol, so never replaces a working install. The check runs in the bin
directory rather than the download directory because hardened servers
mount `/tmp` noexec, where nothing can run. Only when both start does it
rename them into place; otherwise it removes the copies. `--app` checks
the copied `Telar.app` the same way before swapping it in. It runs `sudo`
only with `--sudo`.

On Linux it tries the desktop build when `ldconfig -p` lists
`libwayland-client.so.0` and `libvulkan.so.1`, looking in `/sbin` and
`/usr/sbin` too, since a regular Debian user's PATH has neither. The
desktop build also needs xkbcommon, Fontconfig, ATK, GLib and glibc 2.38
(see [What each build pins](#what-each-build-pins)); when it does not
start, the installer prints the loader's error and installs the headless
build instead. `--gui` insists on the desktop build and aborts, keeping the
install, when it does not start; `--headless` skips it. Remote mode needs
the same version on both machines, so pin `--version` on the server.
`TELAR_RELEASES_URL` points it at a mirror or a local `file://` copy.

`--sha256 HEX` adds a second check: the archive (or disk image) must hash to
that value as well as match `SHA256SUMS`. `telar machine setup` passes the
hash the client read from its own release, so a machine never installs an
archive the client did not name. Since it names one archive, a Linux
install needs `--headless` or `--gui` beside it. `--binary FILE --sha256 HEX`
installs a bare executable instead of a release, for development builds
that have none; it is staged and started from the target directory like a
downloaded one.

It needs `curl`. A stock Alpine has only busybox `wget`, so install curl
first there, which the one-line install needs anyway:

```sh
apk add curl
curl -fsSL https://github.com/adriangs1996/telar/releases/latest/download/install.sh | sh
```

`--proto '=https,file'` refuses plain http, redirects to http included. `wget` has no equivalent: its `--https-only` applies only to
recursive downloads, and GNU Wget 1.21.3 fetched an http URL with it.
Ctrl-C, SIGTERM and SIGHUP stop it after removing its temporary directory.

`packaging/release/test-install.sh` runs the installer against fake
releases through `file://`, with `uname`, `sw_vers` and `ldconfig`
stubbed: fallback, refusal, checksum, http and signal cases, plus `--app`
where `hdiutil` exists. The http case serves the release over plain http,
so only `--proto` refuses it. With `NOEXEC_TMPDIR` naming a directory on a
noexec mount, as CI mounts one, it also installs with that as `TMPDIR`.

The checksums come from the same release as the archive. They catch a
corrupt download, not a tampered release; the attestation covers that.

### Homebrew

`packaging/homebrew` holds templates for a tap at `adriangs1996/homebrew-tap`:

- `telar.rb.in`, the `telar` formula: the macOS command line archive, or the
  headless build on Linux.
- `telar-app.rb.in`, the `telar-app` cask: `Telar.app` plus the `telar`
  command. Both put `telar` in Homebrew's `bin`, so install one of them.

After publishing, the workflow renders them with `render.sh` and pushes
them to the tap when `HOMEBREW_TAP_TOKEN` exists. It writes the cask only
for notarized disk images: Homebrew quarantines cask downloads, deprecated
`--no-quarantine` in 5.0.0, and disables casks in its own repository that
fail Gatekeeper since September 2026
([Homebrew 5.0.0](https://brew.sh/2025/11/12/homebrew-5.0.0/)).

```sh
brew install adriangs1996/tap/telar
brew install --cask adriangs1996/tap/telar-app
```
