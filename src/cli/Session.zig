/// One connected control session with its owned receive buffer.
const Session = @This();
const source_namespace = @import("control.zig");
const std = @import("std");
const core = @import("telar-core");
const Snapshot = @import("Snapshot.zig");
const Agent = @import("ControlAgent.zig");
const AgentCommandReport = @import("AgentCommandReport.zig");
io: source_namespace.Io,
gpa: std.mem.Allocator,
connection: core.transport.SocketChannel,
receive_buffer: []u8,
next_request: u64 = 1,

/// Connects to the runtime named by the CLI socket option or the process
/// environment, starting it when necessary.
///
/// ```zig
/// var session = try Session.open(init, options.socket);
/// defer session.close();
/// ```
pub fn open(init: std.process.Init, socket: ?[*:0]const u8) !Session {
    const connector = try source_namespace.RuntimeConnector.init(init, socket);
    return Session.adopt(init, try connector.connectOrStart(.{}));
}

/// Connects to a runtime that is already listening and never starts one.
/// Reporters running inside a pane use it: the pane environment outlives
/// the runtime that injected it, so a report must not resurrect a stopped
/// runtime.
///
/// ```zig
/// var session = try Session.attach(init, options.socket);
/// defer session.close();
/// ```
pub fn attach(init: std.process.Init, socket: ?[*:0]const u8) !Session {
    const connector = try source_namespace.RuntimeConnector.init(init, socket);
    return Session.adopt(init, try connector.connect());
}

fn adopt(init: std.process.Init, connection: core.transport.SocketChannel) !Session {
    var owned = connection;
    errdefer owned.deinit(init.io);
    const receive_buffer = try init.gpa.alloc(u8, core.transport.max_frame_size);

    return .{
        .io = init.io,
        .gpa = init.gpa,
        .connection = owned,
        .receive_buffer = receive_buffer,
    };
}

pub fn close(session: *Session) void {
    session.connection.deinit(session.io);
    session.gpa.free(session.receive_buffer);
}

fn requestId(session: *Session) source_namespace.schema.RequestId {
    const request_id: source_namespace.schema.RequestId = @enumFromInt(session.next_request);
    session.next_request += 1;
    return request_id;
}

/// Fetches the current agent snapshot into owned storage.
///
/// ```zig
/// var snapshot: Snapshot = .{};
/// try session.fetchAgents(&snapshot);
/// ```
pub fn fetchAgents(session: *Session, snapshot: *Snapshot) !void {
    var send_buffer: [16]u8 = undefined;
    try session.connection.send(session.io, try source_namespace.schema.encodeQueryAgents(&send_buffer, .{
        .request_id = session.requestId(),
    }));

    const response = try source_namespace.schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
    const view = switch (response) {
        .agent_snapshot => |view| view,
        .request_failed => |failure| return source_namespace.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    };

    snapshot.revision = view.revision;
    snapshot.count = 0;
    var entries = view.entries();
    while (try entries.next()) |entry| {
        if (snapshot.count == snapshot.entries.len) {
            break;
        }

        snapshot.entries[snapshot.count] = Agent.fromEntry(entry);
        snapshot.count += 1;
    }
}

pub const PaneRef = struct {
    pane_id: u64,
    pane_generation: u64,
};

pub const Text = struct {
    pane_id: u64,
    truncated: bool,
    text: []const u8,
};

pub const ReadOptions = struct {
    rows: u16,
    source: source_namespace.schema.PaneTextSource,
};

pub const TextInput = struct {
    mode: source_namespace.schema.PaneTextMode,
    text: []const u8,
};

/// Reads bounded plain text from one exact pane generation. The returned
/// slice borrows the session's receive buffer until the next request.
///
/// ```zig
/// const text = try session.readPane(pane, .{ .rows = 40, .source = .recent });
/// ```
pub fn readPane(session: *Session, pane: PaneRef, options: ReadOptions) !Text {
    var send_buffer: [64]u8 = undefined;
    try session.connection.send(session.io, try source_namespace.schema.encodeReadPane(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try source_namespace.schema.id.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .rows = options.rows,
        .source = options.source,
    }));

    const response = try source_namespace.schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
    return switch (response) {
        .pane_text => |text| .{ .pane_id = pane.pane_id, .truncated = text.truncated, .text = text.text },
        .request_failed => |failure| source_namespace.failureError(failure),
        else => error.UnexpectedRuntimeResponse,
    };
}

/// Sends raw bytes or one prompt to an exact pane generation.
///
/// ```zig
/// try session.sendText(pane, .{ .mode = .prompt, .text = "run the tests" });
/// ```
pub fn sendText(session: *Session, pane: PaneRef, input: TextInput) !void {
    var send_buffer: [source_namespace.schema.max_pane_text_input_bytes + 64]u8 = undefined;
    try session.connection.send(session.io, try source_namespace.schema.encodeSendPaneText(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try source_namespace.schema.id.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .mode = input.mode,
        .text = input.text,
    }));

    const response = try source_namespace.schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return source_namespace.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

