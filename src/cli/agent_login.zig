//! The login step of `telar machine setup` (docs/flows/machine-setup.md):
//! each agent gets its own login on the machine, through its official flow,
//! so no credential ever travels. The login runs in a workspace of the
//! machine's runtime; setup reads its link from that pane and shows it in
//! this machine's window as a notification that opens it on click. A code
//! the agent wants pasted back is asked for in setup's terminal and typed
//! into that pane. The agent's own status command decides when it is done.
//! The link, a device code and pasted text are shown, never stored.
const core = @import("telar-core");
const client = @import("telar-client");
const std = @import("std");
const MachinePlatform = @import("MachinePlatform.zig");
const SetupReport = @import("SetupReport.zig");
const config_filter = @import("config_filter.zig");
const config_allowlist = @import("config_allowlist.zig");
const machine_dispatch = @import("machine_dispatch.zig");
const notification = @import("notification.zig");
const remote_shell = @import("remote_shell.zig");
const LoginRequest = @import("LoginRequest.zig");

const Agent = MachinePlatform.Agent;
const AgentLogin = core.AgentLogin;

/// The login pane's width: wider than any login URL, so `pane read` returns
/// it on one line.
const login_columns = "1024";
/// How long setup waits for a login link, and for the person to finish.
const link_wait_ms = 60 * std.time.ms_per_s;
/// Codex's device code expires in 15 minutes (codex-rs/login/src/device_code_auth.rs).
const finish_wait_ms = 15 * std.time.ms_per_min;
const poll_ms = 500;
const status_poll_ms = 3 * std.time.ms_per_s;
const status_timeout_s = 30;
/// How long the notification stays, in milliseconds (the wire's maximum).
const notification_ms = core.max_notification_duration_ms;
/// Rows of the login pane read at a time.
const read_lines = "80";
/// Bytes kept of a local configuration file read for a provider name.
const max_settings_bytes = 256 * 1024;

/// How one agent logs in without a browser on the machine, from its
/// official documentation or source (docs/plans/machine-setup.md).
const LoginPlan = struct {
    title: []const u8,
    /// Words after the agent's path; empty runs the agent itself.
    arguments: []const []const u8,
    /// An environment assignment the login runs with.
    environment: ?[]const u8 = null,
    /// Keys typed into the pane once it runs, for a TUI-only login.
    keys: ?[]const u8 = null,
    /// Whether the login prints a link to open.
    link: bool = true,
    /// The only hosts a link from this login may name, from the agent's
    /// source or shipped bundle (docs/plans/machine-setup.md, Agent facts).
    /// Any other link in the pane, or one with user info, is never shown.
    hosts: []const []const u8 = &.{},
    /// Text before the one-time code a device login prints.
    code_marker: ?[]const u8 = null,
    /// What the person pastes back into the pane, when the login asks.
    paste: ?[]const u8 = null,
    /// What the person does in the browser.
    instructions: []const u8,
};

/// What exits 0 once the agent is logged in there; it runs with `agent`
/// and `provider` set. Sources as for `planFor`; Cursor's `status` exits 0
/// either way, so its JSON is read.
fn statusScript(agent: Agent) []const u8 {
    return switch (agent) {
        .claude => "\"$agent\" auth status >/dev/null 2>&1",
        .codex => "\"$agent\" login status >/dev/null 2>&1",
        .cursor => "\"$agent\" status --format json 2>/dev/null | grep -Eq '\"status\": *\"authenticated\"|\"isAuthenticated\": *true'",
        .pi => "[ -n \"$provider\" ] && \"$agent\" auth check --provider \"$provider\" --no-refresh >/dev/null 2>&1",
        .opencode => "[ -n \"$provider\" ] && \"$agent\" auth list 2>/dev/null | grep -qi -- \"$provider\"",
    };
}

