//! `telar machine setup LABEL|DESTINATION` (docs/flows/machine-setup.md):
//! makes a machine this account reaches over SSH ready for the window in
//! one idempotent command. It checks batch-mode SSH, installs this exact
//! build of telar under the machine's home without sudo, saves its absolute
//! path in the profile so nothing depends on the machine's PATH, and checks
//! that a window can attach. Credentials never leave this machine: nothing
//! here reads a key, a token or an agent's auth file.
const build_options = @import("build_options");
const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const MachineOptions = @import("arguments/MachineOptions.zig");
const MachinePlatform = @import("MachinePlatform.zig");
const ScriptOutput = @import("ScriptOutput.zig");
const SetupReport = @import("SetupReport.zig");
const remote_shell = @import("remote_shell.zig");
const telar_release = @import("telar_release.zig");
const agent_setup = @import("agent_setup.zig");
const remote = client.remote;
const profile_file = client.profile_file;
const machine_profiles = client.machine_profiles;
const MachineEdit = client.MachineEdit;

/// The installer of this build, sent to the machine as the script it runs.
const installer = @embedFile("install.sh");
const version = build_options.version;

/// Exit status of a setup with a failed step.
const failure: u8 = 1;
/// Hex digits of the binary's hash in a development build's directory.
const build_hash_digits = 12;
/// Seconds a quick script and an install may take.
const probe_timeout_s = 60;
const install_timeout_s = 900;
/// How long a restarted runtime may take to accept the new telar.
const restart_attempts = 20;
const restart_wait_ms = 250;
/// What `telar server stop` prints once the runtime agreed to stop.
const stopping_text = "is stopping";

/// The machine one setup works on: a saved profile, or a destination that
/// becomes one.
const SetupTarget = struct {
    label_bytes: [core.MachineProfile.max_label_bytes]u8 = undefined,
    label_len: u8 = 0,
    destination_bytes: [core.ssh_destination.max_bytes]u8 = undefined,
    destination_len: u8 = 0,
    saved: ?core.MachineProfile = null,

    fn label(self: *const SetupTarget) []const u8 {
        return self.label_bytes[0..self.label_len];
    }

    fn destination(self: *const SetupTarget) []const u8 {
        return self.destination_bytes[0..self.destination_len];
    }
};

/// Where this build goes on the machine: `~/.local/share/telar/versions/DIR/telar`,
/// with DIR the version, or the version and the binary's hash for a
/// development build, so two builds never share a path.
const BuildDirectory = struct {
    bytes: [64]u8 = undefined,
    len: u8 = 0,
    /// `--binary` and its SHA-256, when given.
    binary_path: ?[]const u8 = null,
    binary_digest: ?[telar_release.digest_hex_bytes]u8 = null,

    fn slice(self: *const BuildDirectory) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Sets up the machine `options.label` names and returns the exit status.
///
/// ```zig
/// const status = try machine_setup.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: MachineOptions) !u8 {
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var report: SetupReport = .{
        .json = options.json,
        .writer = &output.interface,
    };

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try profile_file.path(init.minimal.environ, &path_buffer);
    const profiles = try profile_file.load(init.io, init.gpa, path);
    const target = try resolve(&profiles, std.mem.span(options.label.?), if (options.new_label) |text| std.mem.span(text) else null);

    const directory = try buildDirectory(init, options.binary);
    if (!options.json) {
        try output.interface.print("Setting up {s} ({s}) with telar {s}\n", .{ target.label(), target.destination(), version });
        try output.interface.flush();
    }

    const interactive = !options.json and (std.Io.File.stdin().isTty(init.io) catch false);
    const platform = try reach(init, &report, &target, directory.slice(), interactive) orelse return finish(&report, &target);
    const telar_path = platform.target.slice();
    if (!try installTelar(init, &report, &target, &platform, &directory)) {
        return finish(&report, &target);
    }

    if (!try startRuntime(init, &report, &target, telar_path, interactive)) {
        return finish(&report, &target);
    }

    try saveProfile(init, &report, &target, path, telar_path);
    var current = platform;
    if (options.skip.contains(.agents)) {
        try report.end(.agents, .skipped, "--skip agents", .{});
    } else if (try agent_setup.install(init, &report, target.destination(), &platform, agent_setup.detectLocal(init.minimal.environ))) {
        current = try probeAgain(init, &target, directory.slice()) orelse platform;
    }

    try agent_setup.integrate(init, &report, target.destination(), &current);
    try check(init, &report, &target, telar_path);
    return finish(&report, &target);
}

