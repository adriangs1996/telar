//! Command-line grammar and validated launch options.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");

const pty = backend.pty;

pub const max_args = pty.max_args;

pub const RunOptions = struct {
    command: pty.Command,
    theme: frontend.theme.Theme = frontend.theme.default_theme,
    theme_set: bool = false,
    sidebar_rendering: frontend.kitty.SidebarRendering = .automatic,
    sidebar_renderer_set: bool = false,
    config: ?[*:0]const u8 = null,
    no_config: bool = false,
    profile: ?[*:0]const u8 = null,
    /// SSH destination whose runtime this client attaches to.
    remote: ?[*:0]const u8 = null,
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
        if (args.len < 2 or !std.mem.eql(u8, std.mem.span(args[0]), "show")) {
            return error.MissingNotificationShow;
        }

        var options: NotificationOptions = .{ .title = args[1] };
        if (std.mem.span(options.title).len == 0) {
            return error.EmptyNotificationTitle;
        }

        var target_set = false;
        var level_set = false;
        var duration_set = false;
        var index: usize = 2;
        while (index < args.len) {
            const arg = std.mem.span(args[index]);
            if (std.mem.eql(u8, arg, "--body")) {
                if (options.body != null) {
                    return error.DuplicateNotificationBody;
                }
                if (index + 1 >= args.len) {
                    return error.MissingNotificationBody;
                }

                options.body = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--level")) {
                if (level_set) {
                    return error.DuplicateNotificationLevel;
                }
                if (index + 1 >= args.len) {
                    return error.MissingNotificationLevel;
                }

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
                if (duration_set) {
                    return error.DuplicateNotificationDuration;
                }
                if (index + 1 >= args.len) {
                    return error.MissingNotificationDuration;
                }

                options.duration_ms = try std.fmt.parseUnsigned(
                    u32,
                    std.mem.span(args[index + 1]),
                    10,
                );
                if (options.duration_ms < core.schema.min_notification_duration_ms or
                    options.duration_ms > core.schema.max_notification_duration_ms)
                {
                    return error.InvalidNotificationDuration;
                }

                duration_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--pane")) {
                if (target_set) {
                    return error.ConflictingNotificationTargets;
                }
                if (index + 1 >= args.len) {
                    return error.MissingPaneId;
                }

                options.target = .{ .pane = try core.schema.id.pane(try std.fmt.parseUnsigned(
                    u64,
                    std.mem.span(args[index + 1]),
                    10,
                )) };
                target_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--tab")) {
                if (target_set) {
                    return error.ConflictingNotificationTargets;
                }
                if (index + 1 >= args.len) {
                    return error.MissingTabId;
                }

                options.target = .{ .tab = try core.schema.id.tab(try std.fmt.parseUnsigned(
                    u64,
                    std.mem.span(args[index + 1]),
                    10,
                )) };
                target_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--workspace")) {
                if (target_set) {
                    return error.ConflictingNotificationTargets;
                }
                if (index + 1 >= args.len) {
                    return error.MissingWorkspaceId;
                }

                options.target = .{ .workspace = try core.schema.id.workspace(try std.fmt.parseUnsigned(
                    u64,
                    std.mem.span(args[index + 1]),
                    10,
                )) };
                target_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                if (options.socket != null) {
                    return error.DuplicateSocketOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingSocketPath;
                }

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
    agent: AgentOptions,
    pane: PaneOptions,
    workspace: WorkspaceOptions,
    api: ApiOptions,
    hook: HookOptions,
    integration: IntegrationOptions,
    skill,
    run: RunOptions,

    /// Parses one complete argv into a validated command without performing
    /// filesystem, transport or process work.
    ///
    /// ```zig
    /// const args = [_][*:0]const u8{ "telar", "server" };
    /// const command = try Cli.parse(&args, .empty);
    /// ```
    pub fn parse(args: []const [*:0]const u8, environ: std.process.Environ) !Cli {
        if (args.len == 0) {
            return error.MissingArgvZero;
        }
        if (args.len == 1) {
            return .{ .run = .{ .command = try defaultShell(environ) } };
        }

        const first = std.mem.span(args[1]);
        if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
            return .help;
        }
        if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
            return .version;
        }
        if (std.mem.eql(u8, first, "--skill")) {
            return .skill;
        }
        if (std.mem.eql(u8, first, "agent")) {
            return .{ .agent = try AgentOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "pane")) {
            return .{ .pane = try PaneOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "workspace")) {
            return .{ .workspace = try WorkspaceOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "api")) {
            return .{ .api = try ApiOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "hook")) {
            return .{ .hook = try HookOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "integration")) {
            return .{ .integration = try IntegrationOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "server")) {
            return .{ .server = try ServerOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "history")) {
            return .{ .history = try HistoryOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "notification")) {
            return .{ .notification = try NotificationOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "config")) {
            if (args.len < 3 or !std.mem.eql(u8, std.mem.span(args[2]), "check")) {
                return error.UnknownConfigAction;
            }

            var check: ConfigCheckOptions = .{};
            var check_index: usize = 3;
            while (check_index < args.len) {
                if (std.mem.eql(u8, std.mem.span(args[check_index]), "--profile")) {
                    if (check.profile != null) {
                        return error.DuplicateProfileOption;
                    }
                    if (check_index + 1 >= args.len) {
                        return error.MissingProfileName;
                    }

                    check.profile = args[check_index + 1];
                    check_index += 2;
                } else {
                    if (check.path != null) {
                        return error.TooManyConfigArguments;
                    }

                    check.path = args[check_index];
                    check_index += 1;
                }
            }
            return .{ .config_check = check };
        }
        if (std.mem.eql(u8, first, "plugin-worker")) {
            if (args.len != 9) {
                return error.InvalidPluginWorkerArguments;
            }

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
            if (args.len < 4) {
                return error.MissingPluginArguments;
            }

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
                    plugin_arg + 1 >= args.len)
                {
                    return error.InvalidPluginArguments;
                }
                if (plugin_options.capability_count == plugin_options.capabilities.len) {
                    return error.TooManyPluginCapabilities;
                }

                plugin_options.capabilities[plugin_options.capability_count] =
                    try core.plugin.Capability.parse(std.mem.span(args[plugin_arg + 1]));
                plugin_options.capability_count += 1;
                plugin_arg += 2;
            }
            if (plugin_options.command != .trust and plugin_options.capability_count != 0) {
                return error.InvalidPluginArguments;
            }

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
                if (theme_set) {
                    return error.DuplicateThemeOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingThemeName;
                }

                options.theme = frontend.theme.fromName(std.mem.span(args[command_start + 1])) orelse
                    return error.UnknownTheme;
                theme_set = true;
                options.theme_set = true;
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--theme=")) {
                if (theme_set) {
                    return error.DuplicateThemeOption;
                }

                options.theme = frontend.theme.fromName(arg["--theme=".len..]) orelse
                    return error.UnknownTheme;
                theme_set = true;
                options.theme_set = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--sidebar-renderer")) {
                if (sidebar_renderer_set) {
                    return error.DuplicateSidebarRendererOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingSidebarRenderer;
                }

                options.sidebar_rendering = try frontend.kitty.SidebarRendering.parse(
                    std.mem.span(args[command_start + 1]),
                );
                sidebar_renderer_set = true;
                options.sidebar_renderer_set = true;
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--sidebar-renderer=")) {
                if (sidebar_renderer_set) {
                    return error.DuplicateSidebarRendererOption;
                }

                options.sidebar_rendering = try frontend.kitty.SidebarRendering.parse(
                    arg["--sidebar-renderer=".len..],
                );
                sidebar_renderer_set = true;
                options.sidebar_renderer_set = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--remote")) {
                if (options.remote != null) {
                    return error.DuplicateRemoteOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingRemoteDestination;
                }

                options.remote = args[command_start + 1];
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--remote=")) {
                if (options.remote != null) {
                    return error.DuplicateRemoteOption;
                }
                if (arg["--remote=".len..].len == 0) {
                    return error.MissingRemoteDestination;
                }

                options.remote = args[command_start] + "--remote=".len;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--config")) {
                if (options.config != null or options.no_config) {
                    return error.DuplicateConfigOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingConfigPath;
                }

                options.config = args[command_start + 1];
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--config=")) {
                if (options.config != null or options.no_config) {
                    return error.DuplicateConfigOption;
                }
                if (arg["--config=".len..].len == 0) {
                    return error.MissingConfigPath;
                }

                options.config = args[command_start] + "--config=".len;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-config")) {
                if (options.config != null or options.no_config) {
                    return error.DuplicateConfigOption;
                }

                options.no_config = true;
                command_start += 1;
                continue;
            }
            if (std.mem.eql(u8, arg, "--profile")) {
                if (options.profile != null) {
                    return error.DuplicateProfileOption;
                }
                if (command_start + 1 >= args.len) {
                    return error.MissingProfileName;
                }

                options.profile = args[command_start + 1];
                command_start += 2;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--profile=")) {
                if (options.profile != null) {
                    return error.DuplicateProfileOption;
                }
                if (arg["--profile=".len..].len == 0) {
                    return error.MissingProfileName;
                }

                options.profile = args[command_start] + "--profile=".len;
                command_start += 1;
                continue;
            }
            break;
        }
        if (command_start == args.len) {
            if (delimiter_seen) {
                return error.MissingCommand;
            }

            options.command = try defaultShell(environ);
        } else {
            options.command = try pty.Command.fromArgv(args[command_start..]);
        }

        if (options.no_config and options.profile != null) {
            return error.ProfileWithoutConfig;
        }

        return .{ .run = options };
    }
};