fn planFor(agent: Agent, provider: ?[]const u8) ?LoginPlan {
    return switch (agent) {
        // https://code.claude.com/docs/en/troubleshoot-install: `claude auth
        // login` prints the URL and reads the pasted code from stdin;
        // `claude auth status` exits 0 when logged in (cli-reference).
        // Hosts: CLAUDE_AI_AUTHORIZE_URL (claude.com), CONSOLE_AUTHORIZE_URL
        // (platform.claude.com) in the 2.1.284 binary; claude.ai as Pi and
        // older releases use it.
        .claude => .{
            .title = "Log in to Claude Code",
            .arguments = &.{ "auth", "login" },
            .hosts = &.{ "claude.com", "claude.ai", "platform.claude.com" },
            .paste = "the code the browser shows",
            .instructions = "open the page, sign in, and paste the code it shows into this terminal",
        },
        // https://learn.chatgpt.com/docs/auth.md; device login must be on in
        // ChatGPT's security settings. `codex login status` exits 0 when
        // logged in (codex-rs/cli/src/login.rs).
        // Host: DEFAULT_ISSUER in codex-rs/login/src/server.rs, and the
        // device page `{issuer}/codex/device` (device_code_auth.rs).
        .codex => .{
            .title = "Log in to Codex",
            .arguments = &.{ "login", "--device-auth" },
            .hosts = &.{"auth.openai.com"},
            .code_marker = "one-time code",
            .instructions = "open the page, sign in and enter the code",
        },
        // https://cursor.com/docs/cli/reference/authentication.md: the URL
        // is printed and the CLI polls (Linux package 2026.09.26-dd393fe).
        // Host: `new URL("/loginDeepControl", "https://cursor.com")` in the
        // bundle's index.js.
        .cursor => .{
            .title = "Log in to Cursor Agent",
            .arguments = &.{"login"},
            .hosts = &.{"cursor.com"},
            .environment = "NO_OPEN_BROWSER=1",
            .instructions = "open the page and sign in",
        },
        // Pi logs in only through `/login` in its TUI (docs/cli.md); the
        // person picks the provider in the pane. `pi auth check` exits 0
        // when ready (docs/cli.md).
        .pi => if (provider == null) null else .{
            .title = "Log in to Pi",
            .arguments = &.{},
            .keys = "/login",
            .link = false,
            .instructions = "choose the provider in the Pi pane there",
        },
        // OpenCode's OpenAI plugin has a device login (source:
        // packages/opencode/src/plugin/openai/codex.ts); Anthropic takes
        // only an API key, which setup never handles.
        .opencode => if (provider == null or !std.mem.eql(u8, provider.?, "openai")) null else .{
            .title = "Log in to OpenCode",
            .arguments = &.{ "auth", "login", "-p", "openai", "-m", "ChatGPT Pro/Plus (headless)" },
            // Host: ISSUER in packages/opencode/src/plugin/openai/codex.ts.
            .hosts = &.{"auth.openai.com"},
            .code_marker = "Enter code:",
            .instructions = "open the page, sign in and enter the code",
        },
    };
}

/// Logs each wanted agent the machine has into its own account there and
/// records how each login stood in the profile.
///
/// ```zig
/// try agent_login.run(process_init, &report, &profile, &platform, .{ .wanted = wanted, .interactive = true, .profiles_path = path });
/// ```
pub fn run(init: std.process.Init, report: *SetupReport, profile: *const core.MachineProfile, platform: *const MachinePlatform, request: LoginRequest) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var logins: std.EnumArray(Agent, ?AgentLogin) = .initFill(null);
    var started = false;
    var iterator = request.wanted.iterator();
    while (iterator.next()) |agent| {
        const path = if (platform.agents.get(agent)) |*value| value.slice() else continue;
        const provider = try localProvider(arena, init.io, init.minimal.environ, agent);
        const logged_in = loggedIn(init, profile.destination(), agent, path, provider) catch |err| {
            try report.note(.logins, "{s}: its login status could not be read there: {s}", .{ @tagName(agent), @errorName(err) });
            logins.set(agent, .failed);
            continue;
        };

        if (logged_in) {
            logins.set(agent, .done);
            try report.note(.logins, "{s}: logged in", .{@tagName(agent)});
            // A login a person finished after an earlier setup left its
            // pane open: it has nothing more to show.
            if (planFor(agent, provider)) |plan| {
                closeLeftover(init, arena, profile, agent, plan.title);
            }

            continue;
        }

        const plan = planFor(agent, provider) orelse {
            try report.note(.logins, "{s}: log in there yourself; setup has no browser login for {s}", .{ @tagName(agent), provider orelse "its provider" });
            continue;
        };

        started = true;
        const login = login: {
            break :login loginOne(init, report, .{
                .profile = profile,
                .home = platform.home.slice(),
                .agent = agent,
                .path = path,
                .plan = plan,
                .provider = provider,
            }, request.interactive) catch |err| {
                try report.note(.logins, "{s}: {s}", .{ @tagName(agent), @errorName(err) });
                break :login AgentLogin.failed;
            };
        };
        logins.set(agent, login);
        try report.note(.logins, "{s}: {s}", .{ @tagName(agent), @tagName(login) });
    }

    record(init, profile.label(), request.profiles_path, logins) catch |err| {
        try report.note(.logins, "machines.json keeps the logins it had: {s}", .{client.machine_profiles.describe(err)});
    };

    const status = aggregate(logins, started);
    try report.end(.logins, status, "{s}", .{switch (status) {
        .ok => "every agent there is logged in",
        .changed => "every started login finished",
        .pending => "a login waits for you; run setup again to see it done",
        .failed => "a login failed; see the notes",
        .skipped => "no agent there to log in",
    }});
}

