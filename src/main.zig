const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");

const Io = std.Io;
const File = Io.File;
const pty = backend.pty;

const version = "0.0.0";
const runtime_start_attempts = 200;
const runtime_start_interval_ms = 10;

// Library warnings cannot be written over a live frame. A later runtime can
// route them to its log; the bootstrap keeps stderr out of the drawing path.
pub const std_options: std.Options = .{ .log_level = .err };

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

const RunOptions = struct {
    command: pty.Command,
    theme: frontend.theme.Theme = frontend.theme.default_theme,
    sidebar_rendering: frontend.kitty.SidebarRendering = .automatic,
};

const Cli = union(enum) {
    help,
    version,
    server: ServerOptions,
    history: HistoryOptions,
    run: RunOptions,

    fn parse(args: []const [*:0]const u8) !Cli {
        if (args.len == 0) return error.MissingArgvZero;
        if (args.len == 1) return .{ .run = .{ .command = try defaultShell() } };

        const first = std.mem.span(args[1]);
        if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h"))
            return .help;
        if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V"))
            return .version;
        if (std.mem.eql(u8, first, "server"))
            return .{ .server = try ServerOptions.parse(args[2..]) };
        if (std.mem.eql(u8, first, "history"))
            return .{ .history = try HistoryOptions.parse(args[2..]) };

        var options: RunOptions = .{ .command = undefined };
        var theme_set = false;
        var sidebar_renderer_set = false;
        var delimiter_seen = false;
        var command_start: usize = 1;
        while (command_start < args.len) {
            const arg = std.mem.span(args[command_start]);
            if (std.mem.eql(u8, arg, "--")) {
                delimiter_seen = true;
                command_start += 1;
                break;
            }
            if (std.mem.eql(u8, arg, "--theme")) {
                if (theme_set) return error.DuplicateThemeOption;
                if (command_start + 1 >= args.len) return error.MissingThemeName;
                options.theme = frontend.theme.fromName(std.mem.span(args[command_start + 1])) orelse
                    return error.UnknownTheme;
                theme_set = true;
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--theme=")) {
                if (theme_set) return error.DuplicateThemeOption;
                options.theme = frontend.theme.fromName(arg["--theme=".len..]) orelse
                    return error.UnknownTheme;
                theme_set = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--sidebar-renderer")) {
                if (sidebar_renderer_set) return error.DuplicateSidebarRendererOption;
                if (command_start + 1 >= args.len) return error.MissingSidebarRenderer;
                options.sidebar_rendering = try frontend.kitty.SidebarRendering.parse(
                    std.mem.span(args[command_start + 1]),
                );
                sidebar_renderer_set = true;
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--sidebar-renderer=")) {
                if (sidebar_renderer_set) return error.DuplicateSidebarRendererOption;
                options.sidebar_rendering = try frontend.kitty.SidebarRendering.parse(
                    arg["--sidebar-renderer=".len..],
                );
                sidebar_renderer_set = true;
                command_start += 1;
                continue;
            }
            break;
        }
        options.command = if (command_start == args.len)
            if (delimiter_seen) return error.MissingCommand else try defaultShell()
        else
            try pty.Command.fromArgv(args[command_start..]);
        return .{ .run = options };
    }
};

const HistoryAction = enum {
    list,
    search,
};

