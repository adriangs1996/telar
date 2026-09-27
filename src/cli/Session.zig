const client = @import("telar-client");
const localsocket = @import("localsocket");
const std = @import("std");
const RuntimeConnector = client.RuntimeConnector;
const Snapshot = @import("Snapshot.zig");
const control = @import("control.zig");
const ControlAgent = @import("ControlAgent.zig");
const AgentCommandReport = @import("AgentCommandReport.zig");
const core = @import("telar-core");
const ReviewSelection = @import("ReviewSelection.zig");
/// One connected control session with its owned receive buffer.
const Session = @This();

io: std.Io,
gpa: std.mem.Allocator,
connection: localsocket.SocketChannel,
receive_buffer: []u8,
next_request: u64 = 1,
review_failure: ?[]const u8 = null,

/// Connects to the runtime named by the CLI socket option or the process
/// environment, starting it when necessary.
///
/// ```zig
/// var session = try Session.open(init, options.socket);
/// defer session.close();
/// ```
pub fn open(init: std.process.Init, socket: ?[*:0]const u8) !Session {
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, socket);
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
    const connector = try RuntimeConnector.init(init.io, init.minimal.environ, socket);
    return adopt(init, try connector.connect());
}

fn adopt(init: std.process.Init, connection: localsocket.SocketChannel) !Session {
    var owned = connection;
    errdefer owned.deinit(init.io);
    const receive_buffer = try init.gpa.alloc(u8, localsocket.transport.max_frame_size);

    return .{
        .io = init.io,
        .gpa = init.gpa,
        .connection = owned,
        .receive_buffer = receive_buffer,
    };
}

pub fn close(self: *Session) void {
    self.connection.deinit(self.io);
    self.gpa.free(self.receive_buffer);
}

fn requestId(self: *Session) core.RequestId {
    const request_id: core.RequestId = @enumFromInt(self.next_request);
    self.next_request += 1;
    return request_id;
}

/// Executes one correlated typed request, ignoring unrelated events. Response slices expire on the next receive.
/// Example: `const reply = try session.exchange(core.encodeRenameWorkspace, request);`
pub fn exchange(self: *Session, comptime encode: anytype, request_value: anytype) !core.ServerMessage {
    var request = request_value;
    request.request_id = self.requestId();
    const buffer = try self.gpa.alloc(u8, localsocket.transport.max_frame_size);
    defer self.gpa.free(buffer);
    try self.connection.send(self.io, try encode(buffer, request));

    while (true) {
        const response = try self.receive();
        switch (response) {
            inline else => |value| {
                if (comptime @typeInfo(@TypeOf(value)) == .@"struct") {
                    if (comptime @hasField(@TypeOf(value), "request_id")) {
                        if (value.request_id == request.request_id) {
                            return response;
                        }
                    }
                }
            },
        }
    }
}

/// Subscribes a disposable observer without adopting a UI's layout identity. Example: `try session.subscribeRuntime();`
pub fn subscribeRuntime(self: *Session) !void {
    var identity: u64 = 0;
    while (identity == 0) {
        self.io.random(std.mem.asBytes(&identity));
    }

    var buffer: [16]u8 = undefined;
    try self.connection.send(self.io, try core.encodeRequestRuntimeState(&buffer, .{ .client_identity = @enumFromInt(identity), .interactive = false }));
}

/// Borrows one decoded response until the next receive, propagating runtime failures. Example: `const response = try session.receive();`
pub fn receive(self: *Session) !core.ServerMessage {
    const Event = union(enum) { response: anyerror!core.ServerMessage, timeout: anyerror!void };
    var events: [2]Event = undefined;
    var select: std.Io.Select(Event) = .init(self.io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.response, receiveMessage, .{self});
    try select.concurrent(.timeout, receiveDeadline, .{self});

    return switch (try select.await()) {
        .response => |result| result,
        .timeout => |result| blk: {
            try result;
            break :blk error.RuntimeTimeout;
        },
    };
}

