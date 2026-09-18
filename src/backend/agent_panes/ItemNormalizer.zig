const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");
const ItemUpdate = @import("ItemUpdate.zig");
const ItemNormalizer = @This();

body: [16 * 1024]u8 = undefined,
body_buffer: ?[]u8 = null,
include_history_details: bool = false,
heading: [512]u8 = undefined,
description: [2048]u8 = undefined,

/// Normalizes only public provider item fields. The returned slices borrow this scratch.
/// Example: `if (normalizer.item(value, true)) |update| transcript.update(update);`
pub fn item(normalizer: *ItemNormalizer, value: std.json.Value, complete: bool) ?ItemUpdate {
    const kind = protocol.field(value, "type");
    var result: ItemUpdate = .{
        .id = protocol.string(protocol.field(value, "id")),
        .role = .tool,
        .complete = complete,
        .status = status(protocol.field(value, "status"), complete),
    };
    var writer: std.Io.Writer = .fixed(normalizer.body_buffer orelse &normalizer.body);
    if (protocol.is(kind, "agentMessage") or protocol.is(kind, "plan")) {
        result.role = .assistant;
        result.kind = if (protocol.is(kind, "plan")) .plan else .message;
        result.title = if (result.kind == .plan) "Plan" else "";
        result.text = protocol.string(protocol.field(value, "text"));
        result.phase = if (protocol.is(protocol.field(value, "phase"), "commentary")) .commentary else if (protocol.is(protocol.field(value, "phase"), "final_answer")) .final_answer else .unknown;
        return result;
    } else if (protocol.is(kind, "userMessage")) {
        result.role = .user;
        result.kind = .message;
        const content = protocol.field(value, "content");
        if (content == .array) {
            var image_index: usize = 0;
            for (content.array.items, 0..) |part, index| {
                if (index != 0) {
                    writer.writeByte('\n') catch {
                        result.truncated = true;
                    };
                }

                const part_kind = protocol.field(part, "type");
                if (protocol.is(part_kind, "text")) {
                    writer.writeAll(protocol.string(protocol.field(part, "text"))) catch {
                        result.truncated = true;
                    };
                } else if (protocol.is(part_kind, "localImage") or protocol.is(part_kind, "image")) {
                    image_index += 1;
                    writer.print("[Image {d}]", .{image_index}) catch {
                        result.truncated = true;
                    };
                } else {
                    writer.print("[{s}] {f}", .{ protocol.string(part_kind), std.json.fmt(part, .{}) }) catch {
                        result.truncated = true;
                    };
                }
            }
        }
    } else if (protocol.is(kind, "reasoning")) {
        result.role = .assistant;
        result.kind = .reasoning;
        result.title = "Reasoning summary";
        const summary = protocol.field(value, "summary");
        if (summary == .array) {
            for (summary.array.items) |part| {
                writer.print("{s}\n", .{protocol.string(part)}) catch {
                    result.truncated = true;
                    break;
                };
            }
        }
    } else if (protocol.is(kind, "commandExecution")) {
        result.kind = .command;
        result.title = "Command";
        result.detail = std.fmt.bufPrint(&normalizer.description, "{s}\n{s}", .{ protocol.string(protocol.field(value, "command")), protocol.string(protocol.field(value, "cwd")) }) catch protocol.string(protocol.field(value, "command"));
        writer.print("$ {s}\n{s}", .{ protocol.string(protocol.field(value, "command")), protocol.string(protocol.field(value, "aggregatedOutput")) }) catch {
            result.truncated = true;
        };
        const exit_code = protocol.field(value, "exitCode");
        if (exit_code == .integer) {
            writer.print("\nExit code: {d}\n", .{exit_code.integer}) catch {
                result.truncated = true;
            };
        }
    } else if (protocol.is(kind, "fileChange")) {
        result.kind = .file_change;
        result.title = "File changes";
        const changes = protocol.field(value, "changes");
        result.truncated = changes != .array;
        if (changes == .array) {
            result.truncated = changes.array.items.len == 0;
            result.detail = std.fmt.bufPrint(&normalizer.description, "{d} file(s)", .{changes.array.items.len}) catch "";
            for (changes.array.items) |change| {
                fileChange(&writer, change) catch |err| {
                    result.truncated = true;
                    if (err != error.WriteFailed) {
                        writer.writeAll("File change details could not be represented safely.\n") catch {};
                    }

                    break;
                };
            }
        }
    } else if (protocol.is(kind, "mcpToolCall") or protocol.is(kind, "dynamicToolCall")) {
        result.kind = if (protocol.is(kind, "mcpToolCall")) .mcp else .dynamic_tool;
        result.title = std.fmt.bufPrint(&normalizer.heading, "{s} · {s}", .{ protocol.string(protocol.field(value, if (result.kind == .mcp) "server" else "namespace")), protocol.string(protocol.field(value, "tool")) }) catch protocol.string(protocol.field(value, "tool"));
        writer.print("Arguments\n{f}\n", .{std.json.fmt(protocol.field(value, "arguments"), .{ .whitespace = .indent_2 })}) catch {
            result.truncated = true;
        };
        const failure = protocol.field(value, "error");
        if (failure != .null) {
            result.status = .failed;
            writer.print("Error\n{s}\n", .{protocol.string(protocol.field(failure, "message"))}) catch {
                result.truncated = true;
            };
        }

        const output = protocol.field(value, if (result.kind == .mcp) "result" else "contentItems");
        if (output != .null) {
            toolOutput(&writer, output) catch {
                result.truncated = true;
            };
        }

        if (protocol.field(value, "success") == .bool and !protocol.field(value, "success").bool) {
            result.status = .failed;
        }
    } else if (protocol.is(kind, "webSearch")) {
        result.kind = .web_search;
        result.title = "Web search";
        result.detail = protocol.string(protocol.field(value, "query"));
        writer.print("{s}\n{f}\n", .{ protocol.string(protocol.field(value, "query")), std.json.fmt(protocol.field(value, "action"), .{}) }) catch {
            result.truncated = true;
        };
        const results = protocol.field(value, "results");
        if (results != .null) {
            writer.print("{f}\n", .{std.json.fmt(results, .{})}) catch {
                result.truncated = true;
            };
        }
    } else if (protocol.is(kind, "collabAgentToolCall")) {
        result.kind = .dispatch;
        result.title = dispatchTitle(protocol.string(protocol.field(value, "tool")));
        result.detail = protocol.string(protocol.field(value, "prompt"));
        writer.writeAll(protocol.string(protocol.field(value, "prompt"))) catch {
            result.truncated = true;
        };
        if (normalizer.include_history_details) {
            collaborationDetails(&writer, value) catch {
                result.truncated = true;
            };
        }
    } else if (protocol.is(kind, "contextCompaction")) {
        result.kind = .system;
        result.role = .system;
        result.title = "Context compacted";
    } else {
        return null;
    }

    result.text = writer.buffered();
    return result;
}

