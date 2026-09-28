//! What `telar machine setup` learns about a machine before it changes
//! anything: its system, architecture and C library, its home, where this
//! build of telar would live there and what is installed at that path, the
//! tools the installers need, and where each agent is installed. The probe
//! script prints one `key=value` line per fact; `parse` refuses anything
//! else, since the values end up in paths and later scripts.
const std = @import("std");
const values = @import("arguments/values.zig");
const ProbeValue = @import("ProbeValue.zig");
const MachinePlatform = @This();

pub const Os = enum { linux, macos };
pub const Arch = enum { x86_64, aarch64 };
pub const Libc = enum { gnu, musl };
pub const Tool = enum { curl, tar, bash, node, npm };
pub const Agent = values.HookAgent;

/// The most the probe may print, in bytes.
pub const max_output_bytes = 8 * 1024;

/// Prints the facts; `dir` is set above it to the directory this build
/// installs into under `~/.local/share/telar`.
pub const probe_script =
    \\set -u
    \\home=${HOME:-}
    \\[ -n "$home" ] || { echo 'HOME is not set there' >&2; exit 3; }
    \\printf 'os=%s\n' "$(uname -s)"
    \\printf 'arch=%s\n' "$(uname -m)"
    \\libc=gnu
    \\if [ -f /etc/alpine-release ] || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then libc=musl; fi
    \\printf 'libc=%s\n' "$libc"
    \\printf 'home=%s\n' "$home"
    \\target=$home/.local/share/telar/versions/$dir/telar
    \\printf 'target=%s\n' "$target"
    \\if [ -x "$target" ]; then printf 'installed=%s\n' "$("$target" --version 2>/dev/null | head -n 1)"; fi
    \\for tool in curl tar bash node npm; do
    \\    if command -v "$tool" >/dev/null 2>&1; then printf 'tool=%s\n' "$tool"; fi
    \\done
    \\if command -v node >/dev/null 2>&1; then printf 'node=%s\n' "$(node --version 2>/dev/null | head -n 1)"; fi
    \\found() {
    \\    name=$1
    \\    shift
    \\    for candidate in "$@"; do
    \\        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    \\            printf 'agent=%s:%s\n' "$name" "$candidate"
    \\            return
    \\        fi
    \\    done
    \\}
    \\found claude "$home/.local/bin/claude" "$(command -v claude 2>/dev/null)"
    \\found codex "$home/.local/bin/codex" "$(command -v codex 2>/dev/null)"
    \\found pi "$home/.local/bin/pi" "$home/.pi/agent/bin/pi" "$home/bin/pi" "$(command -v pi 2>/dev/null)"
    \\found opencode "$home/.opencode/bin/opencode" "$(command -v opencode 2>/dev/null)"
    \\found cursor "$home/.local/bin/agent" "$home/.local/bin/cursor-agent" "$(command -v cursor-agent 2>/dev/null)"
    \\
;

os: Os,
arch: Arch,
libc: Libc,
home: ProbeValue,
target: ProbeValue,
/// What `target --version` printed, when a telar is there.
installed: ?ProbeValue = null,
tools: std.EnumSet(Tool) = .initEmpty(),
node: ?ProbeValue = null,
agents: std.EnumArray(Agent, ?ProbeValue) = .initFill(null),

/// Reads the probe's output.
///
/// ```zig
/// const platform = try MachinePlatform.parse(output.stdout);
/// ```
pub fn parse(output: []const u8) !MachinePlatform {
    if (output.len > max_output_bytes) {
        return error.MachineProbeUnreadable;
    }

    var os: ?Os = null;
    var arch: ?Arch = null;
    var libc: ?Libc = null;
    var home: ?ProbeValue = null;
    var target: ?ProbeValue = null;
    var result: MachinePlatform = .{
        .os = undefined,
        .arch = undefined,
        .libc = undefined,
        .home = undefined,
        .target = undefined,
    };

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\n"), '\n');
    while (lines.next()) |line| {
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse return error.MachineProbeUnreadable;
        const key = line[0..equals];
        const value = line[equals + 1 ..];
        for (value) |byte| {
            if (byte < 0x20 or byte == 0x7f) {
                return error.MachineProbeUnreadable;
            }
        }

        if (std.mem.eql(u8, key, "os")) {
            os = if (std.mem.eql(u8, value, "Linux")) .linux else if (std.mem.eql(u8, value, "Darwin")) .macos else return error.UnsupportedMachineSystem;
        } else if (std.mem.eql(u8, key, "arch")) {
            arch = if (std.mem.eql(u8, value, "x86_64") or std.mem.eql(u8, value, "amd64"))
                .x86_64
            else if (std.mem.eql(u8, value, "aarch64") or std.mem.eql(u8, value, "arm64"))
                .aarch64
            else
                return error.UnsupportedMachineArchitecture;
        } else if (std.mem.eql(u8, key, "libc")) {
            libc = std.meta.stringToEnum(Libc, value) orelse return error.MachineProbeUnreadable;
        } else if (std.mem.eql(u8, key, "home")) {
            home = try absolute(value);
        } else if (std.mem.eql(u8, key, "target")) {
            target = try absolute(value);
        } else if (std.mem.eql(u8, key, "installed")) {
            result.installed = try ProbeValue.init(value);
        } else if (std.mem.eql(u8, key, "tool")) {
            result.tools.insert(std.meta.stringToEnum(Tool, value) orelse return error.MachineProbeUnreadable);
        } else if (std.mem.eql(u8, key, "node")) {
            result.node = try ProbeValue.init(value);
        } else if (std.mem.eql(u8, key, "agent")) {
            const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.MachineProbeUnreadable;
            const agent = std.meta.stringToEnum(Agent, value[0..colon]) orelse return error.MachineProbeUnreadable;
            result.agents.set(agent, try absolute(value[colon + 1 ..]));
        } else {
            return error.MachineProbeUnreadable;
        }
    }

    result.os = os orelse return error.MachineProbeUnreadable;
    result.arch = arch orelse return error.MachineProbeUnreadable;
    result.libc = libc orelse return error.MachineProbeUnreadable;
    result.home = home orelse return error.MachineProbeUnreadable;
    result.target = target orelse return error.MachineProbeUnreadable;
    return result;
}