// What the machine has after installers ran; null keeps the first probe.
fn probeAgain(init: std.process.Init, target: *const SetupTarget, directory: []const u8) !?MachinePlatform {
    var script_buffer: [MachinePlatform.probe_script.len + 256]u8 = undefined;
    var script: std.Io.Writer = .fixed(&script_buffer);
    try remote_shell.assign(&script, "dir", directory);
    try script.writeAll(MachinePlatform.probe_script);

    var probe = try remote_shell.runScript(init, target.destination(), script.buffered(), probe_timeout_s);
    defer probe.deinit(init.gpa);
    if (!probe.succeeded()) {
        return null;
    }

    return MachinePlatform.parse(probe.stdout) catch null;
}

fn finish(report: *SetupReport, target: *const SetupTarget) !u8 {
    try report.finish(target.label(), target.destination());
    return if (report.failed()) failure else 0;
}

// A saved label, a saved destination, or a new destination whose label is
// `--label` or its host name.
fn resolve(profiles: *const core.MachineProfiles, name: []const u8, new_label: ?[]const u8) !SetupTarget {
    var target: SetupTarget = .{};
    for (profiles.slice()) |*profile| {
        if (std.mem.eql(u8, profile.label(), name) or std.mem.eql(u8, profile.destination(), name)) {
            target.saved = profile.*;
            try copyInto(&target.label_bytes, &target.label_len, profile.label());
            try copyInto(&target.destination_bytes, &target.destination_len, profile.destination());
            return target;
        }
    }

    try core.MachineProfile.validateDestination(name);
    try copyInto(&target.destination_bytes, &target.destination_len, name);
    var label_buffer: [core.MachineProfile.max_label_bytes]u8 = undefined;
    const label = new_label orelse try deriveLabel(name, &label_buffer);
    try core.MachineProfile.validateLabel(label);
    try copyInto(&target.label_bytes, &target.label_len, label);
    return target;
}

fn copyInto(buffer: []u8, len: *u8, text: []const u8) !void {
    if (text.len > buffer.len) {
        return error.NameTooLong;
    }

    @memcpy(buffer[0..text.len], text);
    len.* = @intCast(text.len);
}

/// A label for a destination: its host, without user, scheme or port,
/// with any character a label refuses turned into `-`.
///
/// ```zig
/// const label = try deriveLabel("ssh://dev@box.lan:2222", &buffer);  // "box.lan"
/// ```
fn deriveLabel(destination: []const u8, buffer: *[core.MachineProfile.max_label_bytes]u8) ![]const u8 {
    var host = destination;
    if (std.mem.startsWith(u8, host, "ssh://")) {
        host = host["ssh://".len..];
    }

    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| {
        host = host[at + 1 ..];
    }

    host = std.mem.trimStart(u8, host, "[");
    if (std.mem.indexOfAny(u8, host, ":]/")) |end| {
        host = host[0..end];
    }

    const len = @min(host.len, buffer.len);
    for (host[0..len], buffer[0..len]) |byte, *kept| {
        kept.* = if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-') byte else '-';
    }

    const label = buffer[0..len];
    core.MachineProfile.validateLabel(label) catch return error.MachineLabelNeeded;
    return label;
}

fn buildDirectory(init: std.process.Init, binary: ?[*:0]const u8) !BuildDirectory {
    var directory: BuildDirectory = .{};
    var writer: std.Io.Writer = .fixed(&directory.bytes);
    if (binary) |file| {
        const digest = telar_release.fileDigest(init.io, std.mem.span(file)) catch return error.SetupBinaryUnreadable;
        directory.binary_path = std.mem.span(file);
        directory.binary_digest = digest;
        try writer.print("{s}-{s}", .{ version, digest[0..build_hash_digits] });
    } else {
        try writer.writeAll(version);
    }

    directory.len = @intCast(writer.buffered().len);
    return directory;
}

