const PaneRefType = @import("PaneRef.zig");
const TextType = @import("Text.zig");
const ReadOptionsType = @import("ReadOptions.zig");
const TextInputType = @import("TextInput.zig");
const AgentReportType = @import("AgentReport.zig");
const WorkspaceCreationType = @import("WorkspaceCreation.zig");
const std = @import("std");
const SocketChannelType = @import("telar-core").SocketChannel;
const RuntimeConnectorType = @import("RuntimeConnector.zig");
const max_frame_size_module = @import("telar-core").max_frame_size;
const RequestIdType = @import("telar-core").RequestId;
const Snapshot = @import("Snapshot.zig");
const encodeQueryAgents_module = @import("telar-core").encodeQueryAgents;
const decodeServer_module = @import("telar-core").decodeServer;
const control = @import("control.zig");
const ControlAgent = @import("ControlAgent.zig");
const encodeReadPane_module = @import("telar-core").encodeReadPane;
const pane_module = @import("telar-core").pane;
const max_pane_text_input_bytes_module = @import("telar-core").max_pane_text_input_bytes;
const encodeSendPaneText_module = @import("telar-core").encodeSendPaneText;
const PaneDirectionType = @import("telar-core").PaneDirection;
const PaneFocusResultType = @import("telar-core").PaneFocusResult;
const encodeRequestPaneFocus_module = @import("telar-core").encodeRequestPaneFocus;
const max_agent_session_reference_bytes_module = @import("telar-core").max_agent_session_reference_bytes;
const encodeReportAgentSession_module = @import("telar-core").encodeReportAgentSession;
const max_agent_session_file_bytes_module = @import("telar-core").max_agent_session_file_bytes;
const encodeReportAgent_module = @import("telar-core").encodeReportAgent;
const AgentCommandReport = @import("AgentCommandReport.zig");
const max_history_command_bytes_module = @import("telar-core").max_history_command_bytes;
const max_cwd_bytes_module = @import("telar-core").max_cwd_bytes;
const encodeReportAgentCommand_module = @import("telar-core").encodeReportAgentCommand;
const max_agent_session_title_bytes_module = @import("telar-core").max_agent_session_title_bytes;
const encodeReportAgentTitle_module = @import("telar-core").encodeReportAgentTitle;
const encodeCreateWorkspace_module = @import("telar-core").encodeCreateWorkspace;
const raw_module = @import("telar-core").raw;
/// One connected control session with its owned receive buffer.
const Session = @This();

io: std.Io,
gpa: std.mem.Allocator,
connection: SocketChannelType,
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
    const connector = try RuntimeConnectorType.init(init, socket);
    return adopt(init, try connector.connectOrStart(.{}));
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
    const connector = try RuntimeConnectorType.init(init, socket);
    return adopt(init, try connector.connect());
}

