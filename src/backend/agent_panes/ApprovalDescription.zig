const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");
const Transcript = @import("Transcript.zig");
const Description = @This();

params: std.json.Value,
transcript: *const Transcript,
command_request: bool,

/// Fails before exposing an approval when its complete scope cannot fit.
/// Example: `try description.write(&request);`
pub fn write(description: Description, request: *core.AgentApprovalRequest) !void {
    try description.validateDecision();
    var writer: std.Io.Writer = .fixed(&request.description);
    try writer.writeAll(if (description.command_request) "Allow this command or terminal input?\n" else "Allow these file changes?\n");
    const params = description.params;
    const command_value = protocol.field(params, "command");
    if (command_value != .null and command_value != .string) {
        return error.InvalidProviderRequest;
    }

    const command = protocol.string(protocol.field(params, "command"));
    if (command.len != 0) {
        try writer.print("{s}\n", .{command});
    }

    const item_id = protocol.string(protocol.field(params, "itemId"));
    if (!description.command_request or command.len == 0) {
        if (try description.transcript.reviewText(item_id)) |details| {
            try writer.print("Requested action:\n{s}\n", .{details});
        } else if (!description.command_request or protocol.field(params, "networkApprovalContext") == .null) {
            return error.ApprovalDetailsUnavailable;
        }
    }

    if (params != .object) {
        return error.InvalidProviderRequest;
    }

    // Every non-null scope field is shown, including future provider extensions.
    // Only correlation IDs and the already displayed command are omitted.
    var fields = params.object.iterator();
    while (fields.next()) |field| {
        const key = field.key_ptr.*;
        const value = field.value_ptr.*;
        if (value == .null or isMetadata(key)) {
            continue;
        }

        if (std.mem.eql(u8, key, "grantRoot")) {
            if (value != .string) {
                return error.InvalidProviderRequest;
            }

            try writer.print("Requested write root for this session: {s}\n", .{protocol.string(value)});
        } else if (std.mem.eql(u8, key, "cwd")) {
            if (value != .string) {
                return error.InvalidProviderRequest;
            }

            try writer.print("Directory: {s}\n", .{protocol.string(value)});
        } else if (std.mem.eql(u8, key, "reason")) {
            if (value != .string) {
                return error.InvalidProviderRequest;
            }

            try writer.print("Reason: {s}\n", .{protocol.string(value)});
        } else {
            try writer.print("{s}: {f}\n", .{ key, std.json.fmt(value, .{ .whitespace = .indent_2 }) });
        }
    }

    request.description_len = @intCast(writer.end);
}

fn validateDecision(description: Description) !void {
    const decisions = protocol.field(description.params, "availableDecisions");
    if (decisions == .null) {
        return;
    }

    if (decisions == .array) {
        for (decisions.array.items) |decision| {
            if (protocol.is(decision, "accept")) {
                return;
            }
        }
    }

    return error.UnsupportedApprovalDecisions;
}

fn isMetadata(key: []const u8) bool {
    for ([_][]const u8{ "threadId", "turnId", "itemId", "approvalId", "startedAtMs", "command" }) |metadata| {
        if (std.mem.eql(u8, key, metadata)) {
            return true;
        }
    }

    return false;
}