/// Example: `const state = ItemNormalizer.status(raw_status, completed);`
pub fn status(value: std.json.Value, complete: bool) core.agent_thread.ItemStatus {
    if (protocol.is(value, "failed")) {
        return .failed;
    }
    if (protocol.is(value, "declined")) {
        return .declined;
    }
    if (protocol.is(value, "interrupted")) {
        return .interrupted;
    }
    return if (complete or protocol.is(value, "completed")) .completed else .running;
}

fn fileChange(writer: *std.Io.Writer, change: std.json.Value) !void {
    try knownFields(change, &.{ "path", "kind", "diff" });
    const path = protocol.field(change, "path");
    const diff = protocol.field(change, "diff");
    const kind = protocol.field(change, "kind");
    try validPath(path);
    if (diff != .string or !std.unicode.utf8ValidateSlice(diff.string) or std.mem.indexOfScalar(u8, diff.string, 0) != null) {
        return error.UnsupportedFileChange;
    }

    const change_type = protocol.field(kind, "type");
    const is_update = protocol.is(change_type, "update");
    try knownFields(kind, if (is_update) &.{ "type", "move_path" } else &.{"type"});
    const label = if (is_update) "Updated" else if (protocol.is(change_type, "add")) "Added" else if (protocol.is(change_type, "delete")) "Deleted" else return error.UnsupportedFileChange;
    const destination = protocol.field(kind, "move_path");
    if (destination != .null) {
        try validPath(destination);
        try writer.writeAll("Moved ");
        try writePath(writer, path.string);
        try writer.writeAll(" → ");
        try writePath(writer, destination.string);
    } else {
        try writer.print("{s} ", .{label});
        try writePath(writer, path.string);
    }

    try writer.writeByte('\n');
    try writer.writeAll(diff.string);
    if (!std.mem.endsWith(u8, diff.string, "\n")) {
        try writer.writeByte('\n');
    }
}