// Steps 1 and 2: batch-mode SSH, then the probe. A refused host key or
// login with a terminal attached gets one interactive attempt, where
// OpenSSH asks the person and telar answers nothing.
fn reach(init: std.process.Init, report: *SetupReport, target: *const SetupTarget, directory: []const u8, interactive: bool) !?MachinePlatform {
    var script_buffer: [MachinePlatform.probe_script.len + 256]u8 = undefined;
    var script: std.Io.Writer = .fixed(&script_buffer);
    try remote_shell.assign(&script, "dir", directory);
    try script.writeAll(MachinePlatform.probe_script);

    var probe = try remote_shell.runScript(init, target.destination(), script.buffered(), probe_timeout_s);
    defer probe.deinit(init.gpa);

    var confirmed = false;
    if (!probe.succeeded() and interactive and refusedLogin(&probe)) {
        confirmed = try confirmInteractively(init, report, target);
        if (confirmed) {
            probe.deinit(init.gpa);
            probe = try remote_shell.runScript(init, target.destination(), script.buffered(), probe_timeout_s);
        }
    }

    if (!probe.succeeded()) {
        try reportUnreachable(report, target, &probe, confirmed);
        return null;
    }

    try report.end(.ssh, if (confirmed) .changed else .ok, "batch-mode SSH to {s} works", .{target.destination()});
    const platform = MachinePlatform.parse(probe.stdout) catch |err| {
        try report.end(.platform, .failed, "{s}: {s}", .{ @errorName(err), firstLine(probe.stdout) });
        return null;
    };

    const system = switch (platform.os) {
        .linux => "Linux",
        .macos => "macOS",
    };
    const libc = if (platform.libc == .musl) " (musl)" else "";
    try report.end(.platform, .ok, "{s} {s}{s}, {s}", .{ system, @tagName(platform.arch), libc, platform.assetName() });

    return platform;
}

fn refusedLogin(probe: *const ScriptOutput) bool {
    const failed = remote.sshFailure(probe.term, probe.stderr);
    return failed == error.SshHostKeyRejected or failed == error.SshAuthenticationFailed;
}

