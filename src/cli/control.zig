//! Shared control-client helpers for CLI commands that address panes and
//! agents through the local runtime.

const std = @import("std");
const core = @import("telar-core");
const parser = @import("parser.zig");
const runtime_connection = @import("runtime_connection.zig");

const Io = std.Io;
const File = Io.File;
const schema = core.schema;
const RuntimeConnector = runtime_connection.RuntimeConnector;

pub const max_entries = schema.max_agent_snapshot_entries;

/// One decoded agent entry with its variable-length labels copied into owned
/// storage, so a snapshot can be inspected after the receive buffer is reused.
pub const Agent = struct {
    pane_id: u64,
    pane_generation: u64,
    workspace_id: u64,
    tab_id: u64,
    pane_index: u16,
    provider: schema.AgentProvider,
    status: schema.AgentStatus,
    workspace_label: [schema.max_agent_workspace_label_bytes]u8 = undefined,
    workspace_label_len: u8 = 0,
    tab_label: [schema.max_tab_label_bytes]u8 = undefined,
    tab_label_len: u8 = 0,
    title: [schema.max_agent_session_title_bytes]u8 = undefined,
    title_len: u8 = 0,
    cwd_label: [schema.max_agent_cwd_label_bytes]u8 = undefined,
    cwd_label_len: u8 = 0,
    provider_name: [schema.max_agent_provider_name_bytes]u8 = undefined,
    provider_name_len: u8 = 0,

    /// Manifest name of the provider, or the built-in label when the runtime
    /// sent none.
    pub fn providerLabel(agent: *const Agent) []const u8 {
        if (agent.provider_name_len != 0) {
            return agent.provider_name[0..agent.provider_name_len];
        }

        return providerName(agent.provider);
    }

    pub fn workspaceLabel(agent: *const Agent) []const u8 {
        return agent.workspace_label[0..agent.workspace_label_len];
    }

    pub fn tabLabel(agent: *const Agent) []const u8 {
        return agent.tab_label[0..agent.tab_label_len];
    }

    pub fn titleSlice(agent: *const Agent) []const u8 {
        return agent.title[0..agent.title_len];
    }

    pub fn cwdLabel(agent: *const Agent) []const u8 {
        return agent.cwd_label[0..agent.cwd_label_len];
    }

    fn fromEntry(entry: schema.AgentSnapshotEntry) Agent {
        var agent: Agent = .{
            .pane_id = schema.id.raw(entry.pane_id),
            .pane_generation = entry.pane_generation,
            .workspace_id = schema.id.raw(entry.location.workspace.workspace),
            .tab_id = schema.id.raw(entry.location.tab_id),
            .pane_index = entry.pane_index,
            .provider = entry.provider,
            .status = entry.status,
        };
        agent.workspace_label_len = copyBounded(&agent.workspace_label, entry.workspace_label);
        agent.tab_label_len = copyBounded(&agent.tab_label, entry.tab_label);
        agent.title_len = copyBounded(&agent.title, entry.session_title);
        agent.cwd_label_len = copyBounded(&agent.cwd_label, entry.cwd_label);
        agent.provider_name_len = copyBounded(&agent.provider_name, entry.provider_name);
        return agent;
    }
};

pub const Snapshot = struct {
    revision: u64 = 0,
    entries: [max_entries]Agent = undefined,
    count: usize = 0,

    pub fn slice(snapshot: *const Snapshot) []const Agent {
        return snapshot.entries[0..snapshot.count];
    }

    /// Finds the unique agent named by a CLI target. `current` reads
    /// `TELAR_PANE_ID`; a name matches the session title case-insensitively.
    ///
    /// ```zig
    /// const agent = try snapshot.resolve(target, environ) orelse return error.AgentNotFound;
    /// ```
    pub fn resolve(snapshot: *const Snapshot, target: parser.Target, environ: std.process.Environ) !?*const Agent {
        const wanted_pane: ?u64 = switch (target) {
            .current => try currentPaneId(environ),
            .pane => |pane| pane,
            .name => null,
        };

        if (wanted_pane) |pane_id| {
            for (snapshot.slice()) |*agent| {
                if (agent.pane_id == pane_id) {
                    return agent;
                }
            }

            return null;
        }

        const name = std.mem.span(target.name);
        var found: ?*const Agent = null;
        for (snapshot.slice()) |*agent| {
            if (!std.ascii.eqlIgnoreCase(agent.titleSlice(), name)) {
                continue;
            }
            if (found != null) {
                return error.AmbiguousAgentName;
            }

            found = agent;
        }

        return found;
    }
};

