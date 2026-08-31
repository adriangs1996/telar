//! Command-line grammar and validated launch options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");

const pty = backend.pty;

pub const RunOptions = struct {
    command: pty.Command,
    theme: frontend.theme.Theme = frontend.theme.default_theme,
    theme_set: bool = false,
    sidebar_rendering: frontend.kitty.SidebarRendering = .automatic,
    sidebar_renderer_set: bool = false,
    config: ?[*:0]const u8 = null,
    no_config: bool = false,
    profile: ?[*:0]const u8 = null,
};

pub const ConfigCheckOptions = struct {
    path: ?[*:0]const u8 = null,
    profile: ?[*:0]const u8 = null,
};

pub const PluginWorkerOptions = struct {
    entry: [*:0]const u8,
    action: [*:0]const u8,
    context: frontend.config.CallbackContext,
};

pub const PluginCommand = enum { inspect, install, trust };

pub const PluginOptions = struct {
    command: PluginCommand,
    path: [*:0]const u8,
    capabilities: [@typeInfo(core.plugin.Capability).@"enum".fields.len]core.plugin.Capability = undefined,
    capability_count: u8 = 0,
};

pub const NotificationOptions = struct {
    title: [*:0]const u8,
    body: ?[*:0]const u8 = null,
    level: core.schema.NotificationLevel = .info,
    duration_ms: u32 = core.schema.default_notification_duration_ms,
    target: core.schema.NotificationTarget = .none,
    socket: ?[*:0]const u8 = null,

    fn parse(args: []const [*:0]const u8) !NotificationOptions {
        if (args.len < 2 or !std.mem.eql(u8, std.mem.span(args[0]), "show"))
            return error.MissingNotificationShow;
        var options: NotificationOptions = .{ .title = args[1] };
        if (std.mem.span(options.title).len == 0) return error.EmptyNotificationTitle;
        var target_set = false;
        var level_set = false;
        var duration_set = false;
        var index: usize = 2;
        while (index < args.len) {
            const arg = std.mem.span(args[index]);
            if (std.mem.eql(u8, arg, "--body")) {
                if (options.body != null) return error.DuplicateNotificationBody;
                if (index + 1 >= args.len) return error.MissingNotificationBody;
                options.body = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--level")) {
                if (level_set) return error.DuplicateNotificationLevel;
                if (index + 1 >= args.len) return error.MissingNotificationLevel;
                const level = std.mem.span(args[index + 1]);
                options.level = if (std.mem.eql(u8, level, "info"))
                    .info
                else if (std.mem.eql(u8, level, "success"))
                    .success
                else if (std.mem.eql(u8, level, "warning"))
                    .warning
                else if (std.mem.eql(u8, level, "failure"))
                    .failure
                else
                    return error.InvalidNotificationLevel;
                level_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--duration")) {
                if (duration_set) return error.DuplicateNotificationDuration;
                if (index + 1 >= args.len) return error.MissingNotificationDuration;
                options.duration_ms = try std.fmt.parseUnsigned(
                    u32,
                    std.mem.span(args[index + 1]),
                    10,
                );
                if (options.duration_ms < core.schema.min_notification_duration_ms or
                    options.duration_ms > core.schema.max_notification_duration_ms)
                    return error.InvalidNotificationDuration;
                duration_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--pane")) {
                if (target_set) return error.ConflictingNotificationTargets;
                if (index + 1 >= args.len) return error.MissingPaneId;
                options.target = .{ .pane = try core.schema.id.pane(try std.fmt.parseUnsigned(
                    u64,
                    std.mem.span(args[index + 1]),
                    10,
                )) };
                target_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--tab")) {
                if (target_set) return error.ConflictingNotificationTargets;
                if (index + 1 >= args.len) return error.MissingTabId;
                options.target = .{ .tab = try core.schema.id.tab(try std.fmt.parseUnsigned(
                    u64,
                    std.mem.span(args[index + 1]),
                    10,
                )) };
                target_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--workspace")) {
                if (target_set) return error.ConflictingNotificationTargets;
                if (index + 1 >= args.len) return error.MissingWorkspaceId;
                options.target = .{ .workspace = try core.schema.id.workspace(try std.fmt.parseUnsigned(
                    u64,
                    std.mem.span(args[index + 1]),
                    10,
                )) };
                target_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                if (options.socket != null) return error.DuplicateSocketOption;
                if (index + 1 >= args.len) return error.MissingSocketPath;
                options.socket = args[index + 1];
                index += 2;
            } else {
                return error.UnknownNotificationOption;
            }
        }
        return options;
    }
};

