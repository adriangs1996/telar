const jsonl = @import("jsonl");
const std = @import("std");
const core = @import("telar-core");
const ItemUpdate = @import("ItemUpdate.zig");
const ItemNormalizer = @This();

body: [16 * 1024]u8 = undefined,
body_buffer: ?[]u8 = null,
include_history_details: bool = false,
heading: [512]u8 = undefined,
description: [2048]u8 = undefined,

/// Normalizes only public provider item fields. The returned slices borrow this scratch.
/// Example: `if (normalizer.item(value, true)) |update| transcript.update(update);`
pub fn item(self: *ItemNormalizer, value: std.json.Value, complete: bool) ?ItemUpdate {
    const kind = jsonl.field(value, "type");
    var result: ItemUpdate = .{
        .id = jsonl.string(jsonl.field(value, "id")),
        .role = .tool,
        .complete = complete,
        .status = status(jsonl.field(value, "status"), complete),
    };
    var writer: std.Io.Writer = .fixed(self.body_buffer orelse &self.body);
    if (jsonl.is(kind, "agentMessage") or jsonl.is(kind, "plan")) {
        result.role = .assistant;
        result.kind = if (jsonl.is(kind, "plan")) .plan else .message;
        result.title = if (result.kind == .plan) "Plan" else "";
        result.text = jsonl.string(jsonl.field(value, "text"));
        result.phase = if (jsonl.is(jsonl.field(value, "phase"), "commentary")) .commentary else if (jsonl.is(jsonl.field(value, "phase"), "final_answer")) .final_answer else .unknown;
        return result;
    } else if (jsonl.is(kind, "userMessage")) {
        result.role = .user;
        result.kind = .message;
        const content = jsonl.field(value, "content");
        if (content == .array) {
            var image_index: usize = 0;
            for (content.array.items, 0..) |part, index| {
                if (index != 0) {
                    writer.writeByte('\n') catch {
                        result.truncated = true;
                    };
                }

                const part_kind = jsonl.field(part, "type");
                if (jsonl.is(part_kind, "text")) {
                    writer.writeAll(jsonl.string(jsonl.field(part, "text"))) catch {
                        result.truncated = true;
                    };
                } else if (jsonl.is(part_kind, "localImage") or jsonl.is(part_kind, "image")) {
                    image_index += 1;
                    writer.print("[Image {d}]", .{image_index}) catch {
                        result.truncated = true;
                    };
                } else {
                    writer.print("[{s}] {f}", .{ jsonl.string(part_kind), std.json.fmt(part, .{}) }) catch {
                        result.truncated = true;
                    };
                }
            }
        }
    } else if (jsonl.is(kind, "reasoning")) {
        result.role = .assistant;
        result.kind = .reasoning;
        result.title = "Reasoning summary";
        const summary = jsonl.field(value, "summary");
        if (summary == .array) {
            for (summary.array.items) |part| {
                writer.print("{s}\n", .{jsonl.string(part)}) catch {
                    result.truncated = true;
                    break;
                };
            }
        }
    } else if (jsonl.is(kind, "commandExecution")) {
        result.kind = .command;
        result.title = "Command";
        result.detail = std.fmt.bufPrint(&self.description, "{s}\n{s}", .{ jsonl.string(jsonl.field(value, "command")), jsonl.string(jsonl.field(value, "cwd")) }) catch jsonl.string(jsonl.field(value, "command"));
        writer.print("$ {s}\n{s}", .{ jsonl.string(jsonl.field(value, "command")), jsonl.string(jsonl.field(value, "aggregatedOutput")) }) catch {
            result.truncated = true;
        };
        const exit_code = jsonl.field(value, "exitCode");
        if (exit_code == .integer) {
            writer.print("\nExit code: {d}\n", .{exit_code.integer}) catch {
                result.truncated = true;
            };
        }
    } else if (jsonl.is(kind, "fileChange")) {
        result.kind = .file_change;
        result.title = "File changes";
        const changes = jsonl.field(value, "changes");
        result.truncated = changes != .array;
        if (changes == .array) {
            result.truncated = changes.array.items.len == 0;
            result.detail = std.fmt.bufPrint(&self.description, "{d} file(s)", .{changes.array.items.len}) catch "";
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
    } else if (jsonl.is(kind, "mcpToolCall") or jsonl.is(kind, "dynamicToolCall")) {
        result.kind = if (jsonl.is(kind, "mcpToolCall")) .mcp else .dynamic_tool;
        result.title = std.fmt.bufPrint(&self.heading, "{s} · {s}", .{ jsonl.string(jsonl.field(value, if (result.kind == .mcp) "server" else "namespace")), jsonl.string(jsonl.field(value, "tool")) }) catch jsonl.string(jsonl.field(value, "tool"));
        writer.print("Arguments\n{f}\n", .{std.json.fmt(jsonl.field(value, "arguments"), .{ .whitespace = .indent_2 })}) catch {
            result.truncated = true;
        };
        const failure = jsonl.field(value, "error");
        if (failure != .null) {
            result.status = .failed;
            writer.print("Error\n{s}\n", .{jsonl.string(jsonl.field(failure, "message"))}) catch {
                result.truncated = true;
            };
        }

        const output = jsonl.field(value, if (result.kind == .mcp) "result" else "contentItems");
        if (output != .null) {
            toolOutput(&writer, output) catch {
                result.truncated = true;
            };
        }

        if (jsonl.field(value, "success") == .bool and !jsonl.field(value, "success").bool) {
            result.status = .failed;
        }
    } else if (jsonl.is(kind, "webSearch")) {
        result.kind = .web_search;
        result.title = "Web search";
        result.detail = jsonl.string(jsonl.field(value, "query"));
        writer.print("{s}\n{f}\n", .{ jsonl.string(jsonl.field(value, "query")), std.json.fmt(jsonl.field(value, "action"), .{}) }) catch {
            result.truncated = true;
        };
        const results = jsonl.field(value, "results");
        if (results != .null) {
            writer.print("{f}\n", .{std.json.fmt(results, .{})}) catch {
                result.truncated = true;
            };
        }
    } else if (jsonl.is(kind, "collabAgentToolCall")) {
        result.kind = .dispatch;
        result.title = dispatchTitle(jsonl.string(jsonl.field(value, "tool")));
        result.detail = jsonl.string(jsonl.field(value, "prompt"));
        writer.writeAll(jsonl.string(jsonl.field(value, "prompt"))) catch {
            result.truncated = true;
        };
        if (self.include_history_details) {
            collaborationDetails(&writer, value) catch {
                result.truncated = true;
            };
        }
    } else if (jsonl.is(kind, "contextCompaction")) {
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
    if (jsonl.is(value, "failed")) {
        return .failed;
    }
    if (jsonl.is(value, "declined")) {
        return .declined;
    }
    if (jsonl.is(value, "interrupted")) {
        return .interrupted;
    }
    return if (complete or jsonl.is(value, "completed")) .completed else .running;
}

fn fileChange(writer: *std.Io.Writer, change: std.json.Value) !void {
    try knownFields(change, &.{ "path", "kind", "diff" });
    const path = jsonl.field(change, "path");
    const diff = jsonl.field(change, "diff");
    const kind = jsonl.field(change, "kind");
    try validPath(path);
    if (diff != .string or !std.unicode.utf8ValidateSlice(diff.string) or std.mem.indexOfScalar(u8, diff.string, 0) != null) {
        return error.UnsupportedFileChange;
    }

    const change_type = jsonl.field(kind, "type");
    const is_update = jsonl.is(change_type, "update");
    try knownFields(kind, if (is_update) &.{ "type", "move_path" } else &.{"type"});
    const label = if (is_update) "Updated" else if (jsonl.is(change_type, "add")) "Added" else if (jsonl.is(change_type, "delete")) "Deleted" else return error.UnsupportedFileChange;
    const destination = jsonl.field(kind, "move_path");
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
    const content = if (output == .array) output else jsonl.field(output, "content");
    if (content == .array) {
        for (content.array.items) |part| {
            const kind = jsonl.field(part, "type");
            if (jsonl.is(kind, "text") or jsonl.is(kind, "inputText")) {
                try writer.print("{s}\n", .{jsonl.string(jsonl.field(part, "text"))});
            } else {
                try writer.print("[{s} result]\n", .{jsonl.string(kind)});
            }
        }
    }

    const structured = jsonl.field(output, "structuredContent");
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
    const receivers = jsonl.field(value, "receiverThreadIds");
    if (receivers == .array) {
        try writer.writeAll("\nAgents\n");
        for (receivers.array.items) |receiver| {
            try writer.print("{s}\n", .{jsonl.string(receiver)});
        }
    }

    const states = jsonl.field(value, "agentsStates");
    if (states == .object) {
        var iterator = states.object.iterator();
        while (iterator.next()) |entry| {
            try writer.print("{s}: {s}\n", .{ entry.key_ptr.*, jsonl.string(jsonl.field(entry.value_ptr.*, "status")) });
            const message = jsonl.string(jsonl.field(entry.value_ptr.*, "message"));
            if (message.len != 0) {
                try writer.print("{s}\n", .{message});
            }
        }
    }

    const model = jsonl.string(jsonl.field(value, "model"));
    const effort = jsonl.string(jsonl.field(value, "reasoningEffort"));
    if (model.len != 0 or effort.len != 0) {
        try writer.print("\nModel: {s}\nReasoning effort: {s}\n", .{ model, effort });
    }
}