const HistoryOptions = struct {
    action: HistoryAction,
    query: ?[*:0]const u8 = null,
    scope: core.schema.HistoryScope = .global,
    scope_value: ?[*:0]const u8 = null,
    pane_id: core.schema.PaneId = .invalid,
    failed_only: bool = false,
    limit: u16 = 20,
    socket: ?[*:0]const u8 = null,

    fn parse(args: []const [*:0]const u8) !HistoryOptions {
        if (args.len == 0) return error.MissingHistoryAction;
        const action_text = std.mem.span(args[0]);
        var options: HistoryOptions = if (std.mem.eql(u8, action_text, "list"))
            .{ .action = .list }
        else if (std.mem.eql(u8, action_text, "search")) search: {
            if (args.len < 2) return error.MissingHistoryQuery;
            break :search .{ .action = .search, .query = args[1] };
        } else return error.UnknownHistoryAction;

        var index: usize = if (options.action == .search) 2 else 1;
        while (index < args.len) {
            const arg = std.mem.span(args[index]);
            if (std.mem.eql(u8, arg, "--cwd")) {
                try options.setScope(.cwd, null);
                index += 1;
            } else if (std.mem.eql(u8, arg, "--workspace")) {
                if (index + 1 >= args.len) return error.MissingWorkspacePath;
                try options.setScope(.workspace, args[index + 1]);
                index += 2;
            } else if (std.mem.eql(u8, arg, "--pane")) {
                if (index + 1 >= args.len) return error.MissingPaneId;
                const raw = try std.fmt.parseInt(u64, std.mem.span(args[index + 1]), 10);
                options.pane_id = try core.schema.id.pane(raw);
                try options.setScope(.pane, null);
                index += 2;
            } else if (std.mem.eql(u8, arg, "--failed")) {
                options.failed_only = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--limit")) {
                if (index + 1 >= args.len) return error.MissingHistoryLimit;
                options.limit = try std.fmt.parseInt(u16, std.mem.span(args[index + 1]), 10);
                if (options.limit == 0 or options.limit > core.schema.max_history_results)
                    return error.InvalidHistoryLimit;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                if (index + 1 >= args.len) return error.MissingSocketPath;
                if (options.socket != null) return error.DuplicateSocketOption;
                options.socket = args[index + 1];
                index += 2;
            } else {
                return error.UnknownHistoryOption;
            }
        }
        return options;
    }

    fn setScope(
        options: *HistoryOptions,
        scope: core.schema.HistoryScope,
        value: ?[*:0]const u8,
    ) !void {
        if (options.scope != .global) return error.ConflictingHistoryScopes;
        options.scope = scope;
        options.scope_value = value;
    }
};

const ServerMode = enum {
    foreground,
    background_launcher,
    daemonized,
};

const ServerAction = enum {
    run,
    stop,
};

const ServerOptions = struct {
    action: ServerAction = .run,
    mode: ServerMode = .foreground,
    socket: ?[*:0]const u8 = null,
    graphics: backend.runtime.GraphicsLimits = .{},

    fn parse(args: []const [*:0]const u8) !ServerOptions {
        var options: ServerOptions = .{};
        var action_explicit = false;
        var index: usize = 0;
        while (index < args.len) {
            const arg = std.mem.span(args[index]);
            if (std.mem.eql(u8, arg, "stop")) {
                if (action_explicit) return error.DuplicateServerAction;
                options.action = .stop;
                action_explicit = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--background")) {
                if (options.mode != .foreground) return error.ConflictingServerModes;
                options.mode = .background_launcher;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--daemonized")) {
                if (options.mode != .foreground) return error.ConflictingServerModes;
                options.mode = .daemonized;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                if (options.socket != null) return error.DuplicateSocketOption;
                if (index + 1 >= args.len) return error.MissingSocketPath;
                options.socket = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--graphics-pane-mib")) {
                if (index + 1 >= args.len) return error.MissingGraphicsPaneLimit;
                options.graphics.pane_bytes = try parseMebibytes(args[index + 1]);
                index += 2;
            } else if (std.mem.eql(u8, arg, "--graphics-global-mib")) {
                if (index + 1 >= args.len) return error.MissingGraphicsGlobalLimit;
                options.graphics.global_bytes = try parseMebibytes(args[index + 1]);
                index += 2;
            } else {
                return error.UnknownServerOption;
            }
        }
        if (options.action == .stop and options.mode != .foreground)
            return error.ConflictingServerAction;
        try options.graphics.validate();
        return options;
    }
};