fn receiveDeadline(self: *Session) !void {
    try self.io.sleep(.fromSeconds(30), .awake);
}

fn receiveMessage(self: *Session) !core.ServerMessage {
    const response = try self.nextEvent();
    if (response == .runtime_stopping) {
        return error.RuntimeStopping;
    }

    return response;
}

/// Waits for subscription traffic without an idle timeout. Example: `const event = try session.nextEvent();`
pub fn nextEvent(self: *Session) !core.ServerMessage {
    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
    switch (response) {
        .request_failed => |failure| return control.failureError(failure),
        else => return response,
    }
}

/// Reads one immutable edition; returned strings borrow the next receive buffer.
/// Example: `const review = try session.fetchReview(pane, .{});`
pub fn fetchReview(self: *Session, pane: PaneRef, selection: ReviewSelection) !core.ChangeReviewSnapshotView {
    self.review_failure = null;
    const id = self.requestId();
    var buffer: [256]u8 = undefined;
    try self.connection.send(self.io, try core.encodeQueryChangeReview(&buffer, .{
        .request_id = id,
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .edition_id = selection.edition,
        .session = selection.session,
    }));
    return self.receiveReview(id);
}

/// Issues an explicit review action, replacing only its transport request ID.
/// Example: `const review = try session.commandReview(command);`
pub fn commandReview(self: *Session, command: core.ChangeReviewCommand) !core.ChangeReviewSnapshotView {
    self.review_failure = null;
    var request = command;
    request.request_id = self.requestId();
    var buffer: [16 * 1024]u8 = undefined;
    try self.connection.send(self.io, try core.encodeChangeReviewCommand(&buffer, request));
    return self.receiveReview(request.request_id);
}