/// Reads the pane identity the runtime injected into this process.
///
/// ```zig
/// const pane_id = try currentPaneId(environ);
/// ```
pub fn currentPaneId(environ: std.process.Environ) !u64 {
    const value = std.process.Environ.getPosix(environ, "TELAR_PANE_ID") orelse return error.NotInsideTelarPane;
    return std.fmt.parseUnsigned(u64, value, 10) catch error.NotInsideTelarPane;
}

/// One connected control session with its owned receive buffer.
pub const Session = struct {
    io: Io,
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
        const connector = try RuntimeConnector.init(init, socket);
        var connection = try connector.connectOrStart(.{});
        errdefer connection.deinit(init.io);
        const receive_buffer = try init.gpa.alloc(u8, core.transport.max_frame_size);

        return .{
            .io = init.io,
            .gpa = init.gpa,
            .connection = connection,
            .receive_buffer = receive_buffer,
        };
    }

    pub fn close(session: *Session) void {
        session.connection.deinit(session.io);
        session.gpa.free(session.receive_buffer);
    }

    fn requestId(session: *Session) schema.RequestId {
        const request_id: schema.RequestId = @enumFromInt(session.next_request);
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
        try session.connection.send(session.io, try schema.encodeQueryAgents(&send_buffer, .{
            .request_id = session.requestId(),
        }));

        const response = try schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
        const view = switch (response) {
            .agent_snapshot => |view| view,
            .request_failed => |failure| return failureError(failure),
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
        truncated: bool,
        text: []const u8,
    };

    /// Reads bounded plain text from one exact pane generation. The returned
    /// slice borrows the session's receive buffer until the next request.
    ///
    /// ```zig
    /// const text = try session.readPane(pane, 40, .recent);
    /// ```
    pub fn readPane(session: *Session, pane: PaneRef, rows: u16, source: schema.PaneTextSource) !Text {
        var send_buffer: [64]u8 = undefined;
        try session.connection.send(session.io, try schema.encodeReadPane(&send_buffer, .{
            .request_id = session.requestId(),
            .pane_id = try schema.id.pane(pane.pane_id),
            .pane_generation = pane.pane_generation,
            .rows = rows,
            .source = source,
        }));

        const response = try schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
        return switch (response) {
            .pane_text => |text| .{ .truncated = text.truncated, .text = text.text },
            .request_failed => |failure| failureError(failure),
            else => error.UnexpectedRuntimeResponse,
        };
    }

    /// Sends raw bytes or one prompt to an exact pane generation.
    ///
    /// ```zig
    /// try session.sendText(pane, .prompt, "run the tests");
    /// ```
    pub fn sendText(session: *Session, pane: PaneRef, mode: schema.PaneTextMode, text: []const u8) !void {
        var send_buffer: [schema.max_pane_text_input_bytes + 64]u8 = undefined;
        try session.connection.send(session.io, try schema.encodeSendPaneText(&send_buffer, .{
            .request_id = session.requestId(),
            .pane_id = try schema.id.pane(pane.pane_id),
            .pane_generation = pane.pane_generation,
            .mode = mode,
            .text = text,
        }));

        const response = try schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
        switch (response) {
            .request_completed => {},
            .request_failed => |failure| return failureError(failure),
            else => return error.UnexpectedRuntimeResponse,
        }
    }

    /// Reports an agent's own session reference for later restore.
    ///
    /// ```zig
    /// try session.reportSession(pane, "0192...");
    /// ```
    pub fn reportSession(session: *Session, pane: PaneRef, reference: []const u8) !void {
        var send_buffer: [schema.max_agent_session_reference_bytes + 64]u8 = undefined;
        try session.connection.send(session.io, try schema.encodeReportAgentSession(&send_buffer, .{
            .request_id = session.requestId(),
            .pane_id = try schema.id.pane(pane.pane_id),
            .pane_generation = pane.pane_generation,
            .session = reference,
        }));

        const response = try schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
        switch (response) {
            .request_completed => {},
            .request_failed => |failure| return failureError(failure),
            else => return error.UnexpectedRuntimeResponse,
        }
    }

    /// Sends one official lifecycle report for the pane's agent.
    ///
    /// ```zig
    /// try session.reportAgent(pane, .working, "");
    /// ```
    pub fn reportAgent(session: *Session, pane: PaneRef, state: schema.AgentReportState, reference: []const u8) !void {
        var send_buffer: [schema.max_agent_session_reference_bytes + 64]u8 = undefined;
        try session.connection.send(session.io, try schema.encodeReportAgent(&send_buffer, .{
            .request_id = session.requestId(),
            .pane_id = try schema.id.pane(pane.pane_id),
            .pane_generation = pane.pane_generation,
            .state = state,
            .session = reference,
        }));

        const response = try schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
        switch (response) {
            .request_completed => {},
            .request_failed => |failure| return failureError(failure),
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
        try session.connection.send(session.io, try schema.encodeCreateWorkspace(&send_buffer, .{
            .request_id = session.requestId(),
            .size = .{ .cols = 80, .rows = 24 },
            .name = request.name,
            .launch = .{ .cwd = request.cwd, .arguments = request.arguments },
        }));

        const response = try schema.decodeServer(try session.connection.receive(session.io, session.receive_buffer));
        switch (response) {
            .pane_opened => |opened| return schema.id.raw(opened.location.workspace.workspace),
            .request_failed => |failure| return failureError(failure),
            else => return error.UnexpectedRuntimeResponse,
        }
    }

    pub fn nowMs(session: *const Session) i64 {
        return Io.Timestamp.now(session.io, .real).toMilliseconds();
    }

    pub fn sleepMs(session: *const Session, milliseconds: u32) void {
        session.io.sleep(.fromMilliseconds(milliseconds), .awake) catch {};
    }
};

pub const ControlError = error{
    PaneNotFound,
    PaneExited,
    AgentBlocked,
    InvalidRequest,
    RuntimeRefused,
};

fn failureError(failure: schema.RequestFailed) ControlError {
    return switch (failure.code) {
        .pane_not_found => error.PaneNotFound,
        .pane_exited => error.PaneExited,
        .agent_blocked => error.AgentBlocked,
        .invalid_request => error.InvalidRequest,
        else => error.RuntimeRefused,
    };
}

/// Text for a control failure, suitable for stderr and scripts.
///
/// ```zig
/// std.debug.print("telar agent: {s}\n", .{describe(err)});
/// ```
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.PaneNotFound => "pane not found or its generation is stale",
        error.PaneExited => "pane already exited",
        error.AgentBlocked => "agent is waiting for a decision; answer it before prompting",
        error.InvalidRequest => "runtime rejected the request",
        error.RuntimeRefused => "runtime refused the request",
        error.AgentNotFound => "no agent matches that target",
        error.AmbiguousAgentName => "more than one agent has that title; use the pane id",
        error.NotInsideTelarPane => "TELAR_PANE_ID is not set; run inside a telar pane or name a pane",
        error.RuntimeUnavailable => "the local runtime is not reachable",
        error.UnexpectedRuntimeResponse => "unexpected reply from the runtime",
        else => @errorName(err),
    };
}