/// One login under way.
const Login = struct {
    profile: *const core.MachineProfile,
    /// The machine's home, where the login pane starts.
    home: []const u8,
    agent: Agent,
    path: []const u8,
    plan: LoginPlan,
    provider: ?[]const u8,
};

fn aggregate(logins: std.EnumArray(Agent, ?AgentLogin), started: bool) SetupReport.Status {
    var any = false;
    var pending = false;
    for (std.enums.values(Agent)) |agent| {
        const login = logins.get(agent) orelse continue;
        any = true;
        switch (login) {
            .failed => return .failed,
            .pending => pending = true,
            .done => {},
        }
    }

    if (!any) {
        return .skipped;
    }

    if (pending) {
        return .pending;
    }

    return if (started) .changed else .ok;
}

fn loginOne(init: std.process.Init, report: *SetupReport, login: Login, interactive: bool) !AgentLogin {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A login an earlier setup left waiting keeps its pane: its link and
    // code still stand, and a second login would only race it.
    const existing = findLoginPane(init, arena, login.profile, login.agent, login.plan.title) catch null;
    const pane = existing orelse try openLoginPane(init, arena, login);
    errdefer closeLoginPane(init, arena, login.profile, login.agent, pane) catch {};
    if (existing != null) {
        try report.progress("{s} on {s}: the login setup started before is still open there", .{ login.plan.title, login.profile.label() });
    } else if (login.plan.keys) |keys| {
        try sendText(init, arena, login.profile, pane, keys);
    }

    if (login.plan.link) {
        const found = try waitForLink(init, arena, login, pane) orelse {
            try report.progress("{s}: no login link appeared in its pane on {s}; finish it there", .{ @tagName(login.agent), login.profile.label() });
            return .pending;
        };

        try report.progress("{s} on {s}: {s}", .{ login.plan.title, login.profile.label(), found.url });
        if (found.code) |code| {
            try report.progress("one-time code: {s}", .{code});
        }

        if (!try announce(init, arena, login, found)) {
            try report.progress("no window here took the notification; open the link above", .{});
        }
    } else {
        _ = try announce(init, arena, login, .{ .url = "" });
        try report.progress("{s} on {s}: {s}", .{ login.plan.title, login.profile.label(), login.plan.instructions });
    }

    // Without a terminal nobody can paste or wait here: the login stays open
    // there, and the next setup sees it done or shows it again.
    if (!interactive) {
        return .pending;
    }

    if (login.plan.paste != null) {
        try pasteBack(init, arena, report, login, pane);
    }

    const outcome = try waitForLogin(init, login);
    closeLoginPane(init, arena, login.profile, login.agent, pane) catch |err| {
        try report.note(.logins, "{s}: its login pane there stays open: {s}", .{ @tagName(login.agent), @errorName(err) });
    };

    return outcome;
}

/// Where one login runs on the machine.
const LoginPane = struct {
    workspace_id: u64,
    tab_id: u64,
    pane_id: u64,
};