fn parseWorkerBool(value: [*:0]const u8) !bool {
    const text = std.mem.span(value);
    if (std.mem.eql(u8, text, "0")) {
        return false;
    }
    if (std.mem.eql(u8, text, "1")) {
        return true;
    }

    return error.InvalidPluginWorkerArguments;
}

pub const HistoryAction = enum {
    import,
    delete,
    prune,
    show,
    stats,
    list,
    search,
};

pub const HistoryImportKind = enum { auto, zsh, bash, fish };

pub const HistoryOptions = struct {
    action: HistoryAction,
    import_kind: HistoryImportKind = .auto,
    import_file: ?[*:0]const u8 = null,
    delete_id: u64 = 0,
    before_ms: i64 = 0,
    period_days: u16 = 0,
    dry_run: bool = false,
    assume_yes: bool = false,
    query: ?[*:0]const u8 = null,
    scope: core.schema.HistoryScope = .global,
    scope_value: ?[*:0]const u8 = null,
    pane_id: core.schema.PaneId = .invalid,
    failed_only: bool = false,
    author: core.schema.HistoryAuthorFilter = .all,
    limit: u16 = 20,
    socket: ?[*:0]const u8 = null,

    fn parse(args: []const [*:0]const u8) !HistoryOptions {
        if (args.len == 0) {
            return error.MissingHistoryAction;
        }

        const action_text = std.mem.span(args[0]);
        var options: HistoryOptions = if (std.mem.eql(u8, action_text, "list"))
            .{ .action = .list }
        else if (std.mem.eql(u8, action_text, "search")) search: {
            if (args.len < 2) {
                return error.MissingHistoryQuery;
            }

            break :search .{ .action = .search, .query = args[1] };
        } else if (std.mem.eql(u8, action_text, "stats")) .{
            .action = .stats,
        } else if (std.mem.eql(u8, action_text, "show")) show: {
            if (args.len < 2) {
                return error.MissingHistoryId;
            }

            const raw = try std.fmt.parseInt(u64, std.mem.span(args[1]), 10);
            if (raw == 0) {
                return error.InvalidHistoryId;
            }

            break :show .{ .action = .show, .delete_id = raw };
        } else if (std.mem.eql(u8, action_text, "delete")) delete: {
            if (args.len < 2) {
                return error.MissingHistoryId;
            }

            const raw = try std.fmt.parseInt(u64, std.mem.span(args[1]), 10);
            if (raw == 0) {
                return error.InvalidHistoryId;
            }

            break :delete .{ .action = .delete, .delete_id = raw };
        } else if (std.mem.eql(u8, action_text, "prune")) .{
            .action = .prune,
        } else if (std.mem.eql(u8, action_text, "import")) import: {
            var imported: HistoryOptions = .{ .action = .import };
            if (args.len > 1 and args[1][0] != '-') {
                const kind = std.mem.span(args[1]);
                imported.import_kind = if (std.mem.eql(u8, kind, "auto"))
                    .auto
                else if (std.mem.eql(u8, kind, "zsh"))
                    .zsh
                else if (std.mem.eql(u8, kind, "bash"))
                    .bash
                else if (std.mem.eql(u8, kind, "fish"))
                    .fish
                else
                    return error.UnknownHistoryImportKind;
            }

            break :import imported;
        } else return error.UnknownHistoryAction;

        var index: usize = switch (options.action) {
            .search, .delete, .show => 2,
            .import => if (args.len > 1 and args[1][0] != '-') 2 else 1,
            else => 1,
        };
        while (index < args.len) {
            const arg = std.mem.span(args[index]);
            if (std.mem.eql(u8, arg, "--file")) {
                if (options.action != .import) {
                    return error.UnknownHistoryOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingHistoryFile;
                }

                options.import_file = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--cwd")) {
                try options.setScope(.cwd, null);
                index += 1;
            } else if (std.mem.eql(u8, arg, "--workspace")) {
                if (index + 1 >= args.len) {
                    return error.MissingWorkspacePath;
                }

                try options.setScope(.workspace, args[index + 1]);
                index += 2;
            } else if (std.mem.eql(u8, arg, "--pane")) {
                if (index + 1 >= args.len) {
                    return error.MissingPaneId;
                }

                const raw = try std.fmt.parseInt(u64, std.mem.span(args[index + 1]), 10);
                options.pane_id = try core.schema.id.pane(raw);
                try options.setScope(.pane, null);
                index += 2;
            } else if (std.mem.eql(u8, arg, "--failed")) {
                options.failed_only = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--period")) {
                if (options.action != .stats) {
                    return error.UnknownHistoryOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingHistoryPeriod;
                }

                const period = std.mem.span(args[index + 1]);
                options.period_days = if (std.mem.eql(u8, period, "today"))
                    1
                else if (std.mem.eql(u8, period, "week"))
                    7
                else if (std.mem.eql(u8, period, "month"))
                    30
                else if (std.mem.eql(u8, period, "year"))
                    365
                else if (std.mem.eql(u8, period, "all"))
                    0
                else
                    return error.InvalidHistoryPeriod;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--before")) {
                if (options.action != .prune) {
                    return error.UnknownHistoryOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingHistoryBefore;
                }

                options.before_ms = try parseBeforeDate(std.mem.span(args[index + 1]));
                index += 2;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                if (options.action != .prune) {
                    return error.UnknownHistoryOption;
                }

                options.dry_run = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--yes")) {
                if (options.action != .prune) {
                    return error.UnknownHistoryOption;
                }

                options.assume_yes = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--match")) {
                if (options.action != .prune) {
                    return error.UnknownHistoryOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingHistoryQuery;
                }

                options.query = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--author")) {
                if (index + 1 >= args.len) {
                    return error.MissingHistoryAuthor;
                }

                const author = std.mem.span(args[index + 1]);
                options.author = if (std.mem.eql(u8, author, "all"))
                    .all
                else if (std.mem.eql(u8, author, "human"))
                    .human
                else if (std.mem.eql(u8, author, "agent"))
                    .agent
                else
                    return error.InvalidHistoryAuthor;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--limit")) {
                if (index + 1 >= args.len) {
                    return error.MissingHistoryLimit;
                }

                options.limit = try std.fmt.parseInt(u16, std.mem.span(args[index + 1]), 10);
                if (options.limit == 0 or options.limit > core.schema.max_history_results) {
                    return error.InvalidHistoryLimit;
                }

                index += 2;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                if (index + 1 >= args.len) {
                    return error.MissingSocketPath;
                }
                if (options.socket != null) {
                    return error.DuplicateSocketOption;
                }

                options.socket = args[index + 1];
                index += 2;
            } else {
                return error.UnknownHistoryOption;
            }
        }
        return options;
    }

    /// Parses `--before` as `YYYY-MM-DD` (UTC midnight) or unix seconds.
    fn parseBeforeDate(text: []const u8) !i64 {
        if (std.mem.indexOfScalar(u8, text, '-')) |_| {
            var parts = std.mem.splitScalar(u8, text, '-');
            const year = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidHistoryBefore, 10);
            const month = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidHistoryBefore, 10);
            const day = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidHistoryBefore, 10);
            if (parts.next() != null or year < 1970 or month < 1 or month > 12 or day < 1 or day > 31) {
                return error.InvalidHistoryBefore;
            }

            const epoch_days = daysFromCivil(year, month, day);
            return epoch_days * 86_400_000;
        }

        const seconds = try std.fmt.parseInt(i64, text, 10);
        if (seconds <= 0) {
            return error.InvalidHistoryBefore;
        }

        return seconds * 1_000;
    }

    /// Howard Hinnant's days-from-civil algorithm.
    fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
        const y = if (month <= 2) year - 1 else year;
        const era = @divFloor(y, 400);
        const yoe = y - era * 400;
        const mp = @mod(month + 9, 12);
        const doy = @divFloor(153 * mp + 2, 5) + day - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146_097 + doe - 719_468;
    }

    fn setScope(options: *HistoryOptions, scope: core.schema.HistoryScope, value: ?[*:0]const u8) !void {
        if (options.scope != .global) {
            return error.ConflictingHistoryScopes;
        }

        options.scope = scope;
        options.scope_value = value;
    }
};