/// Requests a directional focus change from the UI that owns the pane's interaction.
///
/// ```zig
/// const result = try session.focusPane(pane, .left);
/// ```
pub fn focusPane(session: *Session, pane: PaneRef, direction: source_namespace.schema.PaneDirection) !source_namespace.schema.PaneFocusResult {
    var send_buffer: [64]u8 = undefined;
    try session.connection.send(session.io, try source_namespace.schema.encodeRequestPaneFocus(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try source_namespace.schema.id.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .direction = direction,
    }));

    const response = try source_namespace.schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
    return switch (response) {
        .pane_focus_result => |result| result,
        .request_failed => |failure| source_namespace.failureError(failure),
        else => error.UnexpectedRuntimeResponse,
    };
}

/// Reports an agent's own session reference for later restore.
///
/// ```zig
/// try session.reportSession(pane, "0192...");
/// ```
pub fn reportSession(session: *Session, pane: PaneRef, reference: []const u8) !void {
    var send_buffer: [source_namespace.schema.max_agent_session_reference_bytes + 64]u8 = undefined;
    try session.connection.send(session.io, try source_namespace.schema.encodeReportAgentSession(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try source_namespace.schema.id.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .session = reference,
    }));

    const response = try source_namespace.schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return source_namespace.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

pub const AgentReport = struct {
    state: source_namespace.schema.AgentReportState,
    session: []const u8 = "",
    session_file: []const u8 = "",
    session_file_kind: source_namespace.schema.AgentSessionFileKind = .claude_transcript,
};

/// Sends one official lifecycle report for the pane's agent.
///
/// ```zig
/// try session.reportAgent(pane, .{ .state = .working });
/// ```
pub fn reportAgent(session: *Session, pane: PaneRef, report: AgentReport) !void {
    var send_buffer: [source_namespace.schema.max_agent_session_reference_bytes + source_namespace.schema.max_agent_session_file_bytes + 64]u8 = undefined;
    try session.connection.send(session.io, try source_namespace.schema.encodeReportAgent(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try source_namespace.schema.id.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .state = report.state,
        .session = report.session,
        .session_file = report.session_file,
        .session_file_kind = report.session_file_kind,
    }));

    const response = try source_namespace.schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return source_namespace.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

/// Sends one shell-tool observation from an official agent hook.
///
/// ```zig
/// try session.reportAgentCommand(pane, command);
/// ```
pub fn reportAgentCommand(session: *Session, pane: PaneRef, command: AgentCommandReport) !void {
    var send_buffer: [source_namespace.schema.max_history_command_bytes + source_namespace.schema.max_cwd_bytes + 1024]u8 = undefined;
    try session.connection.send(session.io, try source_namespace.schema.encodeReportAgentCommand(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try source_namespace.schema.id.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .phase = command.phase,
        .provider = command.provider,
        .tool_call_id = command.tool_call_id,
        .command = command.command,
        .cwd = command.cwd,
        .session = command.session,
        .exit_code = command.exit_code,
    }));

    const response = try source_namespace.schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return source_namespace.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

/// Sends the name the agent's own session carries; empty clears it.
///
/// ```zig
/// try session.reportAgentTitle(pane, "Fix proxy");
/// ```
pub fn reportAgentTitle(session: *Session, pane: PaneRef, title: []const u8) !void {
    var send_buffer: [source_namespace.schema.max_agent_session_title_bytes + 64]u8 = undefined;
    try session.connection.send(session.io, try source_namespace.schema.encodeReportAgentTitle(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try source_namespace.schema.id.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .title = title,
    }));

    const response = try source_namespace.schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return source_namespace.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

pub const WorkspaceCreation = struct {
    name: []const u8,
    cwd: []const u8,
    arguments: []const []const u8,
};

/// Creates a named workspace rooted at an explicit path and returns the
/// runtime workspace id. The size only shapes the root pane until a UI
/// client attaches and resizes it.
///
/// ```zig
/// const id = try session.createWorkspace(.{ .name = "fix", .cwd = "/src/fix", .arguments = &.{"/bin/sh"} });
/// ```
pub fn createWorkspace(session: *Session, request: WorkspaceCreation) !u64 {
    var send_buffer: [8192]u8 = undefined;
    try session.connection.send(session.io, try source_namespace.schema.encodeCreateWorkspace(&send_buffer, .{
        .request_id = session.requestId(),
        .size = .{ .cols = 80, .rows = 24 },
        .name = request.name,
        .launch = .{ .cwd = request.cwd, .arguments = request.arguments },
    }));

    const response = try source_namespace.schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .pane_opened => |opened| return source_namespace.schema.id.raw(opened.location.workspace.workspace),
        .request_failed => |failure| return source_namespace.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

pub fn nowMs(session: *const Session) i64 {
    return source_namespace.Io.Timestamp.now(session.io, .real).toMilliseconds();
}

pub fn sleepMs(session: *const Session, milliseconds: u32) void {
    session.io.sleep(.fromMilliseconds(milliseconds), .awake) catch {};
}
