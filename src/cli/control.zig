//! Shared control-client helpers for CLI commands that address panes and
//! agents through the local runtime.

const std = @import("std");
const RequestFailedType = @import("telar-core").RequestFailed;
const AgentStatusType = @import("telar-core").AgentStatus;
const ControlAgent = @import("ControlAgent.zig");
const Snapshot = @import("Snapshot.zig");
const pane_module = @import("telar-core").pane;

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

pub const ControlError = error{
    PaneNotFound,
    PaneExited,
    AgentBlocked,
    InvalidRequest,
    RuntimeRefused,
};

pub fn failureError(failure: RequestFailedType) ControlError {
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

pub fn statusName(status: AgentStatusType) []const u8 {
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
        .pane_id = try pane_module(7),
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