pub const AgentAction = enum { list, get, wait, prompt, read, report_session };

pub const PaneAction = enum { read, send_keys, focus };

/// How a CLI argument names a pane or the agent inside it.
pub const Target = union(enum) {
    /// The pane this process runs in, from `TELAR_PANE_ID`.
    current,
    pane: u64,
    name: [*:0]const u8,

    fn parse(value: [*:0]const u8) Target {
        const text = std.mem.span(value);
        if (std.mem.eql(u8, text, "--current")) {
            return .current;
        }

        if (std.fmt.parseUnsigned(u64, text, 10)) |raw| {
            return .{ .pane = raw };
        } else |_| {
            return .{ .name = value };
        }
    }
};

pub const max_wait_timeout_seconds = 3600;
pub const default_wait_timeout_seconds = 30;

pub const AgentOptions = struct {
    action: AgentAction,
    target: ?Target = null,
    until: core.schema.AgentStatus = .done,
    timeout_seconds: u32 = default_wait_timeout_seconds,
    text: ?[*:0]const u8 = null,
    wait_after_prompt: bool = false,
    lines: u16 = 40,
    source: core.schema.PaneTextSource = .recent,
    json: bool = false,
    socket: ?[*:0]const u8 = null,

    fn parse(args: []const [*:0]const u8) !AgentOptions {
        if (args.len == 0) {
            return error.MissingAgentAction;
        }

        const action_text = std.mem.span(args[0]);
        const action: AgentAction = if (std.mem.eql(u8, action_text, "list"))
            .list
        else if (std.mem.eql(u8, action_text, "get"))
            .get
        else if (std.mem.eql(u8, action_text, "wait"))
            .wait
        else if (std.mem.eql(u8, action_text, "prompt"))
            .prompt
        else if (std.mem.eql(u8, action_text, "read"))
            .read
        else if (std.mem.eql(u8, action_text, "report-session"))
            .report_session
        else
            return error.UnknownAgentAction;
        var options: AgentOptions = .{ .action = action };
        var index: usize = 1;

        if (action != .list) {
            if (args.len < 2) {
                return error.MissingAgentTarget;
            }

            options.target = Target.parse(args[1]);
            index = 2;
        }

        if (action == .report_session) {
            if (args.len < 3) {
                return error.MissingSessionReference;
            }

            options.text = args[2];
            if (std.mem.span(options.text.?).len == 0 or std.mem.span(options.text.?).len > core.schema.max_agent_session_reference_bytes) {
                return error.InvalidSessionReference;
            }

            index = 3;
        }

        if (action == .prompt) {
            if (args.len < 3) {
                return error.MissingPromptText;
            }

            options.text = args[2];
            if (std.mem.span(options.text.?).len == 0 or std.mem.span(options.text.?).len > core.schema.max_pane_text_input_bytes) {
                return error.InvalidPromptText;
            }

            index = 3;
        }

        while (index < args.len) {
            const arg = std.mem.span(args[index]);
            if (std.mem.eql(u8, arg, "--json")) {
                options.json = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--wait")) {
                if (action != .prompt) {
                    return error.UnknownAgentOption;
                }

                options.wait_after_prompt = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--until")) {
                if (action != .wait) {
                    return error.UnknownAgentOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingWaitStatus;
                }

                options.until = try parseWaitStatus(std.mem.span(args[index + 1]));
                index += 2;
            } else if (std.mem.eql(u8, arg, "--timeout")) {
                if (action != .wait and action != .prompt) {
                    return error.UnknownAgentOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingTimeout;
                }

                options.timeout_seconds = try parseTimeoutSeconds(std.mem.span(args[index + 1]));
                index += 2;
            } else if (std.mem.eql(u8, arg, "--lines")) {
                if (action != .read) {
                    return error.UnknownAgentOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingLineCount;
                }

                options.lines = try parseLineCount(std.mem.span(args[index + 1]));
                index += 2;
            } else if (std.mem.eql(u8, arg, "--source")) {
                if (action != .read) {
                    return error.UnknownAgentOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingTextSource;
                }

                options.source = try parseTextSource(std.mem.span(args[index + 1]));
                index += 2;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                if (index + 1 >= args.len) {
                    return error.MissingSocketPath;
                }
                if (options.socket != null) {
                    return error.DuplicateSocketOption;
                }

                options.socket = args[index + 1];
                index += 2;
            } else {
                return error.UnknownAgentOption;
            }
        }

        return options;
    }
};