pub fn statusName(status: schema.AgentStatus) []const u8 {
    return switch (status) {
        .unknown => "unknown",
        .working => "working",
        .blocked => "blocked",
        .ready => "ready",
        .done => "done",
        .failed => "failed",
    };
}

pub fn providerName(provider: schema.AgentProvider) []const u8 {
    return switch (provider) {
        .unknown => "unknown",
        .claude => "claude",
        .codex => "codex",
        else => "custom",
    };
}

/// Writes one JSON string literal with the escapes JSON requires.
///
/// ```zig
/// try writeJsonString(writer, title);
/// ```
pub fn writeJsonString(writer: *Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

/// Writes one agent as a JSON object.
///
/// ```zig
/// try writeAgentJson(writer, agent);
/// ```
pub fn writeAgentJson(writer: *Io.Writer, agent: *const Agent) !void {
    try writer.print("{{\"pane_id\":{d},\"pane_generation\":{d},\"workspace_id\":{d},\"tab_id\":{d},\"pane_index\":{d},\"provider\":", .{
        agent.pane_id,
        agent.pane_generation,
        agent.workspace_id,
        agent.tab_id,
        agent.pane_index,
    });
    try writeJsonString(writer, agent.providerLabel());
    try writer.print(",\"provider_index\":{d},\"status\":", .{@intFromEnum(agent.provider)});
    try writeJsonString(writer, statusName(agent.status));
    try writer.writeAll(",\"workspace\":");
    try writeJsonString(writer, agent.workspaceLabel());
    try writer.writeAll(",\"tab\":");
    try writeJsonString(writer, agent.tabLabel());
    try writer.writeAll(",\"title\":");
    try writeJsonString(writer, agent.titleSlice());
    try writer.writeAll(",\"cwd\":");
    try writeJsonString(writer, agent.cwdLabel());
    try writer.writeByte('}');
}

/// Writes one agent as a fixed-column text row.
///
/// ```zig
/// try writeAgentRow(writer, agent);
/// ```
pub fn writeAgentRow(writer: *Io.Writer, agent: *const Agent) !void {
    try writer.print("{d:<6}{d:<5}{s:<9}{s:<8}{s:<18}{s:<14}{s}\n", .{
        agent.pane_id,
        agent.pane_generation,
        statusName(agent.status),
        agent.providerLabel(),
        agent.workspaceLabel(),
        agent.tabLabel(),
        agent.titleSlice(),
    });
}

pub const agent_row_header = "PANE  GEN  STATUS   PROV    WORKSPACE         TAB           TITLE\n";

fn copyBounded(storage: []u8, value: []const u8) u8 {
    const len = @min(storage.len, value.len);
    @memcpy(storage[0..len], value[0..len]);
    return @intCast(len);
}

test "json strings escape quotes, backslashes and control bytes" {
    var buffer: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);

    try writeJsonString(&writer, "a\"b\\c\nd\x01");

    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", writer.buffered());
}

