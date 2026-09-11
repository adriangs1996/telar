//! CLI command selection; each grammar owns its options and validation.

const ServerOptions = @import("arguments/ServerOptions.zig");
const HistoryOptions = @import("arguments/HistoryOptions.zig");
const NotificationOptions = @import("arguments/NotificationOptions.zig");
const ConfigCheckOptions = @import("arguments/ConfigCheckOptions.zig");
const PluginWorkerOptions = @import("arguments/PluginWorkerOptions.zig");
const TapWorkerOptions = @import("arguments/TapWorkerOptions.zig");
const PluginOptions = @import("arguments/PluginOptions.zig");
const AgentOptions = @import("arguments/AgentOptions.zig");
const PaneOptions = @import("arguments/PaneOptions.zig");
const WorkspaceOptions = @import("arguments/WorkspaceOptions.zig");
const ApiOptions = @import("arguments/ApiOptions.zig");
const HookOptions = @import("arguments/HookOptions.zig");
const IntegrationOptions = @import("arguments/IntegrationOptions.zig");
const ProxyOptions = @import("arguments/ProxyOptions.zig");
const RunOptions = @import("arguments/RunOptions.zig");
const std = @import("std");
const BuiltinType = @import("telar-frontend").Builtin;
const SidebarRenderingType = @import("telar-frontend").SidebarRendering;
const server_module = @import("arguments/server.zig");
const plugin_module = @import("arguments/plugin.zig");
const CapabilityType = @import("telar-core").Capability;
const history_module = @import("arguments/history.zig");
const HistoryScopeType = @import("telar-core").HistoryScope;
const NotificationLevelType = @import("telar-core").NotificationLevel;
const PaneIdType = @import("telar-core").PaneId;
const agent_module = @import("arguments/agent.zig");
const AgentStatusType = @import("telar-core").AgentStatus;
const PaneTextSourceType = @import("telar-core").PaneTextSource;
const pane_module = @import("arguments/pane.zig");
const PaneDirectionType = @import("telar-core").PaneDirection;
const values_module = @import("arguments/values.zig");
const integration_module = @import("arguments/integration.zig");
const proxy_module = @import("arguments/proxy.zig");
const HistoryAuthorFilterType = @import("telar-core").HistoryAuthorFilter;

pub const Cli = union(enum) {
    help,
    version,
    server: ServerOptions,
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
    integration: IntegrationOptions,
    proxy: ProxyOptions,
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
            return .{ .run = try RunOptions.parse(&.{}, environ) };
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
        if (std.mem.eql(u8, first, "proxy")) {
            return .{ .proxy = try ProxyOptions.parse(args[2..]) };
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
            return .{ .config_check = try ConfigCheckOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "plugin-worker")) {
            return .{ .plugin_worker = try PluginWorkerOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "tap-worker")) {
            return .{ .tap_worker = try TapWorkerOptions.parse(args[2..]) };
        }
        if (std.mem.eql(u8, first, "plugin")) {
            return .{ .plugin = try PluginOptions.parse(args[2..]) };
        }
        return .{ .run = try RunOptions.parse(args[1..], environ) };
    }
};

test "CLI defaults to the configured shell" {
    const args = [_][*:0]const u8{"telar"};
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .run);
    try std.testing.expect(cli.run.command.argv[0] != null);
    try std.testing.expectEqual(BuiltinType.vesper, cli.run.theme.base);
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
    try std.testing.expectEqual(BuiltinType.catppuccin, cli.run.theme.base);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(cli.run.command.file));
}