pub const PaneOptions = struct {
    action: PaneAction,
    target: Target,
    text: ?[*:0]const u8 = null,
    enter: bool = false,
    lines: u16 = 40,
    source: core.schema.PaneTextSource = .recent,
    json: bool = false,
    socket: ?[*:0]const u8 = null,
    direction: ?core.schema.PaneDirection = null,

    fn parse(args: []const [*:0]const u8) !PaneOptions {
        if (args.len == 0) {
            return error.MissingPaneAction;
        }

        const action_text = std.mem.span(args[0]);
        const action: PaneAction = if (std.mem.eql(u8, action_text, "read"))
            .read
        else if (std.mem.eql(u8, action_text, "send-keys"))
            .send_keys
        else if (std.mem.eql(u8, action_text, "focus"))
            .focus
        else
            return error.UnknownPaneAction;
        if (args.len < 2) {
            return error.MissingPaneTarget;
        }

        var options: PaneOptions = .{ .action = action, .target = Target.parse(args[1]) };
        if (options.target == .name) {
            return error.InvalidPaneId;
        }
        if (action == .focus and options.target != .current) {
            return error.FocusRequiresCurrentPane;
        }

        var index: usize = 2;
        if (action == .send_keys) {
            if (args.len < 3) {
                return error.MissingSendText;
            }

            options.text = args[2];
            if (std.mem.span(options.text.?).len == 0 or std.mem.span(options.text.?).len > core.schema.max_pane_text_input_bytes) {
                return error.InvalidSendText;
            }

            index = 3;
        }

        while (index < args.len) {
            const arg = std.mem.span(args[index]);
            if (std.mem.eql(u8, arg, "--json")) {
                options.json = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--enter")) {
                if (action != .send_keys) {
                    return error.UnknownPaneOption;
                }

                options.enter = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--lines")) {
                if (action != .read) {
                    return error.UnknownPaneOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingLineCount;
                }

                options.lines = try parseLineCount(std.mem.span(args[index + 1]));
                index += 2;
            } else if (std.mem.eql(u8, arg, "--source")) {
                if (action != .read) {
                    return error.UnknownPaneOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingTextSource;
                }

                options.source = try parseTextSource(std.mem.span(args[index + 1]));
                index += 2;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                if (index + 1 >= args.len) {
                    return error.MissingSocketPath;
                }
                if (options.socket != null) {
                    return error.DuplicateSocketOption;
                }

                options.socket = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--direction")) {
                if (action != .focus or index + 1 >= args.len or options.direction != null) {
                    return error.UnknownPaneOption;
                }

                options.direction = parsePaneDirection(std.mem.span(args[index + 1])) orelse return error.InvalidPaneDirection;
                index += 2;
            } else {
                return error.UnknownPaneOption;
            }
        }

        if (action == .focus and options.direction == null) {
            return error.MissingPaneDirection;
        }

        return options;
    }
};

