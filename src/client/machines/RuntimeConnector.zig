const localsocket = @import("localsocket");
const core = @import("telar-core");
const privatefile = @import("privatefile");
const handshake = @import("../transport/handshake.zig");
const std = @import("std");
const runtime_connection = @import("runtime_connection.zig");
const RuntimeConfigSelection = @import("RuntimeConfigSelection.zig");
const RuntimeConnector = @This();

io: std.Io,
endpoint: localsocket.Local,
/// Where a refused handshake explains itself; standard error when null.
report: ?*std.Io.Writer = null,

/// Resolves the local runtime endpoint from an explicit socket or the
/// process environment. It does not access the filesystem or connect yet.
///
/// ```zig
/// const connector = try RuntimeConnector.init(io, environ, null);
/// ```
pub fn init(io: std.Io, environ: std.process.Environ, override: ?[*:0]const u8) !RuntimeConnector {
    return .{
        .io = io,
        .endpoint = try runtime_connection.resolveEndpoint(environ, override),
    };
}

/// Returns the resolved Unix socket path borrowed from this connector.
///
/// ```zig
/// const path = connector.endpointPath();
/// ```
pub fn endpointPath(self: *const RuntimeConnector) []const u8 {
    return self.endpoint.path();
}

/// Creates and validates Telar's managed socket directory before a runtime
/// binds its listener. Explicit socket paths require no directory work.
///
/// ```zig
/// try connector.prepareServerDirectory();
/// ```
pub fn prepareServerDirectory(self: *const RuntimeConnector) !void {
    const directory = self.endpoint.managedDirectory() orelse return;
    privatefile.prepareDirectory(self.io, directory) catch |err| switch (err) {
        error.InsecureDirectory => return error.InvalidRuntimeDirectory,
        else => |other| return other,
    };
}

/// Connects to an already running runtime and completes schema negotiation.
/// It never starts a missing runtime.
///
/// ```zig
/// var connection = try connector.connect();
/// defer connection.deinit(io);
/// ```
pub fn connect(self: *const RuntimeConnector) !localsocket.SocketChannel {
    const connection = try localsocket.connect(self.io, self.endpoint.path());
    return self.finishHandshake(connection);
}

/// Connects to the local runtime, starting it with the selected config when
/// no listener is available, then waits for its bounded startup window.
///
/// ```zig
/// var connection = try connector.connectOrStart(.{});
/// defer connection.deinit(io);
/// ```
pub fn connectOrStart(self: *const RuntimeConnector, config: RuntimeConfigSelection) !localsocket.SocketChannel {
    const first = localsocket.connect(self.io, self.endpoint.path()) catch |err| switch (err) {
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
            running.deinit(self.io);
            std.debug.print("telar: a runtime is already running; stop it first (telar server stop) or drop --fresh\n", .{});
            return error.RuntimeAlreadyRunning;
        }

        return self.finishHandshake(connection);
    }

    try self.prepareServerDirectory();
    try self.startRuntime(config);
    for (0..runtime_connection.runtime_start_attempts) |_| {
        if (localsocket.connect(self.io, self.endpoint.path())) |connection| {
            return self.finishHandshake(connection);
        } else |_| {
            self.io.sleep(.fromMilliseconds(runtime_connection.runtime_start_interval_ms), .awake) catch {};
        }
    }

    return error.RuntimeUnavailable;
}

fn startRuntime(self: *const RuntimeConnector, config: RuntimeConfigSelection) !void {
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = config.executable orelse executable_buffer[0..try std.process.executablePath(self.io, &executable_buffer)];
    var argv: [10][]const u8 = undefined;
    var argc: usize = 0;
    for ([_][]const u8{ executable, "server", "--background", "--socket", self.endpoint.path() }) |arg| {
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

    var launcher = try std.process.spawn(self.io, .{
        .argv = argv[0..argc],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const result = try launcher.wait(self.io);
    switch (result) {
        .exited => |status| if (status != 0) {
            return error.RuntimeStartFailed;
        },
        else => return error.RuntimeStartFailed,
    }
}

fn finishHandshake(self: *const RuntimeConnector, connection: localsocket.SocketChannel) !localsocket.SocketChannel {
    return negotiate(self.io, connection, self.report);
}

/// Completes the schema handshake on a connected channel, closing it on
/// failure. A refusal explains itself in `report`, or on standard error
/// when null.
///
/// ```zig
/// const channel = try RuntimeConnector.negotiate(io, connection, &report);
/// ```
pub fn negotiate(io: std.Io, connection: localsocket.SocketChannel, report: ?*std.Io.Writer) !localsocket.SocketChannel {
    var result = connection;
    errdefer result.deinit(io);

    const response = try handshake.perform(io, &result);
    switch (response) {
        .accepted => return result,
        .rejected => |rejected| {
            if (report) |writer| {
                writer.print("the runtime speaks wire schema {s}; this telar speaks {s}. Update telar on one side", .{ &rejected.expected_schema, &core.schema_id }) catch {};
            } else {
                std.debug.print("telar protocol mismatch: runtime expects schema {s}\n", .{&rejected.expected_schema});
            }

            return error.IncompatibleSchema;
        },
    }
}