fn knownFields(value: std.json.Value, allowed: []const []const u8) !void {
    if (value != .object) {
        return error.UnsupportedFileChange;
    }

    var fields = value.object.iterator();
    while (fields.next()) |field| {
        var known = false;
        for (allowed) |name| {
            known = known or std.mem.eql(u8, field.key_ptr.*, name);
        }

        if (!known) {
            return error.UnsupportedFileChange;
        }
    }
}

fn validPath(value: std.json.Value) !void {
    if (value != .string or value.string.len == 0 or !std.unicode.utf8ValidateSlice(value.string) or std.mem.indexOfScalar(u8, value.string, 0) != null) {
        return error.UnsupportedFileChange;
    }
}

fn writePath(writer: *std.Io.Writer, path: []const u8) !void {
    for (path) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '"' or byte == '\\') {
            try writer.print("{f}", .{std.json.fmt(path, .{})});
            return;
        }
    }

    try writer.writeAll(path);
}

fn toolOutput(writer: *std.Io.Writer, output: std.json.Value) !void {
    const content = if (output == .array) output else protocol.field(output, "content");
    if (content == .array) {
        for (content.array.items) |part| {
            const kind = protocol.field(part, "type");
            if (protocol.is(kind, "text") or protocol.is(kind, "inputText")) {
                try writer.print("{s}\n", .{protocol.string(protocol.field(part, "text"))});
            } else {
                try writer.print("[{s} result]\n", .{protocol.string(kind)});
            }
        }
    }

    const structured = protocol.field(output, "structuredContent");
    if (structured != .null) {
        try writer.print("{f}\n", .{std.json.fmt(structured, .{ .whitespace = .indent_2 })});
    }
}

fn dispatchTitle(tool: []const u8) []const u8 {
    const names = .{
        .{ "spawnAgent", "Start agent" },        .{ "sendInput", "Send input" },           .{ "resumeAgent", "Resume agent" },
        .{ "wait", "Wait for agents" },          .{ "closeAgent", "Close agent" },         .{ "sendMessage", "Send message" },
        .{ "followupTask", "Assign follow-up" }, .{ "interruptAgent", "Interrupt agent" }, .{ "listAgents", "List agents" },
    };
    inline for (names) |entry| {
        if (std.mem.eql(u8, tool, entry[0])) {
            return entry[1];
        }
    }

    return tool;
}

fn collaborationDetails(writer: *std.Io.Writer, value: std.json.Value) !void {
    const receivers = protocol.field(value, "receiverThreadIds");
    if (receivers == .array) {
        try writer.writeAll("\nAgents\n");
        for (receivers.array.items) |receiver| {
            try writer.print("{s}\n", .{protocol.string(receiver)});
        }
    }

    const states = protocol.field(value, "agentsStates");
    if (states == .object) {
        var iterator = states.object.iterator();
        while (iterator.next()) |entry| {
            try writer.print("{s}: {s}\n", .{ entry.key_ptr.*, protocol.string(protocol.field(entry.value_ptr.*, "status")) });
            const message = protocol.string(protocol.field(entry.value_ptr.*, "message"));
            if (message.len != 0) {
                try writer.print("{s}\n", .{message});
            }
        }
    }

    const model = protocol.string(protocol.field(value, "model"));
    const effort = protocol.string(protocol.field(value, "reasoningEffort"));
    if (model.len != 0 or effort.len != 0) {
        try writer.print("\nModel: {s}\nReasoning effort: {s}\n", .{ model, effort });
    }
}
