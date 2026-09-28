//! The agent steps of `telar machine setup` (docs/flows/machine-setup.md):
//! every coding agent the person has on this machine is installed on the
//! other one with its official installer, under the home and without sudo,
//! and every agent there gets telar's integration. A prerequisite the
//! machine lacks is reported with what to install, never improvised.
//! Sources for each installer are in docs/plans/machine-setup.md.
const std = @import("std");
const MachinePlatform = @import("MachinePlatform.zig");
const SetupReport = @import("SetupReport.zig");
const remote_shell = @import("remote_shell.zig");
const Agent = MachinePlatform.Agent;

/// Seconds one installer may take.
const install_timeout_s = 900;
const integration_timeout_s = 60;
/// Room for every agent's name, comma separated.
const names_bytes = 64;
/// The longest script of one agent's installer.
const max_installer_bytes = 512;
/// Pi's installer needs Node 22.19 or newer (Pi's quickstart).
const pi_node_major = 22;
const pi_node_minor = 19;

/// How one agent is installed, per its official documentation.
const Installer = struct {
    /// The command it is found by on this machine.
    command: []const u8,
    /// What its installer needs on the machine.
    tools: []const MachinePlatform.Tool,
    /// Whether its binary runs on musl.
    runs_on_musl: bool,
    /// Runs after `installer_prelude`: `fetch URL` downloads the official
    /// installer into `$installer`, which the script then runs.
    script: []const u8,
};

/// What every installer script starts with. The official installer is
/// downloaded over https only into a private file and run from there, never
/// piped: a download that fails stops the script with curl's status instead
/// of feeding an empty or cut script to a shell that exits 0. The installer
/// reads no standard input, which carries this script.
const installer_prelude =
    \\set -eu
    \\installer=$(mktemp "${TMPDIR:-/tmp}/telar-agent-installer.XXXXXX")
    \\trap 'rm -f "$installer"' EXIT
    \\fetch() {
    \\    curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$installer"
    \\}
    \\
;

fn installerFor(agent: Agent) Installer {
    return switch (agent) {
        // https://code.claude.com/docs/en/setup: native installer; on Alpine
        // it needs libgcc, libstdc++ and ripgrep from apk, which needs root.
        .claude => .{
            .command = "claude",
            .tools = &.{ .curl, .bash },
            .runs_on_musl = true,
            .script =
            \\if [ -f /etc/alpine-release ]; then
            \\    if [ ! -e /usr/lib/libstdc++.so.6 ] || ! command -v rg >/dev/null 2>&1; then
            \\        echo 'Claude Code on Alpine needs `apk add libgcc libstdc++ ripgrep` (as root) first' >&2
            \\        exit 1
            \\    fi
            \\fi
            \\fetch https://claude.ai/install.sh
            \\bash "$installer" </dev/null
            \\
            ,
        },
        // https://learn.chatgpt.com/docs/config-file/environment-variables.md
        .codex => .{
            .command = "codex",
            .tools = &.{ .curl, .tar },
            .runs_on_musl = true,
            .script =
            \\fetch https://chatgpt.com/codex/install.sh
            \\CODEX_NON_INTERACTIVE=1 sh "$installer" </dev/null
            \\
            ,
        },
        // github.com/earendil-works/pi, packages/coding-agent/docs/quickstart.md
        .pi => .{
            .command = "pi",
            .tools = &.{ .curl, .node, .npm },
            .runs_on_musl = true,
            .script =
            \\fetch https://pi.dev/install.sh
            \\sh "$installer" </dev/null
            \\
            ,
        },
        // https://opencode.ai/docs; the installer detects musl itself.
        .opencode => .{
            .command = "opencode",
            .tools = &.{ .curl, .bash, .tar },
            .runs_on_musl = true,
            .script =
            \\fetch https://opencode.ai/install
            \\bash "$installer" --no-modify-path </dev/null
            \\
            ,
        },
        // https://cursor.com/docs/cli/installation.md; its bundled node links
        // glibc (checked in the Linux x64 package 2026.09.26-dd393fe).
        .cursor => .{
            .command = "cursor-agent",
            .tools = &.{ .curl, .bash },
            .runs_on_musl = false,
            .script =
            \\fetch https://cursor.com/install
            \\bash "$installer" </dev/null
            \\
            ,
        },
    };
}

/// The agents whose command is on this machine's PATH.
///
/// ```zig
/// const wanted = agent_setup.detectLocal(process_init.minimal.environ);
/// ```
pub fn detectLocal(environ: std.process.Environ) std.EnumSet(Agent) {
    var found: std.EnumSet(Agent) = .initEmpty();
    const path = std.process.Environ.getPosix(environ, "PATH") orelse return found;
    for (std.enums.values(Agent)) |agent| {
        if (onPath(path, installerFor(agent).command)) {
            found.insert(agent);
        }
    }

    return found;
}

