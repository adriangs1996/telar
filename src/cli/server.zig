//! Composition of the long-lived runtime process selected by `telar server`.

const backend = @import("telar-backend");
const core = @import("telar-core");
const client = @import("telar-client");
const std = @import("std");
const ServerOptions = @import("arguments/ServerOptions.zig");
const RuntimeConnector = client.RuntimeConnector;
const ServerLaunch = @import("ServerLaunch.zig");
const runtime_bridge = @import("runtime_bridge.zig");
const ProxyAuthorityNames = @import("ProxyAuthorityNames.zig");
const HistoryPath = @import("HistoryPath.zig");
const TestEnvironment = @import("TestEnvironment.zig");

const privatefile = @import("privatefile");
const Inode = privatefile.Inode;

/// Executes the selected server action. A running action prepares persistent
/// paths, initializes one public Runtime with production dependencies and owns
/// its complete `init`, `run`, `deinit` lifecycle. A runtime whose teardown
/// left proxy tunnels running exits here instead of returning.
///
/// ```zig
/// try server.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: ServerOptions) !void {
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, options.socket);
    if (options.action == .stop) {
        return stop(init, &connector);
    }
    if (options.action == .endpoint) {
        return printEndpoint(init, &connector);
    }
    if (options.action == .bridge) {
        return runtime_bridge.relay(init.io, &connector);
    }

    var launch: ServerLaunch = undefined;
    try launch.prepare(.{
        .process = init,
        .options = options,
        .connector = connector,
    });
    defer launch.deinit();

    if (launch.options.mode == .background_launcher) {
        return launch.launchDaemon();
    }

    var runtime: backend.Runtime = undefined;
    try runtime.init(launch.runtimeInitialization());
    const ended = runtime.run();
    runtime.deinit();
    if (runtime.leftProxyTunnels()) {
        launch.removeTapSnapshot();
        exitPastProxyTunnels(ended);
    }

    return ended;
}

