//! Shared control-client helpers for CLI commands that address panes and
//! agents through the local runtime.

const core = @import("telar-core");
const std = @import("std");
const ControlAgent = @import("ControlAgent.zig");
const Snapshot = @import("Snapshot.zig");

/// Reads the pane identity the runtime injected into this process.
///
/// ```zig
/// const pane_id = try currentPaneId(environ);
/// ```
pub fn currentPaneId(environ: std.process.Environ) !u64 {
    const value = std.process.Environ.getPosix(environ, "TELAR_PANE_ID") orelse return error.NotInsideTelarPane;
    return std.fmt.parseUnsigned(u64, value, 10) catch error.NotInsideTelarPane;
}

/// Reads the exact pane generation injected by the runtime.
///
/// ```zig
/// const generation = try currentPaneGeneration(environ);
/// ```
pub fn currentPaneGeneration(environ: std.process.Environ) !u64 {
    const value = std.process.Environ.getPosix(environ, "TELAR_PANE_GENERATION") orelse return error.NotInsideTelarPane;
    const generation = std.fmt.parseUnsigned(u64, value, 10) catch return error.NotInsideTelarPane;
    if (generation == 0) {
        return error.NotInsideTelarPane;
    }
    return generation;
}

/// The pane this process runs in, when the command talks to the runtime that
/// owns that pane: `TELAR_PANE_ID` names a pane of the runtime at
/// `TELAR_SOCKET_PATH`, not of one reached through `--socket` or
/// `TELAR_SOCKET`.
///
/// ```zig
/// const sender = control.senderPane(environ, options.socket);
/// ```
pub fn senderPane(environ: std.process.Environ, socket: ?[*:0]const u8) ?u64 {
    const pane_id = currentPaneId(environ) catch return null;
    const own = std.process.Environ.getPosix(environ, "TELAR_SOCKET_PATH") orelse return null;
    if (socket) |explicit| {
        return if (std.mem.eql(u8, std.mem.span(explicit), own)) pane_id else null;
    }

    if (std.process.Environ.getPosix(environ, "TELAR_SOCKET")) |configured| {
        if (configured.len != 0 and !std.mem.eql(u8, configured, own)) {
            return null;
        }
    }

    return pane_id;
}

pub const ControlError = error{
    PaneNotFound,
    PaneExited,
    AgentBlocked,
    InvalidRequest,
    RuntimeRefused,
    WorktreeNotFound,
    WorkspaceNotFound,
    PaneFocused,
    PromptRateLimited,
    AgentNotWorking,
    InterruptUnsupported,
    ForeignProcess,
};

pub fn failureError(failure: core.RequestFailed) ControlError {
    return switch (failure.code) {
        .pane_not_found => error.PaneNotFound,
        .pane_exited => error.PaneExited,
        .agent_blocked => error.AgentBlocked,
        .invalid_request => error.InvalidRequest,
        .worktree_not_found => error.WorktreeNotFound,
        .workspace_not_found => error.WorkspaceNotFound,
        .pane_focused => error.PaneFocused,
        .prompt_rate_limited => error.PromptRateLimited,
        .agent_not_working => error.AgentNotWorking,
        .interrupt_unsupported => error.InterruptUnsupported,
        .foreign_process => error.ForeignProcess,
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
        error.WorktreeNotFound => "no tracked worktree matches that branch or title",
        error.WorkspaceNotFound => "workspace not found",
        error.PaneFocused => "that pane has the focus in an attached telar window, where a person may type; try again once another pane has it, or open tabs for automation with `telar tab create --background`",
        error.PromptRateLimited => "prompt budget for that pane is spent; wait for its answer with `telar agent wait`",
        error.AgentNotWorking => "the agent is not working; nothing to interrupt",
        error.InterruptUnsupported => "that agent declares no interrupt key",
        error.ForeignProcess => "only a process inside that pane may report for its agent, and only for the agent the pane runs",
        error.AmbiguousWorktree => "more than one worktree has that branch or title; name it by the other",
        error.WorktreeHasNoAgent => "no agent runs in that worktree",
        error.InvalidSendText => std.fmt.comptimePrint("send-keys needs text of 1 to {d} bytes, or --stdin", .{core.max_pane_text_input_bytes}),
        else => @errorName(err),
    };
}

pub fn statusName(status: core.AgentStatus) []const u8 {
    return switch (status) {
        .unknown => "unknown",
        .working => "working",
        .blocked => "blocked",
        .ready => "ready",
        .done => "done",
        .failed => "failed",
    };
}

/// Writes one JSON string literal with the escapes JSON requires.
///
/// ```zig
/// try writeJsonString(writer, title);
/// ```
pub fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
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
pub fn writeAgentJson(writer: *std.Io.Writer, agent: *const ControlAgent) !void {
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
    try writer.writeAll(",\"blocked_reason\":");
    try writeJsonString(writer, @tagName(agent.blocked_reason));
    try writer.print(",\"status_age_s\":{d},\"worktree_id\":{d},\"last_event\":", .{ agent.status_age_s, agent.work_tree });
    try writeJsonString(writer, agent.lastEvent());
    try writer.print(",\"plan\":{{\"done\":{d},\"total\":{d},\"step\":", .{ agent.plan_done, agent.plan_total });
    try writeJsonString(writer, agent.planStep());
    try writer.writeAll("},\"final_message\":");
    try writeJsonString(writer, agent.finalMessage());
    try writer.writeByte('}');
}

/// Writes one agent as a fixed-column text row.
///
/// ```zig
/// try writeAgentRow(writer, agent);
/// ```
pub fn writeAgentRow(writer: *std.Io.Writer, agent: *const ControlAgent) !void {
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

pub fn copyBounded(storage: []u8, value: []const u8) u8 {
    const len = @min(storage.len, value.len);
    @memcpy(storage[0..len], value[0..len]);
    return @intCast(len);
}

test "json strings escape quotes, backslashes and control bytes" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeJsonString(&writer, "a\"b\\c\nd\x01");

    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", writer.buffered());
}

test "snapshot resolution prefers exact pane ids and rejects ambiguous titles" {
    var snapshot: Snapshot = .{};
    snapshot.entries[0] = ControlAgent.fromEntry(.{
        .pane_id = try core.pane(7),
        .pane_generation = 2,
        .process_id = 1,
        .session_id = .{0} ** 16,
        .session_title = "Investigate proxy",
        .provider = .claude,
        .status = .done,
        .source = .lifecycle_report,
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