fn parsePaneDirection(value: []const u8) ?core.schema.PaneDirection {
    if (std.mem.eql(u8, value, "left")) {
        return .left;
    }

    if (std.mem.eql(u8, value, "right")) {
        return .right;
    }

    if (std.mem.eql(u8, value, "up")) {
        return .up;
    }

    if (std.mem.eql(u8, value, "down")) {
        return .down;
    }

    return null;
}

pub const WorkspaceAction = enum { create };

pub const max_worktree_branch_bytes = 200;

pub const WorkspaceOptions = struct {
    action: WorkspaceAction,
    branch: ?[*:0]const u8 = null,
    name: ?[*:0]const u8 = null,
    directory: ?[*:0]const u8 = null,
    socket: ?[*:0]const u8 = null,
    json: bool = false,

    fn parse(args: []const [*:0]const u8) !WorkspaceOptions {
        if (args.len == 0) {
            return error.MissingWorkspaceAction;
        }

        if (!std.mem.eql(u8, std.mem.span(args[0]), "create")) {
            return error.UnknownWorkspaceAction;
        }

        var options: WorkspaceOptions = .{ .action = .create };
        var index: usize = 1;
        while (index < args.len) {
            const arg = std.mem.span(args[index]);
            if (std.mem.eql(u8, arg, "--worktree")) {
                if (index + 1 >= args.len) {
                    return error.MissingWorktreeBranch;
                }
                if (options.branch != null) {
                    return error.DuplicateWorktreeOption;
                }

                try validateWorktreeBranch(std.mem.span(args[index + 1]));
                options.branch = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--name")) {
                if (index + 1 >= args.len) {
                    return error.MissingWorkspaceName;
                }
                if (options.name != null) {
                    return error.DuplicateNameOption;
                }

                options.name = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--directory")) {
                if (index + 1 >= args.len) {
                    return error.MissingWorktreeDirectory;
                }
                if (options.directory != null) {
                    return error.DuplicateDirectoryOption;
                }

                options.directory = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                if (index + 1 >= args.len) {
                    return error.MissingSocketPath;
                }
                if (options.socket != null) {
                    return error.DuplicateSocketOption;
                }

                options.socket = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--json")) {
                options.json = true;
                index += 1;
            } else {
                return error.UnknownWorkspaceOption;
            }
        }

        if (options.branch == null) {
            return error.MissingWorktreeBranch;
        }

        return options;
    }
};

/// Rejects names git could parse as options or refs with traversal, so the
/// worktree argv stays positional and the derived directory stays contained.
fn validateWorktreeBranch(branch: []const u8) !void {
    if (branch.len == 0 or branch.len > max_worktree_branch_bytes) {
        return error.InvalidWorktreeBranch;
    }
    if (branch[0] == '-' or branch[0] == '.') {
        return error.InvalidWorktreeBranch;
    }
    if (std.mem.indexOf(u8, branch, "..") != null) {
        return error.InvalidWorktreeBranch;
    }

    for (branch) |byte| {
        if (byte <= ' ' or byte == 0x7f or byte == '~' or byte == '^' or byte == ':') {
            return error.InvalidWorktreeBranch;
        }
    }
}

pub const HookAgent = enum { claude, codex };

pub const HookOptions = struct {
    agent: HookAgent,
    socket: ?[*:0]const u8 = null,

    fn parse(args: []const [*:0]const u8) !HookOptions {
        if (args.len == 0) {
            return error.MissingHookAgent;
        }
        var options: HookOptions = .{ .agent = try parseHookAgent(std.mem.span(args[0])) };
        var index: usize = 1;
        while (index < args.len) : (index += 2) {
            if (!std.mem.eql(u8, std.mem.span(args[index]), "--socket") or index + 1 >= args.len) {
                return error.UnknownHookOption;
            }
            options.socket = args[index + 1];
        }
        return options;
    }
};

pub const IntegrationAction = enum { install, uninstall, status };