// Starts the login in its own workspace there and returns its pane.
fn openLoginPane(init: std.process.Init, arena: std.mem.Allocator, login: Login) !LoginPane {
    var words: std.ArrayList([*:0]const u8) = .empty;
    for ([_][]const u8{ "telar", "workspace", "create", "--directory" }) |word| {
        try words.append(arena, try arena.dupeZ(u8, word));
    }

    try words.append(arena, try arena.dupeZ(u8, login.home));
    for ([_][]const u8{ "--name", login.plan.title, "--columns", login_columns, "--json", "--" }) |word| {
        try words.append(arena, try arena.dupeZ(u8, word));
    }

    if (login.plan.environment) |assignment| {
        try words.append(arena, "/usr/bin/env");
        try words.append(arena, try arena.dupeZ(u8, assignment));
    }

    try words.append(arena, try arena.dupeZ(u8, login.path));
    for (login.plan.arguments) |word| {
        try words.append(arena, try arena.dupeZ(u8, word));
    }

    const output = try machine_dispatch.capture(init, login.profile, words.items);
    defer init.gpa.free(output);

    const pane = std.json.parseFromSliceLeaky(LoginPane, arena, output, .{ .ignore_unknown_fields = true }) catch return error.LoginPaneUnreadable;
    errdefer closeTab(init, arena, login.profile, pane) catch {};
    try rememberLoginPane(init, login.profile.destination(), login.agent, pane);
    return pane;
}

/// Where setup notes, on the machine, which pane each login it opened runs
/// in: a file per agent holding `WORKSPACE TAB PANE`. Only setup writes it,
/// so a workspace a person named "Log in to Codex" is never taken for a
/// login, nor closed.
const login_records = "$HOME/.local/state/telar/setup-logins";

fn rememberLoginPane(init: std.process.Init, destination: []const u8, agent: Agent, pane: LoginPane) !void {
    var script_buffer: [512]u8 = undefined;
    var script: std.Io.Writer = .fixed(&script_buffer);
    try script.print("umask 077 && mkdir -p \"{s}\" && printf '%s\\n' '{d} {d} {d}' > \"{s}/{s}\"\n", .{
        login_records,
        pane.workspace_id,
        pane.tab_id,
        pane.pane_id,
        login_records,
        @tagName(agent),
    });
    try runRecordScript(init, destination, script.buffered());
}

fn forgetLoginPane(init: std.process.Init, destination: []const u8, agent: Agent) !void {
    var script_buffer: [256]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buffer, "rm -f \"{s}/{s}\"\n", .{ login_records, @tagName(agent) });
    try runRecordScript(init, destination, script);
}

fn recordedLoginPane(init: std.process.Init, destination: []const u8, agent: Agent) !?LoginPane {
    var script_buffer: [256]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buffer, "cat \"{s}/{s}\" 2>/dev/null || true\n", .{ login_records, @tagName(agent) });
    var result = try remote_shell.runScript(init, destination, script, status_timeout_s);
    defer result.deinit(init.gpa);
    if (!result.succeeded()) {
        return error.LoginRecordUnreadable;
    }

    return parseRecord(result.stdout);
}

fn runRecordScript(init: std.process.Init, destination: []const u8, script: []const u8) !void {
    var result = try remote_shell.runScript(init, destination, script, status_timeout_s);
    defer result.deinit(init.gpa);
    if (!result.succeeded()) {
        return error.LoginRecordUnwritable;
    }
}

// `WORKSPACE TAB PANE` as `rememberLoginPane` wrote it; null for anything
// else.
fn parseRecord(text: []const u8) ?LoginPane {
    var words = std.mem.tokenizeAny(u8, text, " \n");
    const workspace = std.fmt.parseUnsigned(u64, words.next() orelse return null, 10) catch return null;
    const tab = std.fmt.parseUnsigned(u64, words.next() orelse return null, 10) catch return null;
    const pane = std.fmt.parseUnsigned(u64, words.next() orelse return null, 10) catch return null;
    if (words.next() != null) {
        return null;
    }

    return .{
        .workspace_id = workspace,
        .tab_id = tab,
        .pane_id = pane,
    };
}

const ListedWorkspace = struct { workspace_id: u64, name: []const u8 };

// Whether the recorded pane still runs there, in a workspace named for the
// login: a runtime that restarted may have given its ids to other panes.
fn claimed(noted: LoginPane, title: []const u8, workspaces: []const ListedWorkspace, panes: []const LoginPane) bool {
    const named = for (workspaces) |workspace| {
        if (workspace.workspace_id == noted.workspace_id) {
            break std.mem.eql(u8, workspace.name, title);
        }
    } else false;

    if (!named) {
        return false;
    }

    for (panes) |pane| {
        if (std.meta.eql(pane, noted)) {
            return true;
        }
    }

    return false;
}