pub const Cli = union(enum) {
    help,
    version,
    server: ServerOptions,
    history: HistoryOptions,
    notification: NotificationOptions,
    config_check: ConfigCheckOptions,
    plugin_worker: PluginWorkerOptions,
    plugin: PluginOptions,
    run: RunOptions,

    pub fn parse(args: []const [*:0]const u8, environ: std.process.Environ) !Cli {
        if (args.len == 0) return error.MissingArgvZero;
        if (args.len == 1) return .{ .run = .{ .command = try defaultShell(environ) } };

        const first = std.mem.span(args[1]);
        if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h"))
            return .help;
        if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V"))
            return .version;
        if (std.mem.eql(u8, first, "server"))
            return .{ .server = try ServerOptions.parse(args[2..]) };
        if (std.mem.eql(u8, first, "history"))
            return .{ .history = try HistoryOptions.parse(args[2..]) };
        if (std.mem.eql(u8, first, "notification"))
            return .{ .notification = try NotificationOptions.parse(args[2..]) };
        if (std.mem.eql(u8, first, "config")) {
            if (args.len < 3 or !std.mem.eql(u8, std.mem.span(args[2]), "check"))
                return error.UnknownConfigAction;
            var check: ConfigCheckOptions = .{};
            var check_index: usize = 3;
            while (check_index < args.len) {
                if (std.mem.eql(u8, std.mem.span(args[check_index]), "--profile")) {
                    if (check.profile != null) return error.DuplicateProfileOption;
                    if (check_index + 1 >= args.len) return error.MissingProfileName;
                    check.profile = args[check_index + 1];
                    check_index += 2;
                } else {
                    if (check.path != null) return error.TooManyConfigArguments;
                    check.path = args[check_index];
                    check_index += 1;
                }
            }
            return .{ .config_check = check };
        }
        if (std.mem.eql(u8, first, "plugin-worker")) {
            if (args.len != 9) return error.InvalidPluginWorkerArguments;
            return .{ .plugin_worker = .{
                .entry = args[2],
                .action = args[3],
                .context = .{
                    .sidebar_visible = try parseWorkerBool(args[4]),
                    .tab_count = try std.fmt.parseUnsigned(u16, std.mem.span(args[5]), 10),
                    .active_tab_index = try std.fmt.parseUnsigned(u16, std.mem.span(args[6]), 10),
                    .pane_count = try std.fmt.parseUnsigned(u16, std.mem.span(args[7]), 10),
                    .focused_pane_id = try std.fmt.parseUnsigned(u64, std.mem.span(args[8]), 10),
                },
            } };
        }
        if (std.mem.eql(u8, first, "plugin")) {
            if (args.len < 4) return error.MissingPluginArguments;
            var plugin_options: PluginOptions = .{
                .command = if (std.mem.eql(u8, std.mem.span(args[2]), "inspect"))
                    .inspect
                else if (std.mem.eql(u8, std.mem.span(args[2]), "install"))
                    .install
                else if (std.mem.eql(u8, std.mem.span(args[2]), "trust"))
                    .trust
                else
                    return error.UnknownPluginAction,
                .path = args[3],
            };
            var plugin_arg: usize = 4;
            while (plugin_arg < args.len) {
                if (!std.mem.eql(u8, std.mem.span(args[plugin_arg]), "--capability") or
                    plugin_arg + 1 >= args.len) return error.InvalidPluginArguments;
                if (plugin_options.capability_count == plugin_options.capabilities.len)
                    return error.TooManyPluginCapabilities;
                plugin_options.capabilities[plugin_options.capability_count] =
                    try core.plugin.Capability.parse(std.mem.span(args[plugin_arg + 1]));
                plugin_options.capability_count += 1;
                plugin_arg += 2;
            }
            if (plugin_options.command != .trust and plugin_options.capability_count != 0)
                return error.InvalidPluginArguments;
            return .{ .plugin = plugin_options };
        }

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
                options.theme_set = true;
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--theme=")) {
                if (theme_set) return error.DuplicateThemeOption;
                options.theme = frontend.theme.fromName(arg["--theme=".len..]) orelse
                    return error.UnknownTheme;
                theme_set = true;
                options.theme_set = true;
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
                options.sidebar_renderer_set = true;
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--sidebar-renderer=")) {
                if (sidebar_renderer_set) return error.DuplicateSidebarRendererOption;
                options.sidebar_rendering = try frontend.kitty.SidebarRendering.parse(
                    arg["--sidebar-renderer=".len..],
                );
                sidebar_renderer_set = true;
                options.sidebar_renderer_set = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--config")) {
                if (options.config != null or options.no_config) return error.DuplicateConfigOption;
                if (command_start + 1 >= args.len) return error.MissingConfigPath;
                options.config = args[command_start + 1];
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--config=")) {
                if (options.config != null or options.no_config) return error.DuplicateConfigOption;
                if (arg["--config=".len..].len == 0) return error.MissingConfigPath;
                options.config = args[command_start] + "--config=".len;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-config")) {
                if (options.config != null or options.no_config) return error.DuplicateConfigOption;
                options.no_config = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--profile")) {
                if (options.profile != null) return error.DuplicateProfileOption;
                if (command_start + 1 >= args.len) return error.MissingProfileName;
                options.profile = args[command_start + 1];
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--profile=")) {
                if (options.profile != null) return error.DuplicateProfileOption;
                if (arg["--profile=".len..].len == 0) return error.MissingProfileName;
                options.profile = args[command_start] + "--profile=".len;
                command_start += 1;
                continue;
            }
            break;
        }
        options.command = if (command_start == args.len)
            if (delimiter_seen) return error.MissingCommand else try defaultShell(environ)
        else
            try pty.Command.fromArgv(args[command_start..]);
        if (options.no_config and options.profile != null) return error.ProfileWithoutConfig;
        return .{ .run = options };
    }
};

