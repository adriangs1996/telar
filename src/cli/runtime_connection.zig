//! Discovery and authenticated connection to the local Telar runtime.

const std = @import("std");
const core = @import("telar-core");
const frontend = @import("telar-frontend");

const Io = std.Io;
const File = Io.File;
const runtime_start_attempts = 200;
const runtime_start_interval_ms = 10;

pub const RuntimeConfigSelection = struct {
    path: ?[*:0]const u8 = null,
    disabled: bool = false,
    profile: ?[*:0]const u8 = null,
};

pub const RuntimeConnector = struct {
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
            .endpoint = try resolveEndpoint(process.minimal.environ, override),
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
        const permissions = File.Permissions.fromMode(0o700);
        Io.Dir.createDirAbsolute(connector.process.io, directory, permissions) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |other| return other,
        };

        const stat = try Io.Dir.cwd().statFile(connector.process.io, directory, .{ .follow_symlinks = false });
        if (stat.kind != .directory) {
            return error.InvalidRuntimeDirectory;
        }

        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory_z = std.fmt.bufPrintZ(&path_buffer, "{s}", .{directory}) catch
            return error.NameTooLong;
        var native_stat: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, directory_z, &native_stat, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
            return error.InvalidRuntimeDirectory;
        }
        try checkRuntimeDirectoryOwner(native_stat.uid, std.c.getuid());

        try Io.Dir.cwd().setFilePermissions(connector.process.io, directory, permissions, .{ .follow_symlinks = false });
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
            return connector.finishHandshake(connection);
        }

        try connector.prepareServerDirectory();
        try connector.startRuntime(config);
        for (0..runtime_start_attempts) |_| {
            if (frontend.transport.local.connect(connector.process.io, connector.endpoint.path())) |connection| {
                return connector.finishHandshake(connection);
            } else |_| {
                connector.process.io.sleep(.fromMilliseconds(runtime_start_interval_ms), .awake) catch {};
            }
        }

        return error.RuntimeUnavailable;
    }

    fn startRuntime(connector: *const RuntimeConnector, config: RuntimeConfigSelection) !void {
        var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const executable = executable_buffer[0..try std.process.executablePath(connector.process.io, &executable_buffer)];
        var argv: [9][]const u8 = undefined;
        var argc: usize = 0;
        for ([_][]const u8{ executable, "server", "--background", "--socket", connector.endpoint.path() }) |arg| {
            argv[argc] = arg;
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
};

fn resolveEndpoint(environ: std.process.Environ, override: ?[*:0]const u8) !core.endpoint.Local {
    if (override) |path| {
        return core.endpoint.Local.explicit(std.mem.span(path));
    }

    if (std.process.Environ.getPosix(environ, "TELAR_SOCKET")) |path| {
        if (path.len != 0) {
            return core.endpoint.Local.explicit(path);
        }
    }

    // Set by the runtime for every pane child, so agents and scripts running
    // inside Telar address the runtime that owns their pane.
    if (std.process.Environ.getPosix(environ, "TELAR_SOCKET_PATH")) |path| {
        if (path.len != 0) {
            return core.endpoint.Local.explicit(path);
        }
    }

    if (std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR")) |base| {
        if (base.len != 0) {
            return core.endpoint.Local.managed(base, "telar");
        }
    }

    var directory_name_buffer: [32]u8 = undefined;
    const directory_name = try std.fmt.bufPrint(&directory_name_buffer, "telar-{d}", .{std.c.getuid()});
    if (std.process.Environ.getPosix(environ, "TMPDIR")) |base| {
        if (base.len != 0) {
            return core.endpoint.Local.managed(base, directory_name);
        }
    }

    return core.endpoint.Local.managed("/tmp", directory_name);
}

fn checkRuntimeDirectoryOwner(owner: std.c.uid_t, current_user: std.c.uid_t) error{WrongOwner}!void {
    if (owner != current_user) {
        return error.WrongOwner;
    }
}

test "an explicit runtime endpoint overrides the environment" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TELAR_SOCKET", "/environment.sock");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);

    const endpoint = try resolveEndpoint(.{ .block = block }, "/explicit.sock");

    try std.testing.expectEqualStrings("/explicit.sock", endpoint.path());
}

test "runtime endpoint resolution follows environment precedence" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("TELAR_SOCKET", "/telar.sock");
    try environment.put("XDG_RUNTIME_DIR", "/run/user/42");
    try environment.put("TMPDIR", "/private/tmp");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);

    const endpoint = try resolveEndpoint(.{ .block = block }, null);

    try std.testing.expectEqualStrings("/telar.sock", endpoint.path());
}

test "XDG runtime endpoints use Telar's managed directory" {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("XDG_RUNTIME_DIR", "/run/user/42");
    try environment.put("TMPDIR", "/private/tmp");
    const block = try environment.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);

    const endpoint = try resolveEndpoint(.{ .block = block }, null);

    try std.testing.expectEqualStrings("/run/user/42/telar", endpoint.managedDirectory().?);
    try std.testing.expectEqualStrings("/run/user/42/telar/runtime.sock", endpoint.path());
}

test "runtime endpoint falls back to a user-specific temporary directory" {
    const endpoint = try resolveEndpoint(.empty, null);
    var expected_buffer: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "/tmp/telar-{d}/runtime.sock", .{std.c.getuid()});

    try std.testing.expectEqualStrings(expected, endpoint.path());
}

test "the runtime directory must belong to the current user" {
    try checkRuntimeDirectoryOwner(1000, 1000);
    try std.testing.expectError(error.WrongOwner, checkRuntimeDirectoryOwner(0, 1000));
}