// The pane of a login an earlier setup opened there and nobody finished:
// the one its record names, still in its workspace named `title`. A record
// that no longer matches is dropped.
fn findLoginPane(init: std.process.Init, arena: std.mem.Allocator, profile: *const core.MachineProfile, agent: Agent, title: []const u8) !?LoginPane {
    const noted = try recordedLoginPane(init, profile.destination(), agent) orelse return null;
    const listed = try machine_dispatch.capture(init, profile, &.{ "telar", "workspace", "list", "--json" });
    defer init.gpa.free(listed);
    const workspaces = try std.json.parseFromSliceLeaky([]const ListedWorkspace, arena, listed, .{ .ignore_unknown_fields = true });

    const id = try std.fmt.allocPrintSentinel(arena, "{d}", .{noted.workspace_id}, 0);
    // A workspace that is gone has no panes to list.
    const panes_output = machine_dispatch.capture(init, profile, &.{ "telar", "pane", "list", "--workspace", id, "--json" }) catch null;
    defer if (panes_output) |output| init.gpa.free(output);
    const panes = try std.json.parseFromSliceLeaky([]const LoginPane, arena, panes_output orelse "[]", .{ .ignore_unknown_fields = true });
    if (claimed(noted, title, workspaces, panes)) {
        return noted;
    }

    try forgetLoginPane(init, profile.destination(), agent);
    return null;
}

// Closes the login's tab there, and with it its workspace, and its record.
fn closeLoginPane(init: std.process.Init, arena: std.mem.Allocator, profile: *const core.MachineProfile, agent: Agent, pane: LoginPane) !void {
    try closeTab(init, arena, profile, pane);
    try forgetLoginPane(init, profile.destination(), agent);
}

fn closeTab(init: std.process.Init, arena: std.mem.Allocator, profile: *const core.MachineProfile, pane: LoginPane) !void {
    const words = [_][*:0]const u8{
        "telar",
        "tab",
        "close",
        try std.fmt.allocPrintSentinel(arena, "{d}", .{pane.tab_id}, 0),
        "--workspace",
        try std.fmt.allocPrintSentinel(arena, "{d}", .{pane.workspace_id}, 0),
        "--json",
    };
    const output = try machine_dispatch.capture(init, profile, &words);
    init.gpa.free(output);
}

// Closes a login pane that outlived its login, if there is one; a failure
// leaves it for the person.
fn closeLeftover(init: std.process.Init, arena: std.mem.Allocator, profile: *const core.MachineProfile, agent: Agent, title: []const u8) void {
    const pane = (findLoginPane(init, arena, profile, agent, title) catch return) orelse return;
    closeLoginPane(init, arena, profile, agent, pane) catch {};
}

const FoundLink = struct {
    url: []const u8,
    code: ?[]const u8 = null,
};

fn waitForLink(init: std.process.Init, arena: std.mem.Allocator, login: Login, pane: LoginPane) !?FoundLink {
    var waited: u64 = 0;
    while (waited < link_wait_ms) : (waited += poll_ms) {
        const text = try readPane(init, arena, login.profile, pane);
        if (findLink(text, login.plan.hosts, login.plan.code_marker)) |found| {
            if (login.plan.code_marker == null or found.code != null) {
                return found;
            }
        }

        try init.io.sleep(.fromMilliseconds(poll_ms), .awake);
    }

    return null;
}

fn readPane(init: std.process.Init, arena: std.mem.Allocator, profile: *const core.MachineProfile, pane: LoginPane) ![]const u8 {
    const words = [_][*:0]const u8{ "telar", "pane", "read", try std.fmt.allocPrintSentinel(arena, "{d}", .{pane.pane_id}, 0), "--lines", read_lines };
    const output = try machine_dispatch.capture(init, profile, &words);
    defer init.gpa.free(output);
    return arena.dupe(u8, output);
}