test "snapshot resolution prefers exact pane ids and rejects ambiguous titles" {
    var snapshot: Snapshot = .{};
    snapshot.entries[0] = Agent.fromEntry(.{
        .pane_id = try schema.id.pane(7),
        .pane_generation = 2,
        .process_id = 1,
        .session_id = .{0} ** 16,
        .session_title = "Investigate proxy",
        .provider = .claude,
        .status = .done,
        .source = .proxy_tls,
        .authority = .active,
        .confidence = 90,
        .sequence = 1,
        .observed_at_ms = 0,
        .expires_at_ms = 0,
    });
    snapshot.entries[1] = snapshot.entries[0];
    snapshot.entries[1].pane_id = 8;
    snapshot.count = 2;

    try std.testing.expectEqual(@as(u64, 8), (try snapshot.resolve(.{ .pane = 8 }, .empty)).?.pane_id);
    try std.testing.expect(try snapshot.resolve(.{ .pane = 9 }, .empty) == null);
    try std.testing.expectError(error.AmbiguousAgentName, snapshot.resolve(.{ .name = "investigate PROXY" }, .empty));
    try std.testing.expectError(error.NotInsideTelarPane, snapshot.resolve(.current, .empty));

    snapshot.count = 1;
    try std.testing.expectEqual(@as(u64, 7), (try snapshot.resolve(.{ .name = "investigate PROXY" }, .empty)).?.pane_id);
}