pub const IntegrationOptions = struct {
    action: IntegrationAction,
    agent: HookAgent,
    settings: ?[*:0]const u8 = null,

    fn parse(args: []const [*:0]const u8) !IntegrationOptions {
        if (args.len < 2) {
            return error.MissingIntegrationArguments;
        }

        const action_text = std.mem.span(args[0]);
        const action: IntegrationAction = if (std.mem.eql(u8, action_text, "install"))
            .install
        else if (std.mem.eql(u8, action_text, "uninstall"))
            .uninstall
        else if (std.mem.eql(u8, action_text, "status"))
            .status
        else
            return error.UnknownIntegrationAction;
        var options: IntegrationOptions = .{ .action = action, .agent = try parseHookAgent(std.mem.span(args[1])) };
        var index: usize = 2;
        while (index < args.len) : (index += 2) {
            if (!std.mem.eql(u8, std.mem.span(args[index]), "--settings") or index + 1 >= args.len) {
                return error.UnknownIntegrationOption;
            }
            options.settings = args[index + 1];
        }
        return options;
    }
};

fn parseHookAgent(text: []const u8) !HookAgent {
    if (std.mem.eql(u8, text, "claude")) {
        return .claude;
    }
    if (std.mem.eql(u8, text, "codex")) {
        return .codex;
    }

    return error.UnknownHookAgent;
}

pub const ApiOptions = struct {
    json: bool = false,

    fn parse(args: []const [*:0]const u8) !ApiOptions {
        if (args.len == 0 or !std.mem.eql(u8, std.mem.span(args[0]), "schema")) {
            return error.UnknownApiAction;
        }

        var options: ApiOptions = .{};
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, std.mem.span(arg), "--json")) {
                options.json = true;
            } else {
                return error.UnknownApiOption;
            }
        }

        return options;
    }
};

fn parseWaitStatus(text: []const u8) !core.schema.AgentStatus {
    if (std.mem.eql(u8, text, "done")) return .done;
    if (std.mem.eql(u8, text, "ready") or std.mem.eql(u8, text, "idle")) return .ready;
    if (std.mem.eql(u8, text, "blocked")) return .blocked;
    if (std.mem.eql(u8, text, "working")) return .working;
    if (std.mem.eql(u8, text, "failed")) return .failed;
    return error.InvalidWaitStatus;
}

fn parseTimeoutSeconds(text: []const u8) !u32 {
    const seconds = std.fmt.parseUnsigned(u32, std.mem.trimEnd(u8, text, "s"), 10) catch
        return error.InvalidTimeout;
    if (seconds == 0 or seconds > max_wait_timeout_seconds) {
        return error.InvalidTimeout;
    }

    return seconds;
}

fn parseLineCount(text: []const u8) !u16 {
    const lines = std.fmt.parseUnsigned(u16, text, 10) catch return error.InvalidLineCount;
    if (lines == 0 or lines > core.schema.max_pane_text_rows) {
        return error.InvalidLineCount;
    }

    return lines;
}

fn parseTextSource(text: []const u8) !core.schema.PaneTextSource {
    if (std.mem.eql(u8, text, "screen")) return .screen;
    if (std.mem.eql(u8, text, "recent")) return .recent;
    return error.InvalidTextSource;
}

pub const ServerMode = enum {
    foreground,
    background_launcher,
    daemonized,
};

pub const ServerAction = enum {
    run,
    stop,
    /// Ensure the runtime is running and print its socket path. Used by
    /// `telar --remote` over SSH to discover the remote endpoint.
    endpoint,
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
                if (action_explicit) {
                    return error.DuplicateServerAction;
                }

                options.action = .stop;
                action_explicit = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "endpoint")) {
                if (action_explicit) {
                    return error.DuplicateServerAction;
                }

                options.action = .endpoint;
                action_explicit = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--background")) {
                if (options.mode != .foreground) {
                    return error.ConflictingServerModes;
                }

                options.mode = .background_launcher;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--daemonized")) {
                if (options.mode != .foreground) {
                    return error.ConflictingServerModes;
                }

                options.mode = .daemonized;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--socket")) {
                if (options.socket != null) {
                    return error.DuplicateSocketOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingSocketPath;
                }

                options.socket = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--graphics-pane-mib")) {
                if (index + 1 >= args.len) {
                    return error.MissingGraphicsPaneLimit;
                }

                options.graphics.pane_bytes = try parseMebibytes(args[index + 1]);
                options.graphics_pane_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--graphics-global-mib")) {
                if (index + 1 >= args.len) {
                    return error.MissingGraphicsGlobalLimit;
                }

                options.graphics.global_bytes = try parseMebibytes(args[index + 1]);
                options.graphics_global_set = true;
                index += 2;
            } else if (std.mem.eql(u8, arg, "--config")) {
                if (options.config != null or options.no_config) {
                    return error.DuplicateConfigOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingConfigPath;
                }

                options.config = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, arg, "--no-config")) {
                if (options.config != null or options.no_config) {
                    return error.DuplicateConfigOption;
                }

                options.no_config = true;
                index += 1;
            } else if (std.mem.eql(u8, arg, "--profile")) {
                if (options.profile != null) {
                    return error.DuplicateProfileOption;
                }
                if (index + 1 >= args.len) {
                    return error.MissingProfileName;
                }

                options.profile = args[index + 1];
                index += 2;
            } else {
                return error.UnknownServerOption;
            }
        }
        if (options.action == .stop and options.mode != .foreground) {
            return error.ConflictingServerAction;
        }
        if (options.no_config and options.profile != null) {
            return error.ProfileWithoutConfig;
        }

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
    if (configured.len == 0) {
        return pty.Command.fromArgv(&.{fallback});
    }

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