/// The first https URL a login printed whose host is one of `hosts` and
/// which a notification may carry (no user info, a plain host), and, when
/// `code_marker` is given, the one-time code after it: on the marker's
/// line, or first on the next line that has text. Any other URL in the pane,
/// printed there by whatever runs in it, is passed over.
///
/// ```zig
/// const found = findLink(pane_text, &.{"auth.openai.com"}, "one-time code").?;
/// ```
fn findLink(text: []const u8, hosts: []const []const u8, code_marker: ?[]const u8) ?FoundLink {
    var from: usize = 0;
    const url = while (std.mem.indexOfPos(u8, text, from, "https://")) |start| {
        from = start + 1;
        const candidate = urlAt(text, start);
        core.notification_link.validate(candidate) catch continue;
        if (allowedHost(core.notification_link.host(candidate), hosts)) {
            break candidate;
        }
    } else return null;

    var found: FoundLink = .{ .url = url };
    const marker = code_marker orelse return found;
    const at = std.mem.indexOf(u8, text, marker) orelse return found;
    var lines = std.mem.splitScalar(u8, text[at + marker.len ..], '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const word = words.next() orelse continue;
        if (word[0] == '(') {
            continue;
        }

        found.code = word;
        return found;
    }

    return found;
}

// The URL that starts at `start`, without the punctuation that ends a
// sentence around it.
fn urlAt(text: []const u8, start: usize) []const u8 {
    var end = start;
    while (end < text.len and text[end] > ' ' and text[end] < 0x7f and text[end] != '"' and text[end] != '\'' and text[end] != '<' and text[end] != '>' and text[end] != '`') {
        end += 1;
    }

    var url = text[start..end];
    while (url.len > "https://".len and std.mem.indexOfScalar(u8, ".,;:)]}", url[url.len - 1]) != null) {
        url = url[0 .. url.len - 1];
    }

    return url;
}

fn allowedHost(host: []const u8, hosts: []const []const u8) bool {
    for (hosts) |allowed| {
        if (std.ascii.eqlIgnoreCase(host, allowed)) {
            return true;
        }
    }

    return false;
}

// Shows the login in this machine's window, where one click opens the
// link; false when no window took it.
fn announce(init: std.process.Init, arena: std.mem.Allocator, login: Login, found: FoundLink) !bool {
    var body = if (found.code) |code|
        try std.fmt.allocPrint(arena, "on {s}: {s}. Code: {s}", .{ login.profile.label(), login.plan.instructions, code })
    else
        try std.fmt.allocPrint(arena, "on {s}: {s}", .{ login.profile.label(), login.plan.instructions });

    // A body the notification cannot hold keeps its start, so the code the
    // login needs moves to the front.
    if (body.len > core.max_notification_message_bytes) {
        if (found.code) |code| {
            body = try std.fmt.allocPrint(arena, "Code: {s}, on {s}: {s}", .{ code, login.profile.label(), login.plan.instructions });
        }
    }

    notification.send(init, .{
        .level = .info,
        .duration_ms = notification_ms,
        .title = notification.fit(login.plan.title, core.max_notification_title_bytes),
        .message = notification.fit(body, core.max_notification_message_bytes),
        .link = found.url,
    }, null, null) catch return false;
    return true;
}

// Asks for what the login wants pasted and types it into the login pane.
// An empty answer leaves the pane for the person. The pasted text reaches
// the pane on standard input, never in a command line here or there.
fn pasteBack(init: std.process.Init, arena: std.mem.Allocator, report: *SetupReport, login: Login, pane: LoginPane) !void {
    try report.writer.print("Paste {s} for {s} (Enter to finish in the pane instead): ", .{ login.plan.paste.?, @tagName(login.agent) });
    try report.writer.flush();

    var line_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &line_buffer);
    const answer = stdin.interface.takeDelimiterExclusive('\n') catch return;
    const pasted = std.mem.trim(u8, answer, " \r\t");
    if (pasted.len == 0) {
        return;
    }

    try sendText(init, arena, login.profile, pane, pasted);
}

// Types `text` and Enter into the pane: a pasted code, or the keys a login
// needs to start (Pi's `/login`). The text travels on standard input.
fn sendText(init: std.process.Init, arena: std.mem.Allocator, profile: *const core.MachineProfile, pane: LoginPane, text: []const u8) !void {
    const words = [_][*:0]const u8{ "telar", "pane", "send-keys", try std.fmt.allocPrintSentinel(arena, "{d}", .{pane.pane_id}, 0), "--stdin", "--enter" };
    const output = try machine_dispatch.captureWithInput(init, profile, &words, text);
    init.gpa.free(output);
}