fn parseWorkerBool(value: [*:0]const u8) !bool {
    const text = std.mem.span(value);
    if (std.mem.eql(u8, text, "0")) return false;
    if (std.mem.eql(u8, text, "1")) return true;
    return error.InvalidPluginWorkerArguments;
}

pub const HistoryAction = enum {
    list,
    search,
};

pub const HistoryOptions = struct {
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

pub const ServerMode = enum {
    foreground,
    background_launcher,
    daemonized,
};

pub const ServerAction = enum {
    run,
    stop,
};

pub const ServerOptions = struct {
    action: ServerAction = .run,
    mode: ServerMode = .foreground,
    socket: ?[*:0]const u8 = null,
    graphics: backend.runtime.GraphicsLimits = .{},
    graphics_pane_set: bool = false,
    graphics_global_set: bool = false,
    config: ?[*:0]const u8 = null,
    no_config: bool = false,
    profile: ?[*:0]const u8 = null,

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
                options.graphics_pane_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--graphics-global-mib")) {
                if (index + 1 >= args.len) return error.MissingGraphicsGlobalLimit;
                options.graphics.global_bytes = try parseMebibytes(args[index + 1]);
                options.graphics_global_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--config")) {
                if (options.config != null or options.no_config) return error.DuplicateConfigOption;
                if (index + 1 >= args.len) return error.MissingConfigPath;
                options.config = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--no-config")) {
                if (options.config != null or options.no_config) return error.DuplicateConfigOption;
                options.no_config = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--profile")) {
                if (options.profile != null) return error.DuplicateProfileOption;
                if (index + 1 >= args.len) return error.MissingProfileName;
                options.profile = args[index + 1];
                index += 2;
            } else {
                return error.UnknownServerOption;
            }
        }
        if (options.action == .stop and options.mode != .foreground)
            return error.ConflictingServerAction;
        if (options.no_config and options.profile != null) return error.ProfileWithoutConfig;
        try options.graphics.validate();
        return options;
    }
};