// Runs `ssh DESTINATION true` with the person's terminal and no control
// master, so what batch mode refused is asked of them, and a password typed
// here never leaves a connection batch mode could reuse.
fn confirmInteractively(init: std.process.Init, report: *SetupReport, target: *const SetupTarget) !bool {
    try report.writer.print(
        "Batch-mode SSH to {s} was refused. Connecting once with your terminal: OpenSSH asks, you answer; telar accepts nothing for you.\n",
        .{target.destination()},
    );
    try report.writer.flush();

    var child = try std.process.spawn(init.io, .{
        .argv = &.{ "ssh", "-o", "ControlPath=none", "-o", "ForwardAgent=no", "--", target.destination(), "true" },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(init.io);
    return term == .exited and term.exited == 0;
}

fn reportUnreachable(report: *SetupReport, target: *const SetupTarget, probe: *const ScriptOutput, confirmed: bool) !void {
    const failed = remote.sshFailure(probe.term, probe.stderr);
    if (probe.term == .exited and probe.term.exited != @intFromEnum(SshExit.failed) and failed != error.RemoteRuntimeIncompatible) {
        try report.end(.ssh, .ok, "batch-mode SSH to {s} works", .{target.destination()});
        try report.end(.platform, .failed, "the probe failed there: {s}", .{probe.errorLine()});
        return;
    }

    switch (failed) {
        error.SshAuthenticationFailed => {
            if (confirmed) {
                try report.end(.ssh, .failed, "{s} accepts your login only interactively; windows need a key. Run `ssh-copy-id {s}`, then setup again", .{ target.destination(), target.destination() });
            } else {
                try report.end(.ssh, .failed, "{s} refused the login in batch mode; add a key with `ssh-copy-id {s}` or run setup from a terminal", .{ target.destination(), target.destination() });
            }
        },
        error.SshHostKeyRejected => try report.end(.ssh, .failed, "the host key of {s} is not confirmed: {s}", .{ target.destination(), probe.errorLine() }),
        else => try report.end(.ssh, .failed, "{s}", .{probe.errorLine()}),
    }
}

/// OpenSSH's own failures exit 255 (ssh(1), EXIT STATUS).
const SshExit = enum(u8) {
    failed = 255,
    _,
};

// Step 3: this build at its own path, downloaded there from the release
// with the hash this machine read, or uploaded with `--binary`.
fn installTelar(init: std.process.Init, report: *SetupReport, target: *const SetupTarget, platform: *const MachinePlatform, directory: *const BuildDirectory) !bool {
    const telar_path = platform.target.slice();
    core.remote_telar.validate(telar_path) catch {
        try report.end(.telar, .failed, "{s} holds a character a remote command cannot carry unquoted; telar needs a home of letters, digits and /._+-", .{telar_path});
        return false;
    };

    if (platform.installedVersion(version)) {
        try report.end(.telar, .ok, "telar {s} at {s}", .{ version, telar_path });
        return true;
    }

    var script_buffer: [installer.len + 2048]u8 = undefined;
    var script: std.Io.Writer = .fixed(&script_buffer);
    if (directory.binary_digest) |*digest| {
        if (!try upload(init, report, target, directory)) {
            return false;
        }

        try script.print("upload=$HOME/.local/share/telar/versions/.upload-{s}\n", .{digest[0..build_hash_digits]});
        try remote_shell.assign(&script, "digest", digest);
        try remote_shell.assign(&script, "bin_dir", std.fs.path.dirname(telar_path).?);
        try script.writeAll("(\nset -- --binary \"$upload\" --sha256 \"$digest\" --bin-dir \"$bin_dir\"\n");
    } else {
        if (!telar_release.released(version)) {
            try report.end(.telar, .failed, "this is a development build ({s}) with no release to download; pass --binary with a telar built for {s} {s}", .{ version, @tagName(platform.os), @tagName(platform.arch) });
            return false;
        }

        if (!platform.tools.contains(.curl)) {
            try report.end(.telar, .failed, "{s} has no curl, which the installer needs to download the release; install curl there, or pass --binary", .{target.label()});
            return false;
        }

        const digest = telar_release.fetchDigest(init, version, platform.assetName()) catch |err| {
            try report.end(.telar, .failed, "{s}: cannot read the hash of {s} from release {s} at {s}", .{ @errorName(err), platform.assetName(), version, telar_release.releasesUrl(init.minimal.environ) });
            return false;
        };

        try remote_shell.assign(&script, "upload", "");
        try remote_shell.assign(&script, "digest", &digest);
        try remote_shell.assign(&script, "version", version);
        try remote_shell.assign(&script, "bin_dir", std.fs.path.dirname(telar_path).?);
        if (std.process.Environ.getPosix(init.minimal.environ, "TELAR_RELEASES_URL")) |url| {
            try remote_shell.assign(&script, "TELAR_RELEASES_URL", url);
            try script.writeAll("export TELAR_RELEASES_URL\n");
        }

        try script.writeAll("(\nset -- --version \"$version\" --sha256 \"$digest\" --bin-dir \"$bin_dir\"");
        if (platform.os == .linux) {
            try script.writeAll(" --headless");
        }

        try script.writeByte('\n');
    }

    // The installer runs in a subshell, so its exit and traps end there and
    // the upload is removed whatever it decided.
    try script.writeAll(installer);
    try script.writeAll(
        \\
        \\)
        \\status=$?
        \\if [ -n "$upload" ]; then rm -f "$upload"; fi
        \\exit $status
        \\
    );

    var result = try remote_shell.runScript(init, target.destination(), script.buffered(), install_timeout_s);
    defer result.deinit(init.gpa);
    if (!result.succeeded()) {
        try report.end(.telar, .failed, "the installer refused: {s}", .{result.errorLine()});
        return false;
    }

    try report.end(.telar, .changed, "installed telar {s} at {s}", .{ version, telar_path });
    try linkCommand(init, report, target, telar_path);
    return true;
}

// Streams `--binary` into an owner-only file under the machine's telar
// directory, over the same SSH connection.
fn upload(init: std.process.Init, report: *SetupReport, target: *const SetupTarget, directory: *const BuildDirectory) !bool {
    const digest = &directory.binary_digest.?;
    var command_buffer: [256]u8 = undefined;
    const command = try std.fmt.bufPrint(
        &command_buffer,
        "exec /bin/sh -c 'umask 077 && mkdir -p \"$HOME/.local/share/telar/versions\" && exec cat > \"$HOME/.local/share/telar/versions/.upload-{s}\"'",
        .{digest[0..build_hash_digits]},
    );

    const binary = std.Io.Dir.cwd().openFile(init.io, directory.binary_path.?, .{}) catch |err| {
        try report.end(.telar, .failed, "{s}: cannot open --binary", .{@errorName(err)});
        return false;
    };
    defer binary.close(init.io);

    var result = try remote_shell.runWithInput(init, target.destination(), command, binary, install_timeout_s);
    defer result.deinit(init.gpa);
    if (!result.succeeded()) {
        try report.end(.telar, .failed, "the upload failed: {s}", .{result.errorLine()});
        return false;
    }

    return true;
}

// Links `~/.local/bin/telar` there to the new executable, so interactive
// shells find the same build. `telar cli install` replaces only a symlink.
fn linkCommand(init: std.process.Init, report: *SetupReport, target: *const SetupTarget, telar_path: []const u8) !void {
    var script_buffer: [512]u8 = undefined;
    var script: std.Io.Writer = .fixed(&script_buffer);
    try remote_shell.assign(&script, "telar", telar_path);
    try script.writeAll("mkdir -p \"$HOME/.local/bin\" && \"$telar\" cli install --dir \"$HOME/.local/bin\"\n");

    var result = try remote_shell.runScript(init, target.destination(), script.buffered(), probe_timeout_s);
    defer result.deinit(init.gpa);
    if (result.succeeded()) {
        try report.note(.telar, "~/.local/bin/telar links to it", .{});
    } else {
        try report.note(.telar, "~/.local/bin/telar left as it was: {s}", .{result.errorLine()});
    }
}

// Step 4: the runtime answers the new telar. One of another build keeps
// running unless the person, asked on a terminal, agrees to stop it.
fn startRuntime(init: std.process.Init, report: *SetupReport, target: *const SetupTarget, telar_path: []const u8, interactive: bool) !bool {
    var detail_buffer: [1024]u8 = undefined;
    var detail: std.Io.Writer = .fixed(&detail_buffer);
    const machine: client.RemoteMachine = .{
        .destination = target.destination(),
        .telar_path = telar_path,
    };

    const found = remote.discover(init.io, init.gpa, init.minimal.environ, machine, &detail) catch |err| {
        if (err != error.RemoteRuntimeIncompatible) {
            try report.end(.runtime, .failed, "{s}: {s}", .{ @errorName(err), std.mem.trim(u8, detail.buffered(), " \n") });
            return false;
        }

        if (!interactive or !try askToStop(init, report, target)) {
            try report.end(.runtime, .failed, "a runtime of another telar build runs there and keeps its panes; this build cannot attach until it stops. Run setup again from a terminal and agree to stop it", .{});
            return false;
        }

        return stopOldRuntime(init, report, target, machine);
    };

    if (!found.compatible()) {
        try report.end(.runtime, .failed, "the telar at {s} speaks wire schema {s}, this one {s}; pass a --binary built from this tree", .{ telar_path, &found.schema, &core.schema_id });
        return false;
    }

    try report.end(.runtime, .ok, "running at {s}", .{found.endpoint()});
    return true;
}

fn askToStop(init: std.process.Init, report: *SetupReport, target: *const SetupTarget) !bool {
    try report.writer.print(
        "A telar runtime of another build runs on {s}. Stopping it ends every pane and agent it runs. Stop it now? [y/N] ",
        .{target.label()},
    );
    try report.writer.flush();

    var line_buffer: [16]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &line_buffer);
    const answer = stdin.interface.takeDelimiterExclusive('\n') catch return false;
    const trimmed = std.mem.trim(u8, answer, " \r\t");
    return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
}