/// Ends the process of a runtime whose teardown left proxy tunnels inside
/// calls nothing interrupts, such as the system resolver. Returning from
/// `main` would wait for their threads, since the process's `Io` joins every
/// thread it started. The teardown that ran is complete: the session
/// checkpoint was written before the proxy stopped, history, plugins and
/// the socket were released after it, and a tunnel writes no file. The
/// runtime, its allocator and the configuration the tunnels borrow host
/// names from stay in place until the process is gone.
fn exitPastProxyTunnels(ended: anyerror!void) noreturn {
    ended catch |err| {
        std.debug.print("telar runtime: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(RuntimeExit.failed));
    };

    std.process.exit(@intFromEnum(RuntimeExit.stopped));
}

/// The exit status of a runtime that exits past its proxy tunnels: the one
/// returning from `main` would have given.
const RuntimeExit = enum(u8) {
    stopped = 0,
    failed = 1,
};

/// Ensures the runtime is running and prints its socket path, then the wire
/// schema this `telar` speaks, one per line. A client runs this over SSH to
/// discover a remote machine (`Discovery.parse`).
fn printEndpoint(init: std.process.Init, connector: *const RuntimeConnector) !void {
    var connection = try connector.connectOrStart(.{});
    connection.deinit(init.io);

    var buffer: [std.fs.max_path_bytes + 1 + core.schema_id.len + 1]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{s}\n{s}\n", .{ connector.endpointPath(), &core.schema_id });
    try std.Io.File.stdout().writeStreamingAll(init.io, line);
}

pub fn grantedCapabilities(trust: *const core.TrustStore, package: *const client.Package) core.CapabilitySet {
    var granted = core.CapabilitySet.initEmpty();
    for (trust.entries[0..trust.count]) |entry| {
        if (entry.grant.plugin_hash != core.stableId(package.manifest.id())) {
            continue;
        }
        if (!std.mem.eql(u8, &entry.grant.digest, &package.digest)) {
            continue;
        }
        granted.setUnion(entry.grant.capabilities);
    }
    return granted;
}

fn stop(init: std.process.Init, connector: *const RuntimeConnector) !void {
    var connection = connector.connect() catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {
            try std.Io.File.stdout().writeStreamingAll(init.io, "telar runtime is not running\n");
            return;
        },
        else => |other| return other,
    };
    defer connection.deinit(init.io);

    var send_buffer: [1]u8 = undefined;
    try connection.send(init.io, try core.encodeRuntimeStop(&send_buffer));

    var receive_buffer: [2048]u8 = undefined;
    switch (try core.decodeServer(try connection.receive(init.io, &receive_buffer))) {
        .runtime_stopping => try std.Io.File.stdout().writeStreamingAll(init.io, "telar runtime is stopping\n"),
        .request_failed => |failure| {
            std.debug.print("telar runtime: {s}\n", .{failure.message});
            return error.RuntimeRequestFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

/// Renames the session checkpoint at `path` to `<path>.previous` so a fresh
/// runtime starts empty without destroying the session it replaces. The
/// runtime persists to `path` again, so the previous session survives exactly
/// one fresh start. Returns false when there was nothing to set aside.
///
/// ```zig
/// const kept = try setSessionAside(io, "/home/me/.local/share/telar/session.ckpt");
/// ```
pub fn setSessionAside(io: std.Io, path: []const u8) !bool {
    var previous_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const previous = try std.fmt.bufPrint(&previous_buffer, "{s}.previous", .{path});
    std.Io.Dir.renameAbsolute(path, previous, io) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return true;
}

pub fn resolveConfigPath(gpa: std.mem.Allocator, config_directory: []const u8, configured_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(configured_path)) {
        return gpa.dupe(u8, configured_path);
    }

    return std.fs.path.resolve(gpa, &.{ config_directory, configured_path });
}

/// The proxy directory when configuration names none, shared by the server
/// and `telar proxy trust`: `$XDG_DATA_HOME/telar/proxy`, else
/// `$HOME/.local/share/telar/proxy`. A relative `XDG_DATA_HOME` is ignored, as
/// the XDG base directory specification requires.
///
/// ```zig
/// const directory = try server.resolveProxyDirectory(environ, &buffer);
/// ```
pub fn resolveProxyDirectory(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    if (environ.getPosix("XDG_DATA_HOME")) |base| {
        if (std.fs.path.isAbsolute(base)) {
            return std.fmt.bufPrint(buffer, "{s}/telar/proxy", .{base});
        }
    }

    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    if (home.len == 0) {
        return error.HomeDirectoryUnavailable;
    }

    return std.fmt.bufPrint(buffer, "{s}/.local/share/telar/proxy", .{home});
}

pub fn proxyAuthorityNames(system_trusted: bool) ProxyAuthorityNames {
    if (system_trusted) {
        return .{ .key = "ca-system-key.pem", .certificate = "ca-system-cert.pem" };
    }

    return .{ .key = "ca-key.pem", .certificate = "ca-cert.pem" };
}

pub fn prepareProxyDirectory(io: std.Io, directory: []const u8) !void {
    const permissions = std.Io.File.Permissions.fromMode(0o700);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, directory, permissions);
    const stat = try std.Io.Dir.cwd().statFile(io, directory, .{ .follow_symlinks = false });
    if (stat.kind != .directory) {
        return error.InvalidProxyDirectory;
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{directory}) catch return error.ProxyPathTooLong;
    const inode = Inode.fromPath(path_z, .no_follow) catch return error.InvalidProxyDirectory;
    try checkDirectoryOwner(inode.owner, std.c.getuid());
    try std.Io.Dir.cwd().setFilePermissions(io, directory, permissions, .{ .follow_symlinks = false });
}

pub fn resolveHistoryPath(environ: std.process.Environ, buffer: []u8) !HistoryPath {
    if (environ.getPosix("TELAR_HISTORY")) |path| {
        if (path.len != 0) {
            return .{
                .path = try std.fmt.bufPrintZ(buffer, "{s}", .{path}),
                .managed_directory = null,
            };
        }
    }

    if (environ.getPosix("XDG_DATA_HOME")) |base| {
        if (base.len != 0) {
            const directory = try std.fmt.bufPrint(buffer, "{s}/telar", .{base});
            const path = try std.fmt.bufPrintZ(buffer[directory.len..], "/history.db", .{});
            return .{
                .path = buffer[0 .. directory.len + path.len :0],
                .managed_directory = directory,
            };
        }
    }

    const home = environ.getPosix("HOME") orelse return error.HomeDirectoryUnavailable;
    if (home.len == 0) {
        return error.HomeDirectoryUnavailable;
    }
    const directory = try std.fmt.bufPrint(buffer, "{s}/.local/share/telar", .{home});
    const path = try std.fmt.bufPrintZ(buffer[directory.len..], "/history.db", .{});
    return .{
        .path = buffer[0 .. directory.len + path.len :0],
        .managed_directory = directory,
    };
}

pub fn prepareHistoryDatabase(io: std.Io, history_path: HistoryPath) !void {
    if (history_path.managed_directory) |directory| {
        const permissions = std.Io.File.Permissions.fromMode(0o700);
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, directory, permissions);
        try std.Io.Dir.cwd().setFilePermissions(io, directory, permissions, .{ .follow_symlinks = false });
    }

    const file = try std.Io.Dir.createFileAbsolute(io, history_path.path, .{
        .read = true,
        .truncate = false,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    file.close(io);
    try std.Io.Dir.cwd().setFilePermissions(io, history_path.path, std.Io.File.Permissions.fromMode(0o600), .{ .follow_symlinks = false });
}

fn checkDirectoryOwner(owner: std.c.uid_t, current_user: std.c.uid_t) error{WrongOwner}!void {
    if (owner != current_user) {
        return error.WrongOwner;
    }
}

fn temporaryDirectory(temp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try temp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

test "explicit history storage overrides XDG data storage" {
    var environment = try TestEnvironment.init(&.{
        .{ .name = "TELAR_HISTORY", .value = "/var/lib/telar/history.db" },
        .{ .name = "XDG_DATA_HOME", .value = "/data" },
    });
    defer environment.deinit();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    const history = try resolveHistoryPath(.{ .block = environment.block }, &buffer);

    try std.testing.expectEqualStrings("/var/lib/telar/history.db", history.path);
    try std.testing.expect(history.managed_directory == null);
}

test "history and proxy storage prefer XDG data home" {
    var environment = try TestEnvironment.init(&.{
        .{ .name = "XDG_DATA_HOME", .value = "/data" },
        .{ .name = "HOME", .value = "/home/adrian" },
    });
    defer environment.deinit();
    const environ: std.process.Environ = .{ .block = environment.block };
    var history_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var proxy_buffer: [std.fs.max_path_bytes]u8 = undefined;

    const history = try resolveHistoryPath(environ, &history_buffer);

    try std.testing.expectEqualStrings("/data/telar", history.managed_directory.?);
    try std.testing.expectEqualStrings("/data/telar/history.db", history.path);
    try std.testing.expectEqualStrings("/data/telar/proxy", try resolveProxyDirectory(environ, &proxy_buffer));
}

test "a relative XDG data home is ignored for the proxy directory" {
    var environment = try TestEnvironment.init(&.{
        .{ .name = "XDG_DATA_HOME", .value = "data" },
        .{ .name = "HOME", .value = "/home/adrian" },
    });
    defer environment.deinit();
    const environ: std.process.Environ = .{ .block = environment.block };
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("/home/adrian/.local/share/telar/proxy", try resolveProxyDirectory(environ, &buffer));
}

test "runtime selects the installed system authority without reusing the private CA" {
    const private = proxyAuthorityNames(false);
    const system = proxyAuthorityNames(true);

    try std.testing.expectEqualStrings("ca-key.pem", private.key);
    try std.testing.expectEqualStrings("ca-cert.pem", private.certificate);
    try std.testing.expectEqualStrings("ca-system-key.pem", system.key);
    try std.testing.expectEqualStrings("ca-system-cert.pem", system.certificate);
}

test "relative configured paths resolve from the config directory" {
    const relative = try resolveConfigPath(std.testing.allocator, "/config/telar", "state/history.db");
    defer std.testing.allocator.free(relative);
    const absolute = try resolveConfigPath(std.testing.allocator, "/ignored", "/state/proxy");
    defer std.testing.allocator.free(absolute);

    try std.testing.expectEqualStrings("/config/telar/state/history.db", relative);
    try std.testing.expectEqualStrings("/state/proxy", absolute);
}

test "runtime storage creates private history and proxy paths" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryDirectory(&temp, &root_buffer);
    var history_directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const history_directory = try std.fmt.bufPrint(&history_directory_buffer, "{s}/state", .{root});
    var history_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const history_path = try std.fmt.bufPrintZ(&history_path_buffer, "{s}/history.db", .{history_directory});
    var proxy_directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const proxy_directory = try std.fmt.bufPrint(&proxy_directory_buffer, "{s}/proxy", .{root});

    try prepareHistoryDatabase(std.testing.io, .{
        .path = history_path,
        .managed_directory = history_directory,
    });
    try prepareProxyDirectory(std.testing.io, proxy_directory);

    const history_directory_stat = try std.Io.Dir.cwd().statFile(std.testing.io, history_directory, .{ .follow_symlinks = false });
    const history_stat = try std.Io.Dir.cwd().statFile(std.testing.io, history_path, .{ .follow_symlinks = false });
    const proxy_stat = try std.Io.Dir.cwd().statFile(std.testing.io, proxy_directory, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o700), history_directory_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o600), history_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o700), proxy_stat.permissions.toMode() & 0o777);
}

test "a fresh start sets the previous session aside once" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryDirectory(&temp, &root_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/session.ckpt", .{root});
    var previous_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const previous = try std.fmt.bufPrint(&previous_buffer, "{s}/session.ckpt.previous", .{root});
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "session.ckpt", .data = "session" });

    try std.testing.expect(try setSessionAside(std.testing.io, path));

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path, .{ .follow_symlinks = false }));
    const moved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, previous, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(moved);
    try std.testing.expectEqualStrings("session", moved);
    try std.testing.expect(!try setSessionAside(std.testing.io, path));
}

test "runtime storage rejects directories owned by another user" {
    try checkDirectoryOwner(1000, 1000);
    try std.testing.expectError(error.WrongOwner, checkDirectoryOwner(0, 1000));
}