fn parseMebibytes(value: [*:0]const u8) !usize {
    const mib = try std.fmt.parseUnsigned(usize, std.mem.span(value), 10);
    return std.math.mul(usize, mib, 1024 * 1024) catch error.InvalidGraphicsLimit;
}

fn resolveEndpoint(
    init: std.process.Init,
    override: ?[*:0]const u8,
) !core.endpoint.Local {
    if (override) |path| return core.endpoint.Local.explicit(std.mem.span(path));

    if (std.process.Environ.getPosix(init.minimal.environ, "TELAR_SOCKET")) |path| {
        if (path.len != 0) return core.endpoint.Local.explicit(path);
    }

    if (std.process.Environ.getPosix(init.minimal.environ, "XDG_RUNTIME_DIR")) |base| {
        if (base.len != 0) return core.endpoint.Local.managed(base, "telar");
    }

    var directory_name_buffer: [32]u8 = undefined;
    const directory_name = try std.fmt.bufPrint(
        &directory_name_buffer,
        "telar-{d}",
        .{std.c.getuid()},
    );
    if (std.process.Environ.getPosix(init.minimal.environ, "TMPDIR")) |base| {
        if (base.len != 0) return core.endpoint.Local.managed(base, directory_name);
    }
    return core.endpoint.Local.managed("/tmp", directory_name);
}

fn prepareManagedDirectory(io: Io, endpoint: *const core.endpoint.Local) !void {
    const directory = endpoint.managedDirectory() orelse return;
    const permissions = File.Permissions.fromMode(0o700);
    Io.Dir.createDirAbsolute(io, directory, permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |other| return other,
    };

    const stat = try Io.Dir.cwd().statFile(io, directory, .{ .follow_symlinks = false });
    if (stat.kind != .directory) return error.InvalidRuntimeDirectory;
    try Io.Dir.cwd().setFilePermissions(
        io,
        directory,
        permissions,
        .{ .follow_symlinks = false },
    );
}

fn executablePath(io: Io, buffer: []u8) ![]const u8 {
    return buffer[0..try std.process.executablePath(io, buffer)];
}