fn waitForLogin(init: std.process.Init, login: Login) !AgentLogin {
    var waited: u64 = 0;
    while (waited < finish_wait_ms) : (waited += status_poll_ms) {
        if (try loggedIn(init, login.profile.destination(), login.agent, login.path, login.provider)) {
            return .done;
        }

        try init.io.sleep(.fromMilliseconds(status_poll_ms), .awake);
    }

    return .failed;
}

// Runs the agent's own status command there; an ssh failure is an error,
// never "not logged in", which would open a login it cannot show.
fn loggedIn(init: std.process.Init, destination: []const u8, agent: Agent, path: []const u8, provider: ?[]const u8) !bool {
    var script_buffer: [2048]u8 = undefined;
    var script: std.Io.Writer = .fixed(&script_buffer);
    try remote_shell.assign(&script, "agent", path);
    try remote_shell.assign(&script, "provider", provider orelse "");
    try script.writeAll(statusScript(agent));
    try script.writeByte('\n');

    var result = try remote_shell.runScript(init, destination, script.buffered(), status_timeout_s);
    defer result.deinit(init.gpa);
    if (result.sshFailed()) {
        return error.SshFailed;
    }

    return result.succeeded();
}

// The provider Pi or OpenCode uses here, read from their settings: Pi's
// `defaultProvider`, the part of OpenCode's `model` before its slash.
fn localProvider(arena: std.mem.Allocator, io: std.Io, environ: std.process.Environ, agent: Agent) !?[]const u8 {
    const home = std.process.Environ.getPosix(environ, "HOME") orelse return null;
    const root = config_allowlist.rootFor(agent);
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const override = if (root.environment) |name| std.process.Environ.getPosix(environ, name) else null;
    const root_path = root.resolve(override, home, &root_buffer) orelse return null;
    return switch (agent) {
        .pi => settingString(arena, io, try std.fmt.allocPrint(arena, "{s}/settings.json", .{root_path}), "defaultProvider"),
        .opencode => provider: {
            for ([_][]const u8{ "opencode.json", "opencode.jsonc" }) |name| {
                const model = try settingString(arena, io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root_path, name }), "model") orelse continue;
                const slash = std.mem.indexOfScalar(u8, model, '/') orelse continue;
                break :provider model[0..slash];
            }

            break :provider null;
        },
        else => null,
    };
}

fn settingString(arena: std.mem.Allocator, io: std.Io, path: []const u8, key: []const u8) !?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_settings_bytes)) catch return null;
    const plain = config_filter.stripJsonc(arena, bytes) catch return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, plain, .{}) catch return null;
    if (value != .object) {
        return null;
    }

    const found = value.object.get(key) orelse return null;
    return if (found == .string) found.string else null;
}

// Keeps each login's outcome in the profile, under the file's lock.
fn record(init: std.process.Init, label: []const u8, path: []const u8, logins: std.EnumArray(Agent, ?AgentLogin)) !void {
    var edits: [std.enums.values(Agent).len]client.MachineEdit = undefined;
    var count: usize = 0;
    for (std.enums.values(Agent)) |agent| {
        const login = logins.get(agent) orelse continue;
        edits[count] = .{
            .kind = .record_login,
            .label = label,
            .login_agent = std.meta.stringToEnum(core.MachineProfile.LoginAgent, @tagName(agent)).?,
            .login = login,
        };
        count += 1;
    }

    if (count != 0) {
        try client.machine_profiles.storeAll(init.io, init.gpa, path, edits[0..count]);
    }
}