/// The release archive this machine installs: the static headless build
/// on Linux, the command line archive on macOS.
///
/// ```zig
/// const asset = platform.assetName();  // "telar-linux-aarch64-headless.tar.gz"
/// ```
pub fn assetName(self: *const MachinePlatform) []const u8 {
    return switch (self.os) {
        .linux => switch (self.arch) {
            .x86_64 => "telar-linux-x86_64-headless.tar.gz",
            .aarch64 => "telar-linux-aarch64-headless.tar.gz",
        },
        .macos => switch (self.arch) {
            .x86_64 => "telar-macos-x86_64.tar.gz",
            .aarch64 => "telar-macos-aarch64.tar.gz",
        },
    };
}

/// Whether telar at the target path already prints `telar VERSION`.
pub fn installedVersion(self: *const MachinePlatform, version: []const u8) bool {
    const line = if (self.installed) |*text| text.slice() else return false;
    const prefix = "telar ";
    return std.mem.startsWith(u8, line, prefix) and std.mem.eql(u8, line[prefix.len..], version);
}

fn absolute(value: []const u8) !ProbeValue {
    if (value.len == 0 or value[0] != '/') {
        return error.MachineProbeUnreadable;
    }

    return ProbeValue.init(value);
}

test "the probe's facts parse into a platform" {
    const platform = try parse(
        \\os=Linux
        \\arch=aarch64
        \\libc=musl
        \\home=/home/dev
        \\target=/home/dev/.local/share/telar/0.3.0/telar
        \\installed=telar 0.3.0
        \\tool=curl
        \\tool=tar
        \\node=v22.19.0
        \\agent=codex:/home/dev/.local/bin/codex
        \\
    );

    try std.testing.expectEqual(Os.linux, platform.os);
    try std.testing.expectEqual(Libc.musl, platform.libc);
    try std.testing.expectEqualStrings("telar-linux-aarch64-headless.tar.gz", platform.assetName());
    try std.testing.expect(platform.installedVersion("0.3.0"));
    try std.testing.expect(!platform.installedVersion("0.3.1"));
    try std.testing.expect(platform.tools.contains(.curl) and !platform.tools.contains(.node));
    try std.testing.expectEqualStrings("/home/dev/.local/bin/codex", platform.agents.get(.codex).?.slice());
    try std.testing.expectEqual(@as(?ProbeValue, null), platform.agents.get(.claude));
}

test "unknown systems, noise and missing facts are refused" {
    try std.testing.expectError(error.UnsupportedMachineSystem, parse("os=FreeBSD\n"));
    try std.testing.expectError(error.UnsupportedMachineArchitecture, parse("os=Linux\narch=riscv64\n"));
    try std.testing.expectError(error.MachineProbeUnreadable, parse("Welcome to box!\nos=Linux\n"));
    try std.testing.expectError(error.MachineProbeUnreadable, parse("os=Linux\narch=x86_64\nlibc=gnu\nhome=/home/dev\n"));
    try std.testing.expectError(error.MachineProbeUnreadable, parse("os=Linux\narch=x86_64\nlibc=gnu\nhome=relative\ntarget=/t\n"));
    try std.testing.expectError(error.MachineProbeUnreadable, parse("os=Linux\narch=x86_64\nlibc=gnu\nhome=/h\x1b[2J\ntarget=/t\n"));
}