/// Records evidence already read by the hook process, without runtime file I/O.
/// Example: `try session.reportReviewSample(sample);`
pub fn reportReviewSample(self: *Session, sample: core.ReportChangeReviewSample) !void {
    var request = sample;
    request.request_id = self.requestId();
    var buffer: [32 * 1024]u8 = undefined;
    try self.connection.send(self.io, try core.encodeReportChangeReviewSample(&buffer, request));
    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
    switch (response) {
        .request_completed => |completed| if (completed.request_id != request.request_id) {
            return error.UnexpectedRuntimeResponse;
        },
        .request_failed => |failure| return control.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

fn receiveReview(self: *Session, id: core.RequestId) !core.ChangeReviewSnapshotView {
    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
    const review = switch (response) {
        .change_review_snapshot => |view| view,
        .request_failed => |failure| {
            self.review_failure = failure.message;
            return control.failureError(failure);
        },
        else => return error.UnexpectedRuntimeResponse,
    };
    if (review.request_id != id) {
        return error.UnexpectedRuntimeResponse;
    }

    return review;
}

/// Fetches the current agent snapshot into owned storage.
///
/// ```zig
/// var snapshot: Snapshot = .{};
/// try session.fetchAgents(&snapshot);
/// ```
pub fn fetchAgents(self: *Session, snapshot: *Snapshot) !void {
    var send_buffer: [16]u8 = undefined;
    try self.connection.send(self.io, try core.encodeQueryAgents(&send_buffer, .{
        .request_id = self.requestId(),
    }));

    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
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
pub fn readPane(self: *Session, pane: PaneRef, options: ReadOptions) !Text {
    var send_buffer: [64]u8 = undefined;
    try self.connection.send(self.io, try core.encodeReadPane(&send_buffer, .{
        .request_id = self.requestId(),
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .rows = options.rows,
        .source = options.source,
    }));

    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
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
pub fn sendText(self: *Session, pane: PaneRef, input: TextInput) !void {
    var send_buffer: [core.max_pane_text_input_bytes + 64]u8 = undefined;
    try self.connection.send(self.io, try core.encodeSendPaneText(&send_buffer, .{
        .request_id = self.requestId(),
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .mode = input.mode,
        .text = input.text,
    }));

    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
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
pub fn focusPane(self: *Session, pane: PaneRef, direction: core.PaneDirection) !core.PaneFocusResult {
    var send_buffer: [64]u8 = undefined;
    try self.connection.send(self.io, try core.encodeRequestPaneFocus(&send_buffer, .{
        .request_id = self.requestId(),
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .direction = direction,
    }));

    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
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
pub fn reportSession(self: *Session, pane: PaneRef, reference: []const u8) !void {
    var send_buffer: [core.max_agent_session_reference_bytes + 64]u8 = undefined;
    try self.connection.send(self.io, try core.encodeReportAgentSession(&send_buffer, .{
        .request_id = self.requestId(),
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .session = reference,
    }));

    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
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
pub fn reportAgent(self: *Session, pane: PaneRef, report: AgentReport) !void {
    var send_buffer: [core.max_agent_session_reference_bytes + core.max_agent_session_file_bytes + core.max_agent_last_event_bytes + 64]u8 = undefined;
    try self.connection.send(self.io, try core.encodeReportAgent(&send_buffer, .{
        .request_id = self.requestId(),
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .state = report.state,
        .blocked_reason = report.blocked_reason,
        .event = report.event,
        .session = report.session,
        .session_file = report.session_file,
        .session_file_kind = report.session_file_kind,
    }));

    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
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
pub fn reportAgentCommand(self: *Session, pane: PaneRef, command: AgentCommandReport) !void {
    var send_buffer: [core.max_history_command_bytes + core.max_cwd_bytes + 1024]u8 = undefined;
    try self.connection.send(self.io, try core.encodeReportAgentCommand(&send_buffer, .{
        .request_id = self.requestId(),
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .phase = command.phase,
        .provider = command.provider,
        .tool_call_id = command.tool_call_id,
        .command = command.command,
        .cwd = command.cwd,
        .session = command.session,
        .exit_code = command.exit_code,
    }));

    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
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
pub fn reportAgentTitle(self: *Session, pane: PaneRef, title: []const u8) !void {
    var send_buffer: [core.max_agent_session_title_bytes + 64]u8 = undefined;
    try self.connection.send(self.io, try core.encodeReportAgentTitle(&send_buffer, .{
        .request_id = self.requestId(),
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
        .title = title,
    }));

    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
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
pub fn createWorkspace(self: *Session, request: WorkspaceCreation) !u64 {
    var send_buffer: [8192]u8 = undefined;
    try self.connection.send(self.io, try core.encodeCreateWorkspace(&send_buffer, .{
        .request_id = self.requestId(),
        .size = .{ .cols = 80, .rows = 24 },
        .name = request.name,
        .launch = .{ .cwd = request.cwd, .arguments = request.arguments },
    }));

    const response = try core.decodeServer(try self.connection.receive(self.io, self.receive_buffer));
    switch (response) {
        .pane_opened => |opened| return core.raw(opened.location.workspace.workspace),
        .request_failed => |failure| return control.failureError(failure),
        else => return error.UnexpectedRuntimeResponse,
    }
}

pub fn nowMs(self: *const Session) i64 {
    return std.Io.Timestamp.now(self.io, .real).toMilliseconds();
}

pub fn sleepMs(self: *const Session, milliseconds: u32) void {
    self.io.sleep(.fromMilliseconds(milliseconds), .awake) catch {};
}

/// Sends a seen marker; a following query acts as an ordering barrier. Example: `try session.acknowledge(pane);`
pub fn acknowledge(self: *Session, pane: PaneRef) !void {
    var buffer: [64]u8 = undefined;
    try self.connection.send(self.io, try core.encodeAcknowledgeAgent(&buffer, .{
        .pane_id = try core.pane(pane.pane_id),
        .pane_generation = pane.pane_generation,
    }));
}