fn onPath(path: []const u8, command: []const u8) bool {
    var directories = std.mem.splitScalar(u8, path, ':');
    while (directories.next()) |directory| {
        if (directory.len == 0) {
            continue;
        }

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrintZ(&buffer, "{s}/{s}", .{ directory, command }) catch continue;
        if (std.c.access(candidate, std.c.X_OK) == 0) {
            return true;
        }
    }

    return false;
}

/// Installs each wanted agent the machine lacks and returns whether any
/// installer ran, so the caller probes the machine again.
///
/// ```zig
/// const installed = try agent_setup.install(process_init, &report, "dev@box", &platform, wanted);
/// ```
pub fn install(init: std.process.Init, report: *SetupReport, destination: []const u8, platform: *const MachinePlatform, wanted: std.EnumSet(Agent)) !bool {
    if (wanted.count() == 0) {
        try report.end(.agents, .skipped, "no agent on this machine's PATH to install there", .{});
        return false;
    }

    var ran = false;
    var failed = false;
    var iterator = wanted.iterator();
    while (iterator.next()) |agent| {
        if (platform.agents.get(agent)) |*path| {
            try report.note(.agents, "{s}: already at {s}", .{ @tagName(agent), path.slice() });
            continue;
        }

        // A machine without what an installer needs is still ready for
        // telar: the note says what to add, and the next setup installs it.
        const installer = installerFor(agent);
        if (missingPrerequisite(platform, installer, agent)) |reason| {
            try report.note(.agents, "{s}: not installed: {s}", .{ @tagName(agent), reason });
            continue;
        }

        ran = true;
        try report.progress("installing {s} there with its official installer", .{@tagName(agent)});
        var script_buffer: [installer_prelude.len + max_installer_bytes]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buffer, "{s}{s}", .{ installer_prelude, installer.script }) catch unreachable;
        var result = remote_shell.runScript(init, destination, script, install_timeout_s) catch |err| {
            try report.note(.agents, "{s}: its installer did not run to the end: {s}", .{ @tagName(agent), @errorName(err) });
            failed = true;
            continue;
        };
        defer result.deinit(init.gpa);
        if (result.succeeded()) {
            try report.note(.agents, "{s}: installed with its official installer", .{@tagName(agent)});
        } else {
            try report.note(.agents, "{s}: its installer failed: {s}", .{ @tagName(agent), result.errorLine() });
            failed = true;
        }
    }

    var names_buffer: [names_bytes]u8 = undefined;
    const status: SetupReport.Status = if (failed) .failed else if (ran) .changed else .ok;
    try report.end(.agents, status, "{d} wanted: {s}", .{ wanted.count(), names(wanted, &names_buffer) });
    return ran;
}

// Why the machine cannot take this agent's installer yet, if it cannot.
fn missingPrerequisite(platform: *const MachinePlatform, installer: Installer, agent: Agent) ?[]const u8 {
    if (platform.libc == .musl and !installer.runs_on_musl) {
        return "its binary needs glibc and this machine has musl";
    }

    for (installer.tools) |tool| {
        if (!platform.tools.contains(tool)) {
            return switch (tool) {
                .curl => "curl is missing there",
                .bash => "bash is missing there",
                .tar => "tar is missing there",
                .node, .npm => "Node.js 22.19 or newer with npm is missing there; its installer would need sudo or a terminal to add it",
            };
        }
    }

    if (agent == .pi and !nodeRecentEnough(platform)) {
        return "Node.js there is older than 22.19";
    }

    return null;
}