fn launchDaemon(
    init: std.process.Init,
    endpoint: *const core.endpoint.Local,
    graphics: backend.runtime.GraphicsLimits,
) !void {
    if (std.c.setsid() < 0) return error.DetachFailed;

    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = try executablePath(init.io, &executable_buffer);
    var pane_mib_buffer: [32]u8 = undefined;
    const pane_mib = try std.fmt.bufPrint(
        &pane_mib_buffer,
        "{d}",
        .{graphics.pane_bytes / (1024 * 1024)},
    );
    var global_mib_buffer: [32]u8 = undefined;
    const global_mib = try std.fmt.bufPrint(
        &global_mib_buffer,
        "{d}",
        .{graphics.global_bytes / (1024 * 1024)},
    );
    const argv = [_][]const u8{
        executable,
        "server",
        "--daemonized",
        "--socket",
        endpoint.path(),
        "--graphics-pane-mib",
        pane_mib,
        "--graphics-global-mib",
        global_mib,
    };
    const daemon = try std.process.spawn(init.io, .{
        .argv = &argv,
        .cwd = .{ .path = "/" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = daemon;
}

fn startRuntime(init: std.process.Init, endpoint: *const core.endpoint.Local) !void {
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = try executablePath(init.io, &executable_buffer);
    const argv = [_][]const u8{
        executable,
        "server",
        "--background",
        "--socket",
        endpoint.path(),
    };
    var launcher = try std.process.spawn(init.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const result = try launcher.wait(init.io);
    switch (result) {
        .exited => |status| if (status != 0) return error.RuntimeStartFailed,
        else => return error.RuntimeStartFailed,
    }
}

fn finishHandshake(io: Io, connection: core.transport.SocketChannel) !core.transport.SocketChannel {
    var result = connection;
    errdefer result.deinit(io);

    const response = try frontend.transport.handshake.perform(io, &result);
    switch (response) {
        .accepted => return result,
        .rejected => |rejected| {
            std.debug.print(
                "telar protocol mismatch: runtime expects schema {s}\n",
                .{&rejected.expected_schema},
            );
            return error.IncompatibleSchema;
        },
    }
}

fn connectRuntime(
    init: std.process.Init,
    endpoint: *const core.endpoint.Local,
) !core.transport.SocketChannel {
    const first = frontend.transport.local.connect(init.io, endpoint.path()) catch |err| switch (err) {
        error.PermissionDenied,
        error.NotDir,
        error.SymLinkLoop,
        error.RelativePath,
        error.NameTooLong,
        => return err,
        else => null,
    };
    if (first) |connection| return finishHandshake(init.io, connection);

    try prepareManagedDirectory(init.io, endpoint);
    try startRuntime(init, endpoint);
    for (0..runtime_start_attempts) |_| {
        if (frontend.transport.local.connect(init.io, endpoint.path())) |connection| {
            return finishHandshake(init.io, connection);
        } else |_| {
            init.io.sleep(.fromMilliseconds(runtime_start_interval_ms), .awake) catch {};
        }
    }
    return error.RuntimeUnavailable;
}

const HistoryPath = struct {
    path: [:0]const u8,
    managed_directory: ?[]const u8,
};

fn resolveHistoryPath(
    init: std.process.Init,
    buffer: []u8,
) !HistoryPath {
    if (std.process.Environ.getPosix(init.minimal.environ, "TELAR_HISTORY")) |path| {
        if (path.len != 0) return .{
            .path = try std.fmt.bufPrintZ(buffer, "{s}", .{path}),
            .managed_directory = null,
        };
    }

    const base = if (std.process.Environ.getPosix(init.minimal.environ, "XDG_DATA_HOME")) |path|
        if (path.len != 0) path else null
    else
        null;
    if (base) |data_home| {
        const directory = try std.fmt.bufPrint(buffer, "{s}/telar", .{data_home});
        const path = try std.fmt.bufPrintZ(buffer[directory.len..], "/history.db", .{});
        return .{
            .path = buffer[0 .. directory.len + path.len :0],
            .managed_directory = directory,
        };
    }

    const home = std.process.Environ.getPosix(init.minimal.environ, "HOME") orelse
        return error.HomeDirectoryUnavailable;
    if (home.len == 0) return error.HomeDirectoryUnavailable;
    const directory = try std.fmt.bufPrint(buffer, "{s}/.local/share/telar", .{home});
    const path = try std.fmt.bufPrintZ(buffer[directory.len..], "/history.db", .{});
    return .{
        .path = buffer[0 .. directory.len + path.len :0],
        .managed_directory = directory,
    };
}

fn prepareHistoryDatabase(io: Io, history_path: HistoryPath) !void {
    if (history_path.managed_directory) |directory| {
        const permissions = File.Permissions.fromMode(0o700);
        _ = try Io.Dir.cwd().createDirPathStatus(io, directory, permissions);
        try Io.Dir.cwd().setFilePermissions(
            io,
            directory,
            permissions,
            .{ .follow_symlinks = false },
        );
    }
    const file = try Io.Dir.createFileAbsolute(io, history_path.path, .{
        .read = true,
        .truncate = false,
        .permissions = File.Permissions.fromMode(0o600),
    });
    file.close(io);
    try Io.Dir.cwd().setFilePermissions(
        io,
        history_path.path,
        File.Permissions.fromMode(0o600),
        .{ .follow_symlinks = false },
    );
}

fn runServer(init: std.process.Init, options: ServerOptions) !void {
    const endpoint = try resolveEndpoint(init, options.socket);
    if (options.action == .stop) return stopRuntime(init, &endpoint);

    switch (options.mode) {
        .background_launcher => return launchDaemon(init, &endpoint, options.graphics),
        .foreground, .daemonized => {},
    }

    try prepareManagedDirectory(init.io, &endpoint);
    var history_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const history_path = try resolveHistoryPath(init, &history_buffer);
    try prepareHistoryDatabase(init.io, history_path);
    try backend.runtime.serveWithHistoryOptions(
        init.io,
        init.gpa,
        endpoint.path(),
        history_path.path,
        .{ .graphics = options.graphics },
    );
}

fn stopRuntime(init: std.process.Init, endpoint: *const core.endpoint.Local) !void {
    const raw_connection = frontend.transport.local.connect(init.io, endpoint.path()) catch |err| switch (err) {
        error.FileNotFound, error.ConnectionRefused => {
            try File.stdout().writeStreamingAll(init.io, "telar runtime is not running\n");
            return;
        },
        else => |other| return other,
    };
    var connection = try finishHandshake(init.io, raw_connection);
    defer connection.deinit(init.io);

    var send_buffer: [1]u8 = undefined;
    try connection.send(init.io, try core.schema.encodeRuntimeStop(&send_buffer));

    var receive_buffer: [2048]u8 = undefined;
    switch (try core.schema.decodeServer(try connection.receive(init.io, &receive_buffer))) {
        .runtime_stopping => try File.stdout().writeStreamingAll(init.io, "telar runtime stopped\n"),
        .request_failed => |failure| {
            std.debug.print("telar runtime: {s}\n", .{failure.message});
            return error.RuntimeRequestFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

fn defaultShell() !pty.Command {
    const fallback: [*:0]const u8 = "/bin/sh";
    const configured = getenv("SHELL") orelse return pty.Command.fromArgv(&.{fallback});
    const shell: [*:0]const u8 = configured;
    if (shell[0] == 0) return pty.Command.fromArgv(&.{fallback});
    return pty.Command.fromArgv(&.{shell});
}

fn collectArgs(init: std.process.Init, storage: *[pty.max_args][*:0]const u8) ![]const [*:0]const u8 {
    var iterator = init.minimal.args.iterate();
    var len: usize = 0;
    while (iterator.next()) |arg| {
        if (len == storage.len) return error.TooManyArguments;
        storage[len] = arg.ptr;
        len += 1;
    }
    return storage[0..len];
}

fn runClient(
    init: std.process.Init,
    connection: *core.transport.SocketChannel,
    options: *const RunOptions,
    endpoint: []const u8,
) !u8 {
    var argument_storage: [pty.max_args][]const u8 = undefined;
    var argument_count: usize = 0;
    while (options.command.argv[argument_count]) |argument| : (argument_count += 1) {
        argument_storage[argument_count] = std.mem.span(argument);
    }

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
    return frontend.client.run(init, connection, .{
        .arguments = argument_storage[0..argument_count],
        .cwd = cwd_buffer[0..cwd_len],
        .endpoint = endpoint,
        .theme = options.theme,
        .sidebar_rendering = options.sidebar_rendering,
    });
}

fn runHistory(init: std.process.Init, options: HistoryOptions) !void {
    const endpoint = try resolveEndpoint(init, options.socket);
    var connection = try connectRuntime(init, &endpoint);
    defer connection.deinit(init.io);

    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scope_value: []const u8 = switch (options.scope) {
        .cwd => cwd: {
            const len = try Io.Dir.cwd().realPathFile(init.io, ".", &cwd_buffer);
            break :cwd cwd_buffer[0..len];
        },
        .workspace => std.mem.span(options.scope_value.?),
        .global, .pane => "",
    };
    const query = if (options.query) |value| std.mem.span(value) else "";

    var send_buffer: [schema_history_request_size]u8 = undefined;
    try connection.send(init.io, try core.schema.encodeQueryHistory(&send_buffer, .{
        .request_id = @enumFromInt(1),
        .query = query,
        .scope = options.scope,
        .scope_value = scope_value,
        .pane_id = options.pane_id,
        .failed_only = options.failed_only,
        .limit = options.limit,
    }));

    const receive_buffer = try init.gpa.alloc(u8, core.transport.max_frame_size);
    defer init.gpa.free(receive_buffer);
    const response = try core.schema.decodeServer(
        try connection.receive(init.io, receive_buffer),
    );
    switch (response) {
        .history_results => |results| try printHistory(init.io, results),
        .request_failed => |failure| {
            std.debug.print("telar history: {s}\n", .{failure.message});
            return error.HistoryQueryFailed;
        },
        else => return error.UnexpectedRuntimeResponse,
    }
}

const schema_history_request_size = core.schema.max_history_query_bytes +
    core.schema.max_cwd_bytes + 64;

fn printHistory(io: Io, results: core.schema.HistoryResultsView) !void {
    var output_buffer: [16 * 1024]u8 = undefined;
    var output = File.stdout().writerStreaming(io, &output_buffer);
    const writer = &output.interface;
    var entries = results.entries();
    while (entries.next()) |entry| {
        const timestamp = utcTimestamp(entry.started_at_ms);
        try writer.print(
            "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z  ",
            .{
                timestamp.year,
                timestamp.month,
                timestamp.day,
                timestamp.hour,
                timestamp.minute,
                timestamp.second,
            },
        );
        switch (entry.status) {
            .interrupted => try writer.writeAll("INT  "),
            .completed => if (entry.exit_code) |exit_code| {
                if (exit_code < 0)
                    try writer.print("-{d}  ", .{@as(u64, @intCast(-@as(i64, exit_code)))})
                else
                    try writer.print("{d}  ", .{@as(u32, @intCast(exit_code))});
            } else {
                try writer.writeAll("?  ");
            },
        }
        const duration_ms: u64 = @intCast(@max(
            @as(i64, 0),
            @divTrunc(entry.duration_ns, std.time.ns_per_ms),
        ));
        try writer.print("{d}ms  ", .{duration_ms});
        try writeHistoryField(writer, entry.cwd);
        try writer.writeAll("  ");
        try writeHistoryField(writer, entry.command);
        try writer.writeByte('\n');
    }
    try writer.flush();
}

const UtcTimestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn utcTimestamp(milliseconds: i64) UtcTimestamp {
    const seconds: u64 = @intCast(@max(@as(i64, 0), @divFloor(milliseconds, 1000)));
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = @intFromEnum(month_day.month),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
    };
}

fn writeHistoryField(writer: *Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (byte < 0x20 or byte == 0x7f)
            try writer.print("\\x{x:0>2}", .{byte})
        else
            try writer.writeByte(byte),
    };
}

const usage =
    \\Usage: telar [--theme NAME] [--sidebar-renderer MODE] [command [args...]]
    \\       telar server
    \\       telar server stop
    \\       telar history list [options]
    \\       telar history search <query> [options]
    \\
    \\Run an interactive shell inside telar's multiplexer UI.
    \\With a command, run that command instead of $SHELL.
    \\The local runtime starts automatically when needed.
    \\
    \\Commands:
    \\  server           Run the local runtime in the foreground
    \\  server stop      Stop the local runtime
    \\  history list     Show recent command history
    \\  history search   Search command history
    \\
    \\History options:
    \\  --cwd            Restrict results to the current directory
    \\  --workspace PATH Restrict results to a workspace path
    \\  --pane ID        Restrict results to a pane
    \\  --failed         Only show commands with a non-zero exit status
    \\  --limit N        Return at most N results (default 20, maximum 100)
    \\  --socket PATH    Query a specific local runtime
    \\
    \\Options:
    \\  --theme NAME      UI theme: vesper, catppuccin, tokyo-night, terminal
    \\  --sidebar-renderer MODE  automatic, cells, kitty-hybrid, kitty-full
    \\Server options:
    \\  --graphics-pane-mib N    Decoded KGP memory per pane (default 64)
    \\  --graphics-global-mib N  Decoded KGP memory for the runtime (default 256)
    \\  -h, --help       Show this help
    \\  -V, --version    Show the version
    \\  --               Stop parsing telar options
    \\
    \\Default keybindings (prefix Ctrl-b):
    \\  % / "             Split left/right or top/bottom
    \\  Arrow keys       Focus a pane by direction
    \\  s                Toggle the sidebar
    \\  x                Close the focused pane
    \\  c                Create and select a tab
    \\  n / p            Select the next or previous tab
    \\  1..9             Select a tab by position
    \\  T                Rename the active tab
    \\  X                Close the active tab
    \\  , / .            Move the active tab left or right
    \\  d                Detach the client
    \\
;

pub fn main(init: std.process.Init) !void {
    var arg_storage: [pty.max_args][*:0]const u8 = undefined;
    const args = try collectArgs(init, &arg_storage);

    switch (try Cli.parse(args)) {
        .help => try File.stdout().writeStreamingAll(init.io, usage),
        .version => try File.stdout().writeStreamingAll(init.io, "telar " ++ version ++ "\n"),
        .server => |options| try runServer(init, options),
        .history => |options| try runHistory(init, options),
        .run => |options| {
            const endpoint = try resolveEndpoint(init, null);
            var connection = try connectRuntime(init, &endpoint);
            defer connection.deinit(init.io);

            const code = try runClient(init, &connection, &options, endpoint.path());
            std.process.exit(code);
        },
    }
}

test "CLI defaults to the configured shell" {
    const args = [_][*:0]const u8{"telar"};
    const cli = try Cli.parse(&args);
    try std.testing.expect(cli == .run);
    try std.testing.expect(cli.run.command.argv[0] != null);
    try std.testing.expectEqual(frontend.theme.Builtin.vesper, cli.run.theme.base);
}

test "CLI forwards a command without a shell" {
    const args = [_][*:0]const u8{ "telar", "/bin/sh", "-c", "exit 9" };
    const cli = try Cli.parse(&args);

    try std.testing.expect(cli == .run);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(cli.run.command.file));
    try std.testing.expectEqualStrings("exit 9", std.mem.span(cli.run.command.argv[2].?));
}

test "CLI delimiter permits option-shaped commands" {
    const args = [_][*:0]const u8{ "telar", "--", "-command" };
    const cli = try Cli.parse(&args);
    try std.testing.expectEqualStrings("-command", std.mem.span(cli.run.command.file));
}

test "CLI selects a built-in theme before the command" {
    const args = [_][*:0]const u8{ "telar", "--theme=catppuccin", "/bin/sh" };
    const cli = try Cli.parse(&args);
    try std.testing.expectEqual(frontend.theme.Builtin.catppuccin, cli.run.theme.base);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(cli.run.command.file));
}

test "CLI runs the default shell when only a theme is provided" {
    const args = [_][*:0]const u8{ "telar", "--theme", "tokyonight" };
    const cli = try Cli.parse(&args);
    try std.testing.expectEqual(frontend.theme.Builtin.tokyo_night, cli.run.theme.base);
    try std.testing.expect(cli.run.command.argv[0] != null);
}

test "CLI rejects unknown and duplicate themes" {
    const unknown = [_][*:0]const u8{ "telar", "--theme", "neon" };
    try std.testing.expectError(error.UnknownTheme, Cli.parse(&unknown));

    const duplicate = [_][*:0]const u8{
        "telar",
        "--theme",
        "vesper",
        "--theme=catppuccin",
    };
    try std.testing.expectError(error.DuplicateThemeOption, Cli.parse(&duplicate));
}

test "CLI selects and validates the sidebar renderer" {
    const args = [_][*:0]const u8{ "telar", "--sidebar-renderer=kitty-hybrid", "/bin/sh" };
    const cli = try Cli.parse(&args);
    try std.testing.expectEqual(frontend.kitty.SidebarRendering.kitty_hybrid, cli.run.sidebar_rendering);

    const invalid = [_][*:0]const u8{ "telar", "--sidebar-renderer", "sixel" };
    try std.testing.expectError(error.UnknownSidebarRenderer, Cli.parse(&invalid));
}

test "CLI rejects an empty command after the delimiter" {
    const args = [_][*:0]const u8{ "telar", "--" };
    try std.testing.expectError(error.MissingCommand, Cli.parse(&args));
}

test "CLI recognizes the runtime server" {
    const args = [_][*:0]const u8{ "telar", "server" };
    const cli = try Cli.parse(&args);
    try std.testing.expect(cli == .server);
    try std.testing.expectEqual(ServerAction.run, cli.server.action);
    try std.testing.expectEqual(ServerMode.foreground, cli.server.mode);
}

test "CLI recognizes runtime stop" {
    const args = [_][*:0]const u8{ "telar", "server", "stop" };
    const cli = try Cli.parse(&args);
    try std.testing.expect(cli == .server);
    try std.testing.expectEqual(ServerAction.stop, cli.server.action);
    try std.testing.expectEqual(ServerMode.foreground, cli.server.mode);
}

test "runtime stop cannot use an internal launcher mode" {
    const args = [_][*:0]const u8{ "telar", "server", "stop", "--background" };
    try std.testing.expectError(error.ConflictingServerAction, Cli.parse(&args));
}

test "server socket and launcher mode are explicit" {
    const args = [_][*:0]const u8{
        "telar",
        "server",
        "--background",
        "--socket",
        "/tmp/telar-test.sock",
    };
    const cli = try Cli.parse(&args);
    try std.testing.expectEqual(ServerMode.background_launcher, cli.server.mode);
    try std.testing.expectEqualStrings(
        "/tmp/telar-test.sock",
        std.mem.span(cli.server.socket.?),
    );
}

test "server graphics memory quotas are configurable and bounded" {
    const args = [_][*:0]const u8{
        "telar",
        "server",
        "--graphics-pane-mib",
        "32",
        "--graphics-global-mib",
        "128",
    };
    const cli = try Cli.parse(&args);
    try std.testing.expectEqual(@as(usize, 32 * 1024 * 1024), cli.server.graphics.pane_bytes);
    try std.testing.expectEqual(@as(usize, 128 * 1024 * 1024), cli.server.graphics.global_bytes);

    const invalid = [_][*:0]const u8{
        "telar",
        "server",
        "--graphics-pane-mib",
        "65",
    };
    try std.testing.expectError(error.InvalidGraphicsLimits, Cli.parse(&invalid));
}

test "CLI parses history search filters" {
    const args = [_][*:0]const u8{
        "telar",
        "history",
        "search",
        "git commit",
        "--workspace",
        "/work/telar",
        "--failed",
        "--limit",
        "40",
    };
    const cli = try Cli.parse(&args);
    try std.testing.expect(cli == .history);
    try std.testing.expectEqual(HistoryAction.search, cli.history.action);
    try std.testing.expectEqualStrings("git commit", std.mem.span(cli.history.query.?));
    try std.testing.expectEqual(core.schema.HistoryScope.workspace, cli.history.scope);
    try std.testing.expectEqualStrings("/work/telar", std.mem.span(cli.history.scope_value.?));
    try std.testing.expect(cli.history.failed_only);
    try std.testing.expectEqual(@as(u16, 40), cli.history.limit);
}

test "CLI rejects conflicting history scopes" {
    const args = [_][*:0]const u8{
        "telar",
        "history",
        "list",
        "--cwd",
        "--pane",
        "1",
    };
    try std.testing.expectError(error.ConflictingHistoryScopes, Cli.parse(&args));
}

test "history fields escape terminal control bytes" {
    var storage: [128]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    try writeHistoryField(&writer, "echo\n\x1b[31m");
    try std.testing.expectEqualStrings("echo\\n\\x1b[31m", writer.buffered());
}
