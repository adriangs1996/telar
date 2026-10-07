//! CLI command selection; each grammar owns its options and validation.

const RepositoryOptions = @import("arguments/RepositoryOptions.zig");
const FileOptions = @import("arguments/FileOptions.zig");
const ProjectOptions = @import("arguments/ProjectOptions.zig");
const ExecOptions = @import("arguments/ExecOptions.zig");
const DiagnosticsOptions = @import("arguments/DiagnosticsOptions.zig");
const ServerOptions = @import("arguments/ServerOptions.zig");
const RuntimeOptions = @import("arguments/RuntimeOptions.zig");
const RoutedOptions = @import("arguments/RoutedOptions.zig");
const ClientOptions = @import("arguments/ClientOptions.zig");
const SuggestionOptions = @import("arguments/SuggestionOptions.zig");
const TabOptions = @import("arguments/TabOptions.zig");
const HistoryOptions = @import("arguments/HistoryOptions.zig");
const NotificationOptions = @import("arguments/NotificationOptions.zig");
const ConfigCheckOptions = @import("arguments/ConfigCheckOptions.zig");
const PluginWorkerOptions = @import("arguments/PluginWorkerOptions.zig");
const TapWorkerOptions = @import("arguments/TapWorkerOptions.zig");
const PluginOptions = @import("arguments/PluginOptions.zig");
const AgentOptions = @import("arguments/AgentOptions.zig");
const PaneOptions = @import("arguments/PaneOptions.zig");
const WorkspaceOptions = @import("arguments/WorkspaceOptions.zig");
const WorktreeOptions = @import("arguments/WorktreeOptions.zig");
const skill_module = @import("skill.zig");
const help = @import("help.zig");
const HelpTopic = @import("HelpTopic.zig").HelpTopic;
const CommandFamily = @import("arguments/CommandFamily.zig").CommandFamily;
const ApiOptions = @import("arguments/ApiOptions.zig");
const HookOptions = @import("arguments/HookOptions.zig");
const IntegrationOptions = @import("arguments/IntegrationOptions.zig");
const ProxyOptions = @import("arguments/ProxyOptions.zig");
const RunOptions = @import("arguments/RunOptions.zig");
const GuiOptions = @import("arguments/GuiOptions.zig");
const CliOptions = @import("arguments/CliOptions.zig");
const MachineOptions = @import("arguments/MachineOptions.zig");
const MachineDispatchOptions = @import("arguments/MachineDispatchOptions.zig");
const std = @import("std");

pub const Cli = union(enum) {
    exec: ExecOptions,
    project: ProjectOptions,
    file: FileOptions,
    repository: RepositoryOptions,
    help: HelpTopic,
    version,
    server: ServerOptions,
    runtime: RuntimeOptions,
    diagnostics: DiagnosticsOptions,
    tab: TabOptions,
    command: SuggestionOptions,
    client_control: ClientOptions,
    routed: RoutedOptions,
    history: HistoryOptions,
    notification: NotificationOptions,
    config_check: ConfigCheckOptions,
    plugin_worker: PluginWorkerOptions,
    tap_worker: TapWorkerOptions,
    plugin: PluginOptions,
    agent: AgentOptions,
    pane: PaneOptions,
    workspace: WorkspaceOptions,
    api: ApiOptions,
    hook: HookOptions,
    worktree: WorktreeOptions,
    integration: IntegrationOptions,
    proxy: ProxyOptions,
    skill: skill_module.Skill,
    run: RunOptions,
    gui: GuiOptions,
    cli: CliOptions,
    machine: MachineOptions,
    /// `telar --machine LABEL COMMAND…`.
    machine_dispatch: MachineDispatchOptions,
    /// The encoded words `--machine` sends to the other machine.
    dispatch_argv: []const [*:0]const u8,

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
            return .{ .run = try RunOptions.parse(&.{}, environ) };
        }

        if (help.find(args[1..])) |topic| {
            return .{ .help = topic };
        }

        if (try MachineDispatchOptions.parse(args)) |options| {
            return .{ .machine_dispatch = options };
        }

        if (try RoutedOptions.parse(args[1..])) |options| {
            return .{ .routed = options };
        }

        const first = std.mem.span(args[1]);
        if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
            return .version;
        }
        if (std.mem.eql(u8, first, "--skill")) {
            if (args.len > 2) {
                const which = std.meta.stringToEnum(skill_module.Skill, std.mem.span(args[2])) orelse return error.UnknownSkill;
                return .{ .skill = which };
            }

            return .{ .skill = .telar };
        }

        // Entry points telar runs for itself; no family lists them.
        if (std.mem.eql(u8, first, "plugin-worker")) {
            return .{ .plugin_worker = try PluginWorkerOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "tap-worker")) {
            return .{ .tap_worker = try TapWorkerOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "dispatch-argv")) {
            return .{ .dispatch_argv = args[2..] };
        }

        const family = CommandFamily.parse(first) orelse return .{ .run = try RunOptions.parse(args[1..], environ) };
        const rest = args[2..];
        return switch (family) {
            .repository => .{ .repository = try RepositoryOptions.parse(rest) },
            .file => .{ .file = try FileOptions.parse(rest) },
            .project => .{ .project = try ProjectOptions.parse(rest) },
            .exec => .{ .exec = try ExecOptions.parse(rest) },
            .client => .{ .client_control = try ClientOptions.parse(rest) },
            .command => .{ .command = try SuggestionOptions.parse(rest) },
            .tab => .{ .tab = try TabOptions.parse(rest) },
            .diagnostics => .{ .diagnostics = try DiagnosticsOptions.parse(rest) },
            .runtime => .{ .runtime = try RuntimeOptions.parse(rest) },
            .agent => .{ .agent = try AgentOptions.parse(rest) },
            .pane => .{ .pane = try PaneOptions.parse(rest) },
            .workspace => .{ .workspace = try WorkspaceOptions.parse(rest) },
            .worktree => .{ .worktree = try WorktreeOptions.parse(rest) },
            .api => .{ .api = try ApiOptions.parse(rest) },
            .hook => .{ .hook = try HookOptions.parse(rest) },
            .integration => .{ .integration = try IntegrationOptions.parse(rest) },
            .proxy => try parseProxy(rest),
            .server => .{ .server = try ServerOptions.parse(rest) },
            .history => .{ .history = try HistoryOptions.parse(rest) },
            .notification => .{ .notification = try NotificationOptions.parse(rest) },
            .config => .{ .config_check = try ConfigCheckOptions.parse(rest) },
            .plugin => .{ .plugin = try PluginOptions.parse(rest) },
            .gui => .{ .gui = try GuiOptions.parse(rest, environ) },
            .cli => .{ .cli = try CliOptions.parse(rest) },
            .machine => .{ .machine = try MachineOptions.parse(rest) },
            // Every command of these families goes through a window, and the
            // routed grammar above took the ones it knows.
            .sidebar, .workspace_list, .layout => if (rest.len == 0) error.MissingClientAction else error.UnknownClientAction,
        };
    }

    // `proxy watch` is a runtime subscription; the rest of the family is trust.
    fn parseProxy(rest: []const [*:0]const u8) !Cli {
        if (rest.len > 0 and std.mem.eql(u8, std.mem.span(rest[0]), "watch")) {
            var options = try RuntimeOptions.parse(rest);
            options.proxy_only = true;
            return .{ .runtime = options };
        }

        return .{ .proxy = try ProxyOptions.parse(rest) };
    }
};