test "CLI parses the isolated plugin worker context" {
    const args = [_][*:0]const u8{
        "telar",
        "plugin-worker",
        "/plugin/main.lua",
        "refresh",
        "1",
        "4",
        "2",
        "3",
        "42",
    };

    const cli = try Cli.parse(&args, .empty);

    try std.testing.expect(cli == .plugin_worker);
    try std.testing.expectEqualStrings("/plugin/main.lua", std.mem.span(cli.plugin_worker.entry));
    try std.testing.expectEqualStrings("refresh", std.mem.span(cli.plugin_worker.action));
    try std.testing.expect(cli.plugin_worker.context.sidebar_visible);
    try std.testing.expectEqual(@as(u16, 4), cli.plugin_worker.context.tab_count);
    try std.testing.expectEqual(@as(u16, 2), cli.plugin_worker.context.active_tab_index);
    try std.testing.expectEqual(@as(u16, 3), cli.plugin_worker.context.pane_count);
    try std.testing.expectEqual(@as(u64, 42), cli.plugin_worker.context.focused_pane_id);
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

test "CLI parses agent commands with their targets and options" {
    const list = [_][*:0]const u8{ "telar", "agent", "list", "--json" };
    const list_cli = try Cli.parse(&list, .empty);
    try std.testing.expectEqual(AgentAction.list, list_cli.agent.action);
    try std.testing.expect(list_cli.agent.json);
    try std.testing.expect(list_cli.agent.target == null);

    const wait = [_][*:0]const u8{ "telar", "agent", "wait", "7", "--until", "blocked", "--timeout", "90s" };
    const wait_cli = try Cli.parse(&wait, .empty);
    try std.testing.expectEqual(AgentAction.wait, wait_cli.agent.action);
    try std.testing.expectEqual(@as(u64, 7), wait_cli.agent.target.?.pane);
    try std.testing.expectEqual(core.schema.AgentStatus.blocked, wait_cli.agent.until);
    try std.testing.expectEqual(@as(u32, 90), wait_cli.agent.timeout_seconds);

    const prompt = [_][*:0]const u8{ "telar", "agent", "prompt", "--current", "run the tests", "--wait" };
    const prompt_cli = try Cli.parse(&prompt, .empty);
    try std.testing.expect(prompt_cli.agent.target.? == .current);
    try std.testing.expectEqualStrings("run the tests", std.mem.span(prompt_cli.agent.text.?));
    try std.testing.expect(prompt_cli.agent.wait_after_prompt);

    const read = [_][*:0]const u8{ "telar", "agent", "read", "Investigate proxy", "--lines", "25", "--source", "screen" };
    const read_cli = try Cli.parse(&read, .empty);
    try std.testing.expectEqualStrings("Investigate proxy", std.mem.span(read_cli.agent.target.?.name));
    try std.testing.expectEqual(@as(u16, 25), read_cli.agent.lines);
    try std.testing.expectEqual(core.schema.PaneTextSource.screen, read_cli.agent.source);
}

test "CLI rejects malformed agent commands" {
    const no_target = [_][*:0]const u8{ "telar", "agent", "get" };
    try std.testing.expectError(error.MissingAgentTarget, Cli.parse(&no_target, .empty));

    const bad_status = [_][*:0]const u8{ "telar", "agent", "wait", "1", "--until", "sleeping" };
    try std.testing.expectError(error.InvalidWaitStatus, Cli.parse(&bad_status, .empty));

    const bad_timeout = [_][*:0]const u8{ "telar", "agent", "wait", "1", "--timeout", "0" };
    try std.testing.expectError(error.InvalidTimeout, Cli.parse(&bad_timeout, .empty));

    const wait_on_list = [_][*:0]const u8{ "telar", "agent", "list", "--wait" };
    try std.testing.expectError(error.UnknownAgentOption, Cli.parse(&wait_on_list, .empty));

    const empty_prompt = [_][*:0]const u8{ "telar", "agent", "prompt", "1", "" };
    try std.testing.expectError(error.InvalidPromptText, Cli.parse(&empty_prompt, .empty));
}

test "CLI parses pane commands and refuses names as pane ids" {
    const read = [_][*:0]const u8{ "telar", "pane", "read", "4", "--lines", "10" };
    const read_cli = try Cli.parse(&read, .empty);
    try std.testing.expectEqual(PaneAction.read, read_cli.pane.action);
    try std.testing.expectEqual(@as(u64, 4), read_cli.pane.target.pane);
    try std.testing.expectEqual(@as(u16, 10), read_cli.pane.lines);

    const send = [_][*:0]const u8{ "telar", "pane", "send-keys", "--current", "y", "--enter" };
    const send_cli = try Cli.parse(&send, .empty);
    try std.testing.expectEqual(PaneAction.send_keys, send_cli.pane.action);
    try std.testing.expect(send_cli.pane.target == .current);
    try std.testing.expectEqualStrings("y", std.mem.span(send_cli.pane.text.?));
    try std.testing.expect(send_cli.pane.enter);

    const focus = [_][*:0]const u8{ "telar", "pane", "focus", "--current", "--direction", "left", "--json" };
    const focus_cli = try Cli.parse(&focus, .empty);
    try std.testing.expectEqual(PaneAction.focus, focus_cli.pane.action);
    try std.testing.expect(focus_cli.pane.target == .current);
    try std.testing.expectEqual(core.schema.PaneDirection.left, focus_cli.pane.direction.?);
    try std.testing.expect(focus_cli.pane.json);

    const inexact_focus = [_][*:0]const u8{ "telar", "pane", "focus", "4", "--direction", "left" };
    try std.testing.expectError(error.FocusRequiresCurrentPane, Cli.parse(&inexact_focus, .empty));

    const directionless_focus = [_][*:0]const u8{ "telar", "pane", "focus", "--current" };
    try std.testing.expectError(error.MissingPaneDirection, Cli.parse(&directionless_focus, .empty));

    const named = [_][*:0]const u8{ "telar", "pane", "read", "main" };
    try std.testing.expectError(error.InvalidPaneId, Cli.parse(&named, .empty));
}

test "CLI parses the api schema command and the skill flag" {
    const schema_args = [_][*:0]const u8{ "telar", "api", "schema", "--json" };
    const schema_cli = try Cli.parse(&schema_args, .empty);
    try std.testing.expect(schema_cli.api.json);

    const skill_args = [_][*:0]const u8{ "telar", "--skill" };
    try std.testing.expect(try Cli.parse(&skill_args, .empty) == .skill);

    const unknown = [_][*:0]const u8{ "telar", "api", "events" };
    try std.testing.expectError(error.UnknownApiAction, Cli.parse(&unknown, .empty));
}

test "CLI parses agent session reports" {
    const args = [_][*:0]const u8{ "telar", "agent", "report-session", "--current", "0192aaaa-bbbb-cccc-dddd-eeeeffff0000" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(AgentAction.report_session, cli.agent.action);
    try std.testing.expect(cli.agent.target.? == .current);
    try std.testing.expectEqualStrings("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", std.mem.span(cli.agent.text.?));

    const missing = [_][*:0]const u8{ "telar", "agent", "report-session", "7" };
    try std.testing.expectError(error.MissingSessionReference, Cli.parse(&missing, .empty));
}

test "CLI parses hook and integration commands" {
    const hook = [_][*:0]const u8{ "telar", "hook", "claude" };
    try std.testing.expectEqual(HookAgent.claude, (try Cli.parse(&hook, .empty)).hook.agent);

    const codex_hook = [_][*:0]const u8{ "telar", "hook", "codex" };
    try std.testing.expectEqual(HookAgent.codex, (try Cli.parse(&codex_hook, .empty)).hook.agent);

    const install = [_][*:0]const u8{ "telar", "integration", "install", "claude", "--settings", "/tmp/s.json" };
    const cli = try Cli.parse(&install, .empty);
    try std.testing.expectEqual(IntegrationAction.install, cli.integration.action);
    try std.testing.expectEqualStrings("/tmp/s.json", std.mem.span(cli.integration.settings.?));

    const codex_install = [_][*:0]const u8{ "telar", "integration", "install", "codex" };
    try std.testing.expectEqual(HookAgent.codex, (try Cli.parse(&codex_install, .empty)).integration.agent);

    const unknown = [_][*:0]const u8{ "telar", "integration", "install", "gemini" };
    try std.testing.expectError(error.UnknownHookAgent, Cli.parse(&unknown, .empty));
}

test "CLI parses the remote destination and the server endpoint action" {
    const remote = [_][*:0]const u8{ "telar", "--remote", "dev@build-box", "/bin/zsh" };
    const cli = try Cli.parse(&remote, .empty);
    try std.testing.expectEqualStrings("dev@build-box", std.mem.span(cli.run.remote.?));
    try std.testing.expectEqualStrings("/bin/zsh", std.mem.span(cli.run.command.file));

    const endpoint = [_][*:0]const u8{ "telar", "server", "endpoint" };
    try std.testing.expectEqual(ServerAction.endpoint, (try Cli.parse(&endpoint, .empty)).server.action);
}

test "workspace create parses worktree flags and rejects unsafe branches" {
    const args = [_][*:0]const u8{ "telar", "workspace", "create", "--worktree", "fix/tabs", "--name", "fix", "--json" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqualStrings("fix/tabs", std.mem.span(cli.workspace.branch.?));
    try std.testing.expectEqualStrings("fix", std.mem.span(cli.workspace.name.?));
    try std.testing.expect(cli.workspace.json);

    const missing = [_][*:0]const u8{ "telar", "workspace", "create" };
    try std.testing.expectError(error.MissingWorktreeBranch, Cli.parse(&missing, .empty));

    const dash = [_][*:0]const u8{ "telar", "workspace", "create", "--worktree", "-evil" };
    try std.testing.expectError(error.InvalidWorktreeBranch, Cli.parse(&dash, .empty));

    const traversal = [_][*:0]const u8{ "telar", "workspace", "create", "--worktree", "a/../b" };
    try std.testing.expectError(error.InvalidWorktreeBranch, Cli.parse(&traversal, .empty));

    const unknown = [_][*:0]const u8{ "telar", "workspace", "remove" };
    try std.testing.expectError(error.UnknownWorkspaceAction, Cli.parse(&unknown, .empty));
}

test "history author filter parses and rejects unknown values" {
    const agent_only = [_][*:0]const u8{ "telar", "history", "list", "--author", "agent" };
    const cli = try Cli.parse(&agent_only, .empty);
    try std.testing.expectEqual(core.schema.HistoryAuthorFilter.agent, cli.history.author);

    const invalid = [_][*:0]const u8{ "telar", "history", "list", "--author", "robot" };
    try std.testing.expectError(error.InvalidHistoryAuthor, Cli.parse(&invalid, .empty));
}

test "history import parses kinds and the file option" {
    const explicit = [_][*:0]const u8{ "telar", "history", "import", "fish", "--file", "/tmp/h" };
    const cli = try Cli.parse(&explicit, .empty);
    try std.testing.expectEqual(HistoryImportKind.fish, cli.history.import_kind);
    try std.testing.expectEqualStrings("/tmp/h", std.mem.span(cli.history.import_file.?));

    const auto = [_][*:0]const u8{ "telar", "history", "import" };
    try std.testing.expectEqual(HistoryImportKind.auto, (try Cli.parse(&auto, .empty)).history.import_kind);

    const unknown = [_][*:0]const u8{ "telar", "history", "import", "powershell" };
    try std.testing.expectError(error.UnknownHistoryImportKind, Cli.parse(&unknown, .empty));

    const misplaced = [_][*:0]const u8{ "telar", "history", "list", "--file", "/tmp/h" };
    try std.testing.expectError(error.UnknownHistoryOption, Cli.parse(&misplaced, .empty));
}

test "history stats parses periods and rejects unknown ones" {
    const week = [_][*:0]const u8{ "telar", "history", "stats", "--period", "week" };
    try std.testing.expectEqual(@as(u16, 7), (try Cli.parse(&week, .empty)).history.period_days);

    const invalid = [_][*:0]const u8{ "telar", "history", "stats", "--period", "decade" };
    try std.testing.expectError(error.InvalidHistoryPeriod, Cli.parse(&invalid, .empty));

    const misplaced = [_][*:0]const u8{ "telar", "history", "list", "--period", "week" };
    try std.testing.expectError(error.UnknownHistoryOption, Cli.parse(&misplaced, .empty));
}