fn adopt(init: std.process.Init, connection: SocketChannelType) !Session {
    var owned = connection;
    errdefer owned.deinit(init.io);
    const receive_buffer = try init.gpa.alloc(u8, max_frame_size_module);

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

fn requestId(session: *Session) RequestIdType {
    const request_id: RequestIdType = @enumFromInt(session.next_request);
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
    try session.connection.send(session.io, try encodeQueryAgents_module(&send_buffer, .{
        .request_id = session.requestId(),
    }));

    const response = try decodeServer_module(try session.connection.receive(session.io, session.receive_buffer));
    const view = switch (response) {
        .agent_snapshot => |view| view,
        .request_failed => |failure| return control.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    };

    snapshot.revision = view.revision;
    snapshot.count = 0;
    var entries = view.entries();
    while (try entries.next()) |entry| {
        if (snapshot.count == snapshot.entries.len) {
            break;
        }

        snapshot.entries[snapshot.count] = ControlAgent.fromEntry(entry);
        snapshot.count += 1;
    }
}

pub const PaneRef = @import("PaneRef.zig");

pub const Text = @import("Text.zig");

pub const ReadOptions = @import("ReadOptions.zig");

pub const TextInput = @import("TextInput.zig");

/// Reads bounded plain text from one exact pane generation. The returned
/// slice borrows the session's receive buffer until the next request.
///
/// ```zig
/// const text = try session.readPane(pane, .{ .rows = 40, .source = .recent });
/// ```
pub fn readPane(session: *Session, pane: PaneRefType, options: ReadOptionsType) !TextType {
    var send_buffer: [64]u8 = undefined;
    try session.connection.send(session.io, try encodeReadPane_module(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try pane_module(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .rows = options.rows,
        .source = options.source,
    }));

    const response = try decodeServer_module(try session.connection.receive(session.io, session.receive_buffer));
    return switch (response) {
        .pane_text => |text| .{ .pane_id = pane.pane_id, .truncated = text.truncated, .text = text.text },
        .request_failed => |failure| control.failureError(failure),
        else => error.UnexpectedRuntimeResponse,
    };
}

/// Sends raw bytes or one prompt to an exact pane generation.
///
/// ```zig
/// try session.sendText(pane, .{ .mode = .prompt, .text = "run the tests" });
/// ```
pub fn sendText(session: *Session, pane: PaneRefType, input: TextInputType) !void {
    var send_buffer: [max_pane_text_input_bytes_module + 64]u8 = undefined;
    try session.connection.send(session.io, try encodeSendPaneText_module(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try pane_module(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .mode = input.mode,
        .text = input.text,
    }));

    const response = try decodeServer_module(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return control.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

/// Requests a directional focus change from the UI that owns the pane's interaction.
///
/// ```zig
/// const result = try session.focusPane(pane, .left);
/// ```
pub fn focusPane(session: *Session, pane: PaneRefType, direction: PaneDirectionType) !PaneFocusResultType {
    var send_buffer: [64]u8 = undefined;
    try session.connection.send(session.io, try encodeRequestPaneFocus_module(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try pane_module(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .direction = direction,
    }));

    const response = try decodeServer_module(try session.connection.receive(session.io, session.receive_buffer));
    return switch (response) {
        .pane_focus_result => |result| result,
        .request_failed => |failure| control.failureError(failure),
        else => error.UnexpectedRuntimeResponse,
    };
}

/// Reports an agent's own session reference for later restore.
///
/// ```zig
/// try session.reportSession(pane, "0192...");
/// ```
pub fn reportSession(session: *Session, pane: PaneRefType, reference: []const u8) !void {
    var send_buffer: [max_agent_session_reference_bytes_module + 64]u8 = undefined;
    try session.connection.send(session.io, try encodeReportAgentSession_module(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try pane_module(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .session = reference,
    }));

    const response = try decodeServer_module(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return control.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

pub const AgentReport = @import("AgentReport.zig");

/// Sends one official lifecycle report for the pane's agent.
///
/// ```zig
/// try session.reportAgent(pane, .{ .state = .working });
/// ```
pub fn reportAgent(session: *Session, pane: PaneRefType, report: AgentReportType) !void {
    var send_buffer: [max_agent_session_reference_bytes_module + max_agent_session_file_bytes_module + 64]u8 = undefined;
    try session.connection.send(session.io, try encodeReportAgent_module(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try pane_module(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .state = report.state,
        .session = report.session,
        .session_file = report.session_file,
        .session_file_kind = report.session_file_kind,
    }));

    const response = try decodeServer_module(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return control.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

/// Sends one shell-tool observation from an official agent hook.
///
/// ```zig
/// try session.reportAgentCommand(pane, command);
/// ```
pub fn reportAgentCommand(session: *Session, pane: PaneRefType, command: AgentCommandReport) !void {
    var send_buffer: [max_history_command_bytes_module + max_cwd_bytes_module + 1024]u8 = undefined;
    try session.connection.send(session.io, try encodeReportAgentCommand_module(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try pane_module(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .phase = command.phase,
        .provider = command.provider,
        .tool_call_id = command.tool_call_id,
        .command = command.command,
        .cwd = command.cwd,
        .session = command.session,
        .exit_code = command.exit_code,
    }));

    const response = try decodeServer_module(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return control.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

/// Sends the name the agent's own session carries; empty clears it.
///
/// ```zig
/// try session.reportAgentTitle(pane, "Fix proxy");
/// ```
pub fn reportAgentTitle(session: *Session, pane: PaneRefType, title: []const u8) !void {
    var send_buffer: [max_agent_session_title_bytes_module + 64]u8 = undefined;
    try session.connection.send(session.io, try encodeReportAgentTitle_module(&send_buffer, .{
        .request_id = session.requestId(),
        .pane_id = try pane_module(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .title = title,
    }));

    const response = try decodeServer_module(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .request_completed => {},
        .request_failed => |failure| return control.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

pub const WorkspaceCreation = @import("WorkspaceCreation.zig");

/// Creates a named workspace rooted at an explicit path and returns the
/// runtime workspace id. The size only shapes the root pane until a UI
/// client attaches and resizes it.
///
/// ```zig
/// const id = try session.createWorkspace(.{ .name = "fix", .cwd = "/src/fix", .arguments = &.{"/bin/sh"} });
/// ```
pub fn createWorkspace(session: *Session, request: WorkspaceCreationType) !u64 {
    var send_buffer: [8192]u8 = undefined;
    try session.connection.send(session.io, try encodeCreateWorkspace_module(&send_buffer, .{
        .request_id = session.requestId(),
        .size = .{ .cols = 80, .rows = 24 },
        .name = request.name,
        .launch = .{ .cwd = request.cwd, .arguments = request.arguments },
    }));

    const response = try decodeServer_module(try session.connection.receive(session.io, session.receive_buffer));
    switch (response) {
        .pane_opened => |opened| return raw_module(opened.location.workspace.workspace),
        .request_failed => |failure| return control.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

pub fn nowMs(session: *const Session) i64 {
    return std.Io.Timestamp.now(session.io, .real).toMilliseconds();
}

pub fn sleepMs(session: *const Session, milliseconds: u32) void {
    session.io.sleep(.fromMilliseconds(milliseconds), .awake) catch {};
}