fn nodeRecentEnough(platform: *const MachinePlatform) bool {
    const text = if (platform.node) |*value| value.slice() else return false;
    const version = std.mem.trimStart(u8, text, "v");
    var parts = std.mem.splitScalar(u8, version, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    return major > pi_node_major or (major == pi_node_major and minor >= pi_node_minor);
}

/// Runs `telar integration install` there for every agent the machine has,
/// with the executable setup installed, so hooks name that path.
///
/// ```zig
/// try agent_setup.integrate(process_init, &report, "dev@box", &platform);
/// ```
pub fn integrate(init: std.process.Init, report: *SetupReport, destination: []const u8, platform: *const MachinePlatform) !void {
    var present: std.EnumSet(Agent) = .initEmpty();
    for (std.enums.values(Agent)) |agent| {
        if (platform.agents.get(agent) != null) {
            present.insert(agent);
        }
    }

    if (present.count() == 0) {
        try report.end(.integrations, .skipped, "no agent there", .{});
        return;
    }

    var changed = false;
    var failed = false;
    var iterator = present.iterator();
    while (iterator.next()) |agent| {
        var script_buffer: [1024]u8 = undefined;
        var script: std.Io.Writer = .fixed(&script_buffer);
        try remote_shell.assign(&script, "telar", platform.target.slice());
        try remote_shell.assign(&script, "agent", @tagName(agent));
        try script.writeAll("exec \"$telar\" integration install \"$agent\"\n");

        var result = remote_shell.runScript(init, destination, script.buffered(), integration_timeout_s) catch |err| {
            try report.note(.integrations, "{s}: {s}", .{ @tagName(agent), @errorName(err) });
            failed = true;
            continue;
        };
        defer result.deinit(init.gpa);
        if (!result.succeeded()) {
            try report.note(.integrations, "{s}: {s}", .{ @tagName(agent), result.errorLine() });
            failed = true;
            continue;
        }

        const unchanged = std.mem.indexOf(u8, result.stdout, "already present") != null;
        changed = changed or !unchanged;
        try report.note(.integrations, "{s}: {s}", .{ @tagName(agent), if (unchanged) "already integrated" else "integrated" });
    }

    var names_buffer: [names_bytes]u8 = undefined;
    const status: SetupReport.Status = if (failed) .failed else if (changed) .changed else .ok;
    try report.end(.integrations, status, "{s}", .{names(present, &names_buffer)});
}

// The set's names, comma separated.
fn names(set: std.EnumSet(Agent), buffer: *[names_bytes]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    var iterator = set.iterator();
    var first = true;
    while (iterator.next()) |agent| {
        if (!first) {
            writer.writeAll(", ") catch {};
        }

        first = false;
        writer.writeAll(@tagName(agent)) catch {};
    }

    return writer.buffered();
}

test "the node pi needs is 22.19 or newer" {
    var platform: MachinePlatform = try .parse("os=Linux\narch=x86_64\nlibc=gnu\nhome=/h\ntarget=/h/t\nnode=v22.19.0\n");
    try std.testing.expect(nodeRecentEnough(&platform));
    platform = try .parse("os=Linux\narch=x86_64\nlibc=gnu\nhome=/h\ntarget=/h/t\nnode=v22.3.1\n");
    try std.testing.expect(!nodeRecentEnough(&platform));
    platform = try .parse("os=Linux\narch=x86_64\nlibc=gnu\nhome=/h\ntarget=/h/t\nnode=v24.0.0\n");
    try std.testing.expect(nodeRecentEnough(&platform));
}

test "a missing prerequisite is named instead of improvised" {
    const alpine = try MachinePlatform.parse("os=Linux\narch=aarch64\nlibc=musl\nhome=/h\ntarget=/h/t\ntool=curl\ntool=bash\ntool=tar\n");
    try std.testing.expectEqualStrings("its binary needs glibc and this machine has musl", missingPrerequisite(&alpine, installerFor(.cursor), .cursor).?);
    try std.testing.expect(std.mem.startsWith(u8, missingPrerequisite(&alpine, installerFor(.pi), .pi).?, "Node.js"));
    try std.testing.expectEqual(@as(?[]const u8, null), missingPrerequisite(&alpine, installerFor(.codex), .codex));

    const bare = try MachinePlatform.parse("os=Linux\narch=aarch64\nlibc=gnu\nhome=/h\ntarget=/h/t\n");
    try std.testing.expectEqualStrings("curl is missing there", missingPrerequisite(&bare, installerFor(.claude), .claude).?);
}

test "local agents are found on the PATH by their command" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var file = try temp.dir.createFile(std.testing.io, "codex", .{ .permissions = .fromMode(0o755) });
    file.close(std.testing.io);
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = directory_buffer[0..try temp.dir.realPath(std.testing.io, &directory_buffer)];

    try std.testing.expect(onPath(directory, "codex"));
    try std.testing.expect(!onPath(directory, "claude"));
    try std.testing.expect(!onPath("", "codex"));
}

test "every installer downloads over https only and stops when the download fails" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const io = std.testing.io;
    var bin_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const bin = bin_buffer[0..try temp.dir.realPath(io, &bin_buffer)];
    // A curl that fails as curl -f does on a 404, after writing nothing.
    var curl = try temp.dir.createFile(io, "curl", .{ .permissions = .fromMode(0o755) });
    try curl.writeStreamingAll(io, "#!/bin/sh\nexit 22\n");
    curl.close(io);

    for (std.enums.values(Agent)) |agent| {
        const installer = installerFor(agent);
        try std.testing.expect(installer.script.len <= max_installer_bytes);
        try std.testing.expect(std.mem.indexOf(u8, installer.script, "| sh") == null);
        try std.testing.expect(std.mem.indexOf(u8, installer.script, "| bash") == null);

        const script = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}echo installed\n", .{ installer_prelude, installer.script });
        defer std.testing.allocator.free(script);
        const path = try std.fmt.allocPrint(std.testing.allocator, "PATH={s}:/usr/bin:/bin", .{bin});
        defer std.testing.allocator.free(path);

        const result = try std.process.run(std.testing.allocator, io, .{
            .argv = &.{ "/usr/bin/env", "-i", path, "/bin/sh", "-c", script },
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);

        try std.testing.expect(result.term == .exited and result.term.exited != 0);
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, "installed") == null);
    }

    try std.testing.expect(std.mem.indexOf(u8, installer_prelude, "--proto '=https'") != null);
}