fn parseMebibytes(value: [*:0]const u8) !usize {
    const mib = try std.fmt.parseUnsigned(usize, std.mem.span(value), 10);
    return std.math.mul(usize, mib, 1024 * 1024) catch error.InvalidGraphicsLimit;
}

fn defaultShell(environ: std.process.Environ) !pty.Command {
    const fallback: [*:0]const u8 = "/bin/sh";
    const configured = environ.getPosix("SHELL") orelse
        return pty.Command.fromArgv(&.{fallback});
    if (configured.len == 0) return pty.Command.fromArgv(&.{fallback});
    return pty.Command.fromArgv(&.{configured.ptr});
}

test "CLI defaults to the configured shell" {
    const args = [_][*:0]const u8{"telar"};
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .run);
    try std.testing.expect(cli.run.command.argv[0] != null);
    try std.testing.expectEqual(frontend.theme.Builtin.vesper, cli.run.theme.base);
}

test "CLI forwards a command without a shell" {
    const args = [_][*:0]const u8{ "telar", "/bin/sh", "-c", "exit 9" };
    const cli = try Cli.parse(&args, .empty);

    try std.testing.expect(cli == .run);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(cli.run.command.file));
    try std.testing.expectEqualStrings("exit 9", std.mem.span(cli.run.command.argv[2].?));
}