test "CLI runs the default shell when only a theme is provided" {
    const args = [_][*:0]const u8{ "telar", "--theme", "tokyonight" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expectEqual(BuiltinType.tokyo_night, cli.run.theme.base);
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
    try std.testing.expectEqual(SidebarRenderingType.kitty_hybrid, cli.run.sidebar_rendering);

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

test "CLI parses --fresh for the client and the server and rejects it elsewhere" {
    const client = [_][*:0]const u8{ "telar", "--fresh", "--no-config" };
    const parsed_client = try Cli.parse(&client, .empty);
    try std.testing.expect(parsed_client.run.fresh);
    try std.testing.expect(parsed_client.run.no_config);

    const twice = [_][*:0]const u8{ "telar", "--fresh", "--fresh" };
    try std.testing.expectError(error.DuplicateFreshOption, Cli.parse(&twice, .empty));

    const remote = [_][*:0]const u8{ "telar", "--remote=host", "--fresh" };
    try std.testing.expectError(error.FreshWithRemote, Cli.parse(&remote, .empty));

    const server = [_][*:0]const u8{ "telar", "server", "--background", "--fresh" };
    const parsed_server = try Cli.parse(&server, .empty);
    try std.testing.expect(parsed_server.server.fresh);
    try std.testing.expectEqual(server_module.ServerMode.background_launcher, parsed_server.server.mode);

    const stop = [_][*:0]const u8{ "telar", "server", "stop", "--fresh" };
    try std.testing.expectError(error.FreshRequiresRun, Cli.parse(&stop, .empty));
}

test "CLI keeps plugin inspection installation and trust separate" {
    const install = [_][*:0]const u8{ "telar", "plugin", "install", "./plugin" };
    const parsed_install = try Cli.parse(&install, .empty);
    try std.testing.expectEqual(plugin_module.PluginCommand.install, parsed_install.plugin.command);

    const trust = [_][*:0]const u8{
        "telar",
        "plugin",
        "trust",
        "./plugin",
        "--capability",
        "history.read",
    };
    const parsed_trust = try Cli.parse(&trust, .empty);
    try std.testing.expectEqual(plugin_module.PluginCommand.trust, parsed_trust.plugin.command);
    try std.testing.expectEqual(CapabilityType.history_read, parsed_trust.plugin.capabilities[0]);
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
    try std.testing.expectEqual(server_module.ServerAction.run, cli.server.action);
    try std.testing.expectEqual(server_module.ServerMode.foreground, cli.server.mode);
}

test "CLI recognizes runtime stop" {
    const args = [_][*:0]const u8{ "telar", "server", "stop" };
    const cli = try Cli.parse(&args, .empty);
    try std.testing.expect(cli == .server);
    try std.testing.expectEqual(server_module.ServerAction.stop, cli.server.action);
    try std.testing.expectEqual(server_module.ServerMode.foreground, cli.server.mode);
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
    try std.testing.expectEqual(server_module.ServerMode.background_launcher, cli.server.mode);
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
    try std.testing.expectEqual(history_module.HistoryAction.search, cli.history.action);
    try std.testing.expectEqualStrings("git commit", std.mem.span(cli.history.query.?));
    try std.testing.expectEqual(HistoryScopeType.workspace, cli.history.scope);
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
    try std.testing.expectEqual(NotificationLevelType.success, parsed.notification.level);
    try std.testing.expectEqual(@as(u32, 2500), parsed.notification.duration_ms);
    try std.testing.expectEqual(@as(PaneIdType, @enumFromInt(42)), parsed.notification.target.pane);
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
    try std.testing.expectEqual(agent_module.AgentAction.list, list_cli.agent.action);
    try std.testing.expect(list_cli.agent.json);
    try std.testing.expect(list_cli.agent.target == null);

    const wait = [_][*:0]const u8{ "telar", "agent", "wait", "7", "--until", "blocked", "--timeout", "90s" };
    const wait_cli = try Cli.parse(&wait, .empty);
    try std.testing.expectEqual(agent_module.AgentAction.wait, wait_cli.agent.action);
    try std.testing.expectEqual(@as(u64, 7), wait_cli.agent.target.?.pane);
    try std.testing.expectEqual(AgentStatusType.blocked, wait_cli.agent.until);
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
    try std.testing.expectEqual(PaneTextSourceType.screen, read_cli.agent.source);
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
    try std.testing.expectEqual(pane_module.PaneAction.read, read_cli.pane.action);
    try std.testing.expectEqual(@as(u64, 4), read_cli.pane.target.pane);
    try std.testing.expectEqual(@as(u16, 10), read_cli.pane.lines);

    const send = [_][*:0]const u8{ "telar", "pane", "send-keys", "--current", "y", "--enter" };
    const send_cli = try Cli.parse(&send, .empty);
    try std.testing.expectEqual(pane_module.PaneAction.send_keys, send_cli.pane.action);
    try std.testing.expect(send_cli.pane.target == .current);
    try std.testing.expectEqualStrings("y", std.mem.span(send_cli.pane.text.?));
    try std.testing.expect(send_cli.pane.enter);

    const focus = [_][*:0]const u8{ "telar", "pane", "focus", "--current", "--direction", "left", "--json" };
    const focus_cli = try Cli.parse(&focus, .empty);
    try std.testing.expectEqual(pane_module.PaneAction.focus, focus_cli.pane.action);
    try std.testing.expect(focus_cli.pane.target == .current);
    try std.testing.expectEqual(PaneDirectionType.left, focus_cli.pane.direction.?);
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
    try std.testing.expectEqual(agent_module.AgentAction.report_session, cli.agent.action);
    try std.testing.expect(cli.agent.target.? == .current);
    try std.testing.expectEqualStrings("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", std.mem.span(cli.agent.text.?));

    const missing = [_][*:0]const u8{ "telar", "agent", "report-session", "7" };
    try std.testing.expectError(error.MissingSessionReference, Cli.parse(&missing, .empty));
}

test "CLI parses hook and integration commands" {
    const hook = [_][*:0]const u8{ "telar", "hook", "claude" };
    try std.testing.expectEqual(values_module.HookAgent.claude, (try Cli.parse(&hook, .empty)).hook.agent);

    const codex_hook = [_][*:0]const u8{ "telar", "hook", "codex" };
    try std.testing.expectEqual(values_module.HookAgent.codex, (try Cli.parse(&codex_hook, .empty)).hook.agent);

    const install = [_][*:0]const u8{ "telar", "integration", "install", "claude", "--settings", "/tmp/s.json" };
    const cli = try Cli.parse(&install, .empty);
    try std.testing.expectEqual(integration_module.IntegrationAction.install, cli.integration.action);
    try std.testing.expectEqualStrings("/tmp/s.json", std.mem.span(cli.integration.settings.?));

    const codex_install = [_][*:0]const u8{ "telar", "integration", "install", "codex" };
    try std.testing.expectEqual(values_module.HookAgent.codex, (try Cli.parse(&codex_install, .empty)).integration.agent);

    const pi_hook = [_][*:0]const u8{ "telar", "hook", "pi", "--socket", "/tmp/s.sock" };
    const pi_cli = try Cli.parse(&pi_hook, .empty);
    try std.testing.expectEqual(values_module.HookAgent.pi, pi_cli.hook.agent);
    try std.testing.expectEqualStrings("/tmp/s.sock", std.mem.span(pi_cli.hook.socket.?));
    const pi_status = [_][*:0]const u8{ "telar", "integration", "status", "pi" };
    try std.testing.expectEqual(values_module.HookAgent.pi, (try Cli.parse(&pi_status, .empty)).integration.agent);

    const unknown = [_][*:0]const u8{ "telar", "integration", "install", "gemini" };
    try std.testing.expectError(error.UnknownHookAgent, Cli.parse(&unknown, .empty));
}

test "CLI parses explicit proxy trust actions and Linux backends" {
    const install = [_][*:0]const u8{ "telar", "proxy", "trust", "install", "--ca-dir", "/tmp/proxy", "--linux", "trust" };
    const parsed = (try Cli.parse(&install, .empty)).proxy;
    try std.testing.expectEqual(proxy_module.ProxyTrustAction.install, parsed.action);
    try std.testing.expectEqualStrings("/tmp/proxy", std.mem.span(parsed.ca_dir.?));
    try std.testing.expectEqual(proxy_module.LinuxTrustBackend.trust, parsed.linux_backend.?);

    const status = [_][*:0]const u8{ "telar", "proxy", "trust", "status" };
    try std.testing.expectEqual(proxy_module.ProxyTrustAction.status, (try Cli.parse(&status, .empty)).proxy.action);

    const implicit = [_][*:0]const u8{ "telar", "proxy", "trust" };
    try std.testing.expectError(error.MissingProxyTrustAction, Cli.parse(&implicit, .empty));
    const invalid = [_][*:0]const u8{ "telar", "proxy", "trust", "install", "--linux", "automatic" };
    try std.testing.expectError(error.InvalidLinuxTrustBackend, Cli.parse(&invalid, .empty));
}

test "CLI parses the remote destination and the server endpoint action" {
    const remote = [_][*:0]const u8{ "telar", "--remote", "dev@build-box", "/bin/zsh" };
    const cli = try Cli.parse(&remote, .empty);
    try std.testing.expectEqualStrings("dev@build-box", std.mem.span(cli.run.remote.?));
    try std.testing.expectEqualStrings("/bin/zsh", std.mem.span(cli.run.command.file));

    const endpoint = [_][*:0]const u8{ "telar", "server", "endpoint" };
    try std.testing.expectEqual(server_module.ServerAction.endpoint, (try Cli.parse(&endpoint, .empty)).server.action);
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
    try std.testing.expectEqual(HistoryAuthorFilterType.agent, cli.history.author);

    const invalid = [_][*:0]const u8{ "telar", "history", "list", "--author", "robot" };
    try std.testing.expectError(error.InvalidHistoryAuthor, Cli.parse(&invalid, .empty));
}

test "history import parses kinds and the file option" {
    const explicit = [_][*:0]const u8{ "telar", "history", "import", "fish", "--file", "/tmp/h" };
    const cli = try Cli.parse(&explicit, .empty);
    try std.testing.expectEqual(history_module.HistoryImportKind.fish, cli.history.import_kind);
    try std.testing.expectEqualStrings("/tmp/h", std.mem.span(cli.history.import_file.?));

    const auto = [_][*:0]const u8{ "telar", "history", "import" };
    try std.testing.expectEqual(history_module.HistoryImportKind.auto, (try Cli.parse(&auto, .empty)).history.import_kind);

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

test "CLI parses the internal tap worker and rejects extra arguments" {
    const valid = [_][*:0]const u8{ "telar", "tap-worker", "/tmp/package/main.lua" };
    const parsed = try Cli.parse(&valid, .empty);
    try std.testing.expectEqualStrings("/tmp/package/main.lua", std.mem.span(parsed.tap_worker.entry));

    const missing = [_][*:0]const u8{ "telar", "tap-worker" };
    try std.testing.expectError(error.InvalidTapWorkerArguments, Cli.parse(&missing, .empty));

    const extra = [_][*:0]const u8{ "telar", "tap-worker", "/tmp/main.lua", "extra" };
    try std.testing.expectError(error.InvalidTapWorkerArguments, Cli.parse(&extra, .empty));
}