// Asks every other telar there to stop its runtime: only the build that
// started it completes the handshake. Then waits for the new one.
fn stopOldRuntime(init: std.process.Init, report: *SetupReport, target: *const SetupTarget, machine: client.RemoteMachine) !bool {
    var script_buffer: [1024]u8 = undefined;
    var script: std.Io.Writer = .fixed(&script_buffer);
    try remote_shell.assign(&script, "target", machine.telar_path.?);
    try remote_shell.assign(&script, "stopping", stopping_text);
    try script.writeAll(
        \\for candidate in "$HOME"/.local/share/telar/versions/*/telar $(command -v telar 2>/dev/null); do
        \\    [ -x "$candidate" ] && [ "$candidate" != "$target" ] || continue
        \\    if "$candidate" server stop 2>/dev/null | grep -q "$stopping"; then
        \\        exit 0
        \\    fi
        \\done
        \\echo 'no telar there could stop the running runtime' >&2
        \\exit 1
        \\
    );

    var result = try remote_shell.runScript(init, target.destination(), script.buffered(), probe_timeout_s);
    defer result.deinit(init.gpa);
    if (!result.succeeded()) {
        try report.end(.runtime, .failed, "{s}", .{result.errorLine()});
        return false;
    }

    var detail_buffer: [1024]u8 = undefined;
    for (0..restart_attempts) |_| {
        var detail: std.Io.Writer = .fixed(&detail_buffer);
        if (remote.discover(init.io, init.gpa, init.minimal.environ, machine, &detail)) |found| {
            if (found.compatible()) {
                try report.end(.runtime, .changed, "stopped the runtime of another build; this one runs at {s}", .{found.endpoint()});
                return true;
            }
        } else |_| {}

        try init.io.sleep(.fromMilliseconds(restart_wait_ms), .awake);
    }

    try report.end(.runtime, .failed, "the old runtime stopped but this build's did not answer", .{});
    return false;
}

// Step 5: the profile names the machine, its telar and is enabled, so
// every window connects to it.
fn saveProfile(init: std.process.Init, report: *SetupReport, target: *const SetupTarget, path: []const u8, telar_path: []const u8) !void {
    var edits: [3]MachineEdit = undefined;
    var count: usize = 0;
    const saved = target.saved;
    if (saved == null) {
        edits[count] = .{
            .kind = .add,
            .label = target.label(),
            .value = target.destination(),
        };
        count += 1;
    }

    const current_path = if (saved) |*profile| profile.telarPath() else null;
    if (current_path == null or !std.mem.eql(u8, current_path.?, telar_path)) {
        edits[count] = .{
            .kind = .place_telar,
            .label = target.label(),
            .value = telar_path,
        };
        count += 1;
    }

    if (saved != null and !saved.?.enabled) {
        edits[count] = .{
            .kind = .enable,
            .label = target.label(),
        };
        count += 1;
    }

    if (count == 0) {
        try report.end(.profile, .ok, "{s} is saved, enabled and names {s}", .{ target.label(), telar_path });
        return;
    }

    machine_profiles.storeAll(init.io, init.gpa, path, edits[0..count]) catch |err| {
        try report.end(.profile, .failed, "{s}", .{machine_profiles.describe(err)});
        return;
    };

    try report.end(.profile, .changed, "{s} {s}, enabled, telar at {s}", .{ target.label(), if (saved == null) "saved" else "updated", telar_path });
}

// Step 10: what a window does first, through the saved path.
fn check(init: std.process.Init, report: *SetupReport, target: *const SetupTarget, telar_path: []const u8) !void {
    var detail_buffer: [1024]u8 = undefined;
    var detail: std.Io.Writer = .fixed(&detail_buffer);
    const found = remote.discover(init.io, init.gpa, init.minimal.environ, .{
        .destination = target.destination(),
        .telar_path = telar_path,
    }, &detail) catch |err| {
        try report.end(.check, .failed, "{s}: {s}", .{ @errorName(err), std.mem.trim(u8, detail.buffered(), " \n") });
        return;
    };

    if (!found.compatible()) {
        try report.end(.check, .failed, "schema {s} there, {s} here", .{ &found.schema, &core.schema_id });
        return;
    }

    try report.end(.check, .ok, "a window can attach: schema {s} on both sides", .{&core.schema_id});
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

test "a destination becomes a label from its host" {
    var buffer: [core.MachineProfile.max_label_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("box.lan", try deriveLabel("dev@box.lan", &buffer));
    try std.testing.expectEqualStrings("box", try deriveLabel("ssh://dev@box:2222", &buffer));
    try std.testing.expectEqualStrings("2001", try deriveLabel("dev@[2001:db8::1]", &buffer));
    try std.testing.expectEqualStrings("my-box", try deriveLabel("dev@my+box", &buffer));
    try std.testing.expectError(error.MachineLabelNeeded, deriveLabel("dev@-box", &buffer));
}

test "setup finds a saved machine by label or destination, or names a new one" {
    var profiles: core.MachineProfiles = .{};
    try profiles.add(try core.MachineProfile.init(@enumFromInt(1), .{
        .label = "box",
        .destination = "dev@box",
    }));

    const by_label = try resolve(&profiles, "box", null);
    try std.testing.expect(by_label.saved != null);
    try std.testing.expectEqualStrings("dev@box", by_label.destination());

    const by_destination = try resolve(&profiles, "dev@box", null);
    try std.testing.expectEqualStrings("box", by_destination.label());

    const fresh = try resolve(&profiles, "ops@gpu.lan", null);
    try std.testing.expect(fresh.saved == null);
    try std.testing.expectEqualStrings("gpu.lan", fresh.label());

    const named = try resolve(&profiles, "ops@gpu.lan", "gpu");
    try std.testing.expectEqualStrings("gpu", named.label());
    try std.testing.expectError(error.InvalidRemoteDestination, resolve(&profiles, "-oProxyCommand=x", null));
}

test "the line kept from unreadable output is the first" {
    try std.testing.expectEqualStrings("one", firstLine("one\ntwo\n"));
}