test "CLI delimiter permits option-shaped commands" {
    const args = [_][*:0]const u8{ "telar", "--", "-command" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqualStrings("-command", std.mem.span(cli.run.command.file));
}

test "CLI selects a built-in theme before the command" {
    const args = [_][*:0]const u8{ "telar", "--theme=catppuccin", "/bin/sh" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(frontend.theme.Builtin.catppuccin, cli.run.theme.base);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(cli.run.command.file));
}

test "CLI runs the default shell when only a theme is provided" {
    const args = [_][*:0]const u8{ "telar", "--theme", "tokyonight" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(frontend.theme.Builtin.tokyo_night, cli.run.theme.base);
    try std.testing.expect(cli.run.command.argv[0] != null);
}

test "CLI rejects unknown and duplicate themes" {
    const unknown = [_][*:0]const u8{ "telar", "--theme", "neon" };
    try std.testing.expectError(error.UnknownTheme, Cli.parse(&unknown, .empty));

    const duplicate = [_][*:0]const u8{
        "telar",
        "--theme",
        "vesper",
        "--theme=catppuccin",
    };
    try std.testing.expectError(error.DuplicateThemeOption, Cli.parse(&duplicate, .empty));
}

test "CLI selects and validates the sidebar renderer" {
    const args = [_][*:0]const u8{ "telar", "--sidebar-renderer=kitty-hybrid", "/bin/sh" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(frontend.kitty.SidebarRendering.kitty_hybrid, cli.run.sidebar_rendering);

    const invalid = [_][*:0]const u8{ "telar", "--sidebar-renderer", "sixel" };
    try std.testing.expectError(error.UnknownSidebarRenderer, Cli.parse(&invalid, .empty));
}

test "CLI rejects an empty command after the delimiter" {
    const args = [_][*:0]const u8{ "telar", "--" };
    try std.testing.expectError(error.MissingCommand, Cli.parse(&args, .empty));
}

test "CLI parses config profiles and rejects profile without config" {
    const args = [_][*:0]const u8{ "telar", "--config", "config.lua", "--profile", "remote" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqualStrings("remote", std.mem.span(cli.run.profile.?));

    const disabled = [_][*:0]const u8{ "telar", "--no-config", "--profile", "remote" };
    try std.testing.expectError(error.ProfileWithoutConfig, Cli.parse(&disabled, .empty));

    const check = [_][*:0]const u8{ "telar", "config", "check", "config.lua", "--profile", "remote" };
    const parsed_check = try Cli.parse(&check, .empty);
    try std.testing.expectEqualStrings("config.lua", std.mem.span(parsed_check.config_check.path.?));
    try std.testing.expectEqualStrings("remote", std.mem.span(parsed_check.config_check.profile.?));
}

test "CLI keeps plugin inspection installation and trust separate" {
    const install = [_][*:0]const u8{ "telar", "plugin", "install", "./plugin" };
    const parsed_install = try Cli.parse(&install, .empty);
    try std.testing.expectEqual(PluginCommand.install, parsed_install.plugin.command);

    const trust = [_][*:0]const u8{
        "telar",
        "plugin",
        "trust",
        "./plugin",
        "--capability",
        "history.read",
    };
    const parsed_trust = try Cli.parse(&trust, .empty);
    try std.testing.expectEqual(PluginCommand.trust, parsed_trust.plugin.command);
    try std.testing.expectEqual(core.plugin.Capability.history_read, parsed_trust.plugin.capabilities[0]);
}

test "CLI recognizes the runtime server" {
    const args = [_][*:0]const u8{ "telar", "server" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .server);
    try std.testing.expectEqual(ServerAction.run, cli.server.action);
    try std.testing.expectEqual(ServerMode.foreground, cli.server.mode);
}

test "CLI recognizes runtime stop" {
    const args = [_][*:0]const u8{ "telar", "server", "stop" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .server);
    try std.testing.expectEqual(ServerAction.stop, cli.server.action);
    try std.testing.expectEqual(ServerMode.foreground, cli.server.mode);
}

test "runtime stop cannot use an internal launcher mode" {
    const args = [_][*:0]const u8{ "telar", "server", "stop", "--background" };
    try std.testing.expectError(error.ConflictingServerAction, Cli.parse(&args, .empty));
}

test "server socket and launcher mode are explicit" {
    const args = [_][*:0]const u8{
        "telar",
        "server",
        "--background",
        "--socket",
        "/tmp/telar-test.sock",
    };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(ServerMode.background_launcher, cli.server.mode);
    try std.testing.expectEqualStrings("/tmp/telar-test.sock", std.mem.span(cli.server.socket.?));
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
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(@as(usize, 32 * 1024 * 1024), cli.server.graphics.pane_bytes);
    try std.testing.expectEqual(@as(usize, 128 * 1024 * 1024), cli.server.graphics.global_bytes);

    const invalid = [_][*:0]const u8{
        "telar",
        "server",
        "--graphics-pane-mib",
        "257",
    };
    try std.testing.expectError(error.InvalidGraphicsLimits, Cli.parse(&invalid, .empty));
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
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .history);
    try std.testing.expectEqual(HistoryAction.search, cli.history.action);
    try std.testing.expectEqualStrings("git commit", std.mem.span(cli.history.query.?));
    try std.testing.expectEqual(core.schema.HistoryScope.workspace, cli.history.scope);
    try std.testing.expectEqualStrings("/work/telar", std.mem.span(cli.history.scope_value.?));
    try std.testing.expect(cli.history.failed_only);
    try std.testing.expectEqual(@as(u16, 40), cli.history.limit);
}

test "CLI parses clickable notification commands" {
    const args = [_][*:0]const u8{
        "telar",
        "notification",
        "show",
        "Build complete",
        "--body",
        "Open the pane",
        "--level",
        "success",
        "--duration",
        "2500",
        "--pane",
        "42",
        "--socket",
        "/tmp/telar.sock",
    };
    const parsed = try Cli.parse(&args, .empty);
    try std.testing.expect(parsed == .notification);
    try std.testing.expectEqualStrings("Build complete", std.mem.span(parsed.notification.title));
    try std.testing.expectEqualStrings("Open the pane", std.mem.span(parsed.notification.body.?));
    try std.testing.expectEqual(core.schema.NotificationLevel.success, parsed.notification.level);
    try std.testing.expectEqual(@as(u32, 2500), parsed.notification.duration_ms);
    try std.testing.expectEqual(@as(core.schema.PaneId, @enumFromInt(42)), parsed.notification.target.pane);
    try std.testing.expectEqualStrings("/tmp/telar.sock", std.mem.span(parsed.notification.socket.?));
}

test "CLI rejects conflicting notification click targets" {
    const args = [_][*:0]const u8{
        "telar",
        "notification",
        "show",
        "Ready",
        "--pane",
        "1",
        "--tab",
        "2",
    };
    try std.testing.expectError(error.ConflictingNotificationTargets, Cli.parse(&args, .empty));
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
    try std.testing.expectError(error.ConflictingHistoryScopes, Cli.parse(&args, .empty));
}