test "a login's link and one-time code are read from its pane" {
    const codex =
        \\Welcome to Codex [v0.158.0]
        \\
        \\1. Open this link in your browser and sign in to your account
        \\   https://auth.openai.com/codex/device
        \\
        \\2. Enter this one-time code (expires in 15 minutes)
        \\   ABCD-1234
    ;
    const openai: []const []const u8 = &.{"auth.openai.com"};
    const found = findLink(codex, openai, "one-time code").?;
    try std.testing.expectEqualStrings("https://auth.openai.com/codex/device", found.url);
    try std.testing.expectEqualStrings("ABCD-1234", found.code.?);

    const claude = "Browser didn't open? Use the url below to sign in:\n\nhttps://claude.ai/oauth/authorize?code=true&client_id=x&state=y.\n\nPaste code here if prompted >";
    const link = findLink(claude, planFor(.claude, null).?.hosts, null).?;
    try std.testing.expectEqualStrings("https://claude.ai/oauth/authorize?code=true&client_id=x&state=y", link.url);
    try std.testing.expectEqual(@as(?[]const u8, null), link.code);

    try std.testing.expectEqual(@as(?FoundLink, null), findLink("Logging in...", openai, null));
    try std.testing.expectEqualStrings("XY-99", findLink("url: https://auth.openai.com/codex/device\nEnter code: XY-99\n", openai, "Enter code:").?.code.?);
}

test "a link to another host, or with user info, is never taken for the login" {
    const claude = planFor(.claude, null).?.hosts;
    for ([_][]const u8{
        "Open https://claude.ai@evil.example/oauth/authorize to sign in",
        "Open https://claude.ai.evil.example/oauth/authorize to sign in",
        "Open https://evil.example/?next=https:claude.ai to sign in",
        "Open https://claude.ai:8443/oauth to sign in",
        "Open http://claude.ai/oauth to sign in",
    }) |text| {
        try std.testing.expectEqual(@as(?FoundLink, null), findLink(text, claude, null));
    }

    // A decoy printed first is passed over for the login's own link.
    const found = findLink("See https://evil.example/login first\nhttps://claude.com/cai/oauth/authorize?code=true\n", claude, null).?;
    try std.testing.expectEqualStrings("https://claude.com/cai/oauth/authorize?code=true", found.url);

    for (std.enums.values(Agent)) |agent| {
        const plan = planFor(agent, "openai") orelse continue;
        try std.testing.expect(!plan.link or plan.hosts.len != 0);
    }
}

test "the step says ok, changed, pending or failed from the logins" {
    var logins: std.EnumArray(Agent, ?AgentLogin) = .initFill(null);
    try std.testing.expectEqual(SetupReport.Status.skipped, aggregate(logins, false));
    logins.set(.claude, .done);
    try std.testing.expectEqual(SetupReport.Status.ok, aggregate(logins, false));
    try std.testing.expectEqual(SetupReport.Status.changed, aggregate(logins, true));
    logins.set(.codex, .pending);
    try std.testing.expectEqual(SetupReport.Status.pending, aggregate(logins, true));
    logins.set(.cursor, .failed);
    try std.testing.expectEqual(SetupReport.Status.failed, aggregate(logins, true));
}

test "agents without a browser login for their provider are left to the person" {
    try std.testing.expect(planFor(.opencode, "anthropic") == null);
    try std.testing.expect(planFor(.opencode, "openai") != null);
    try std.testing.expect(planFor(.pi, null) == null);
    try std.testing.expect(planFor(.claude, null).?.paste != null);
    try std.testing.expect(std.mem.startsWith(u8, statusScript(.pi), "[ -n \"$provider\" ]"));
}

test "only the pane setup recordeded, in its login workspace, is taken for a login" {
    const noted = parseRecord("7 12 31\n").?;
    try std.testing.expectEqual(@as(u64, 12), noted.tab_id);
    try std.testing.expectEqual(@as(?LoginPane, null), parseRecord(""));
    try std.testing.expectEqual(@as(?LoginPane, null), parseRecord("7 12"));
    try std.testing.expectEqual(@as(?LoginPane, null), parseRecord("7 12 31 4"));

    const title = "Log in to Codex";
    const panes = [_]LoginPane{noted};
    const own = [_]ListedWorkspace{.{ .workspace_id = 7, .name = title }};
    try std.testing.expect(claimed(noted, title, &own, &panes));

    // A person's workspace with the same name and other ids is not setup's.
    const persons = [_]ListedWorkspace{.{ .workspace_id = 9, .name = title }};
    try std.testing.expect(!claimed(noted, title, &persons, &panes));

    // A runtime that restarted gave the ids to a workspace named otherwise.
    const reused = [_]ListedWorkspace{.{ .workspace_id = 7, .name = "notes" }};
    try std.testing.expect(!claimed(noted, title, &reused, &panes));

    // The workspace is there but the pane is gone.
    try std.testing.expect(!claimed(noted, title, &own, &.{}));
}
