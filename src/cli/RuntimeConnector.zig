const RuntimeConnector = @This();
const std = @import("std");
const core = @import("telar-core");
const source_namespace = @import("runtime_connection.zig");
const frontend = @import("telar-frontend");
const RuntimeConfigSelection = @import("RuntimeConfigSelection.zig");
process: std.process.Init,
endpoint: core.endpoint.Local,

/// Resolves the local runtime endpoint from an explicit socket or the
/// process environment. It does not access the filesystem or connect yet.
///
/// ```zig
/// const connector = try RuntimeConnector.init(process_init, null);
/// ```
pub fn init(process: std.process.Init, override: ?[*:0]const u8) !RuntimeConnector {
    return .{
        .process = process,
        .endpoint = try source_namespace.resolveEndpoint(process.minimal.environ, override),
    };
}

/// Returns the resolved Unix socket path borrowed from this connector.
///
/// ```zig
/// const path = connector.endpointPath();
/// ```
pub fn endpointPath(connector: *const RuntimeConnector) []const u8 {
    return connector.endpoint.path();
}

/// Creates and validates Telar's managed socket directory before a runtime
/// binds its listener. Explicit socket paths require no directory work.
///
/// ```zig
/// try connector.prepareServerDirectory();
/// ```
pub fn prepareServerDirectory(connector: *const RuntimeConnector) !void {
    const directory = connector.endpoint.managedDirectory() orelse return;
    const permissions = source_namespace.File.Permissions.fromMode(0o700);
    source_namespace.Io.Dir.createDirAbsolute(connector.process.io, directory, permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |other| return other,
    };

    const stat = try source_namespace.Io.Dir.cwd().statFile(connector.process.io, directory, .{ .follow_symlinks = false });
    if (stat.kind != .directory) {
        return error.InvalidRuntimeDirectory;
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{directory}) catch
        return error.NameTooLong;
    var native_stat: source_namespace.native.struct_stat = undefined;
    if (source_namespace.native.fstatat(std.c.AT.FDCWD, directory_z, &native_stat, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
        return error.InvalidRuntimeDirectory;
    }

    try source_namespace.checkRuntimeDirectoryOwner(native_stat.st_uid, std.c.getuid());

    try source_namespace.Io.Dir.cwd().setFilePermissions(connector.process.io, directory, permissions, .{ .follow_symlinks = false });
}

/// Connects to an already running runtime and completes schema negotiation.
/// It never starts a missing runtime.
///
/// ```zig
/// var connection = try connector.connect();
/// defer connection.deinit(process_init.io);
/// ```
pub fn connect(connector: *const RuntimeConnector) !core.transport.SocketChannel {
    const connection = try frontend.transport.local.connect(connector.process.io, connector.endpoint.path());
    return connector.finishHandshake(connection);
}

/// Connects to the local runtime, starting it with the selected config when
/// no listener is available, then waits for its bounded startup window.
///
/// ```zig
/// var connection = try connector.connectOrStart(.{});
/// defer connection.deinit(process_init.io);
/// ```
pub fn connectOrStart(connector: *const RuntimeConnector, config: RuntimeConfigSelection) !core.transport.SocketChannel {
    const first = frontend.transport.local.connect(connector.process.io, connector.endpoint.path()) catch |err| switch (err) {
        error.PermissionDenied,
        error.NotDir,
        error.SymLinkLoop,
        error.RelativePath,
        error.NameTooLong,
        => return err,
        else => null,
    };
    if (first) |connection| {
        if (config.fresh) {
            var running = connection;
            running.deinit(connector.process.io);
            std.debug.print("telar: a runtime is already running; stop it first (telar server stop) or drop --fresh\n", .{});
            return error.RuntimeAlreadyRunning;
        }

        return connector.finishHandshake(connection);
    }

    try connector.prepareServerDirectory();
    try connector.startRuntime(config);
    for (0..source_namespace.runtime_start_attempts) |_| {
        if (frontend.transport.local.connect(connector.process.io, connector.endpoint.path())) |connection| {
            return connector.finishHandshake(connection);
        } else |_| {
            connector.process.io.sleep(.fromMilliseconds(source_namespace.runtime_start_interval_ms), .awake) catch {};
        }
    }

    return error.RuntimeUnavailable;
}

fn startRuntime(connector: *const RuntimeConnector, config: RuntimeConfigSelection) !void {
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = executable_buffer[0..try std.process.executablePath(connector.process.io, &executable_buffer)];
    var argv: [10][]const u8 = undefined;
    var argc: usize = 0;
    for ([_][]const u8{ executable, "server", "--background", "--socket", connector.endpoint.path() }) |arg| {
        argv[argc] = arg;
        argc += 1;
    }
    if (config.fresh) {
        argv[argc] = "--fresh";
        argc += 1;
    }
    if (config.path) |path| {
        argv[argc] = "--config";
        argv[argc + 1] = std.mem.span(path);
        argc += 2;
    } else if (config.disabled) {
        argv[argc] = "--no-config";
        argc += 1;
    }
    if (config.profile) |profile| {
        argv[argc] = "--profile";
        argv[argc + 1] = std.mem.span(profile);
        argc += 2;
    }

    var launcher = try std.process.spawn(connector.process.io, .{
        .argv = argv[0..argc],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const result = try launcher.wait(connector.process.io);
    switch (result) {
        .exited => |status| if (status != 0) {
            return error.RuntimeStartFailed;
        },
        else => return error.RuntimeStartFailed,
    }
}

fn finishHandshake(connector: *const RuntimeConnector, connection: core.transport.SocketChannel) !core.transport.SocketChannel {
    var result = connection;
    errdefer result.deinit(connector.process.io);

    const response = try frontend.transport.handshake.perform(connector.process.io, &result);
    switch (response) {
        .accepted => return result,
        .rejected => |rejected| {
            std.debug.print("telar protocol mismatch: runtime expects schema {s}\n", .{&rejected.expected_schema});
            return error.IncompatibleSchema;
        },
    }
}
