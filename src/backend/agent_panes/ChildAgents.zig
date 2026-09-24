const jsonl = @import("jsonl");
const std = @import("std");
const core = @import("telar-core");
const Transcript = @import("Transcript.zig");
const ChildAgent = @import("ChildAgent.zig");
const ChildEvent = @import("ChildEvent.zig");
const ItemNormalizer = @import("ItemNormalizer.zig");
const ChildAgents = @This();

root: [128]u8 = undefined,
root_len: u8 = 0,
entries: [16]ChildAgent = undefined,
count: u8 = 0,

/// Example: `children.setRoot(thread_id);`
pub fn setRoot(self: *ChildAgents, id: []const u8) void {
    @memcpy(self.root[0..id.len], id);
    self.root_len = @intCast(id.len);
}

/// Registers explicit parent-side collaboration items after their dispatch row exists.
/// Example: `children.item(&transcript, item);`
pub fn item(self: *ChildAgents, transcript: *Transcript, value: std.json.Value) void {
    const kind = jsonl.field(value, "type");
    if (jsonl.is(kind, "subAgentActivity")) {
        const path = jsonl.string(jsonl.field(value, "agentPath"));
        if (std.mem.eql(u8, path, "/root") or std.mem.eql(u8, path, "/")) {
            return;
        }
        const child = self.register(transcript, jsonl.string(jsonl.field(value, "agentThreadId"))) orelse return;
        setMetadata(child, .{ .name = if (child.name_len == 0) std.fs.path.basename(path) else "", .detail = if (child.detail_len == 0) path else "" });
        const activity = jsonl.field(value, "kind");
        if (jsonl.is(activity, "started") and child.status == .pending) {
            child.status = .running;
        }
        if (jsonl.is(activity, "interrupted") and child.status != .closed) {
            child.status = .interrupted;
        }
        if (jsonl.is(activity, "completed") and child.status != .closed) {
            child.status = .idle;
            child.turn_active = false;
        }
        // Merely sending a message to a child does not imply its turn restarted.
        publish(child, transcript, .{ .retain_text = true });
    } else if (jsonl.is(kind, "collabAgentToolCall")) {
        const parent = transcript.identity(jsonl.string(jsonl.field(value, "id"))) orelse 0;
        const receivers = jsonl.field(value, "receiverThreadIds");
        if (receivers == .array) {
            for (receivers.array.items) |receiver| {
                const child = self.register(transcript, jsonl.string(receiver)) orelse continue;
                if (child.parent_identity == 0) {
                    child.parent_identity = parent;
                }
                const prompt = jsonl.string(jsonl.field(value, "prompt"));
                const retained = transcript.get(child.row_identity);
                const has_content = child.message_len != 0 or if (retained) |row| row.text_len != 0 else false;
                publish(child, transcript, .{ .text = prompt, .retain_text = prompt.len == 0 or has_content });
            }
        }

        const states = jsonl.field(value, "agentsStates");
        if (states == .object) {
            var iterator = states.object.iterator();
            while (iterator.next()) |entry| {
                const child = self.register(transcript, entry.key_ptr.*) orelse continue;
                if (child.parent_identity == 0) {
                    child.parent_identity = parent;
                }
                if (parent < child.last_dispatch_identity or (parent == child.last_dispatch_identity and child.last_dispatch_complete)) {
                    continue;
                }
                child.last_dispatch_identity = parent;
                child.last_dispatch_complete = !jsonl.is(jsonl.field(value, "status"), "inProgress");
                child.status = agentStatus(jsonl.field(entry.value_ptr.*, "status"));
                const message = jsonl.string(jsonl.field(entry.value_ptr.*, "message"));
                publish(child, transcript, .{ .text = message, .retain_text = message.len == 0 or child.message_len != 0 });
            }
        }
    }
}

/// Intercepts only registered child threads or explicit thread_spawn provenance.
/// Example: `if (children.observe(&transcript, event)) return;`
pub fn observe(self: *ChildAgents, transcript: *Transcript, event: ChildEvent) bool {
    if (std.mem.eql(u8, event.method, "thread/started")) {
        const thread = jsonl.field(event.params, "thread");
        const source = jsonl.field(jsonl.field(jsonl.field(thread, "source"), "subAgent"), "thread_spawn");
        const parent = jsonl.string(jsonl.field(source, "parent_thread_id"));
        if (self.root_len == 0 or source != .object or parent.len == 0) {
            return false;
        }
        if (!std.mem.eql(u8, parent, self.root[0..self.root_len]) and self.find(parent) == null) {
            return false;
        }
        const path = jsonl.string(jsonl.field(source, "agent_path"));
        if (std.mem.eql(u8, path, "/root") or std.mem.eql(u8, path, "/")) {
            return true;
        }
        const child = self.register(transcript, jsonl.string(jsonl.field(thread, "id"))) orelse return false;
        const nickname = jsonl.string(jsonl.field(source, "agent_nickname"));
        var buffer: [1024]u8 = undefined;
        const details = std.fmt.bufPrint(&buffer, "{s}\n{s}", .{ path, jsonl.string(jsonl.field(source, "agent_role")) }) catch path;
        setMetadata(child, .{ .name = if (nickname.len != 0) nickname else std.fs.path.basename(path), .detail = details });
        publish(child, transcript, .{ .retain_text = true });
        return true;
    }

    const child = self.find(jsonl.string(jsonl.field(event.params, "threadId"))) orelse return false;
    const turn_id = jsonl.string(jsonl.field(event.params, "turnId"));
    if (turn_id.len != 0 and child.turn_len != 0 and !std.mem.eql(u8, turn_id, child.turn[0..child.turn_len])) {
        return true;
    }
    if (std.mem.eql(u8, event.method, "turn/started")) {
        const id = jsonl.string(jsonl.field(jsonl.field(event.params, "turn"), "id"));
        if (id.len == 0 or id.len > child.turn.len) {
            transcript.value.truncated = true;
            return true;
        }
        if (child.status == .closed or std.mem.eql(u8, id, child.turn[0..child.turn_len])) {
            return true;
        }
        @memcpy(child.turn[0..id.len], id);
        child.turn_len = @intCast(id.len);
        child.turn_active = true;
        child.message_len = 0;
        child.activity_len = 0;
        child.message_complete = false;
        child.status = .running;
        publish(child, transcript, .{ .retain_text = true });
    } else if (std.mem.eql(u8, event.method, "turn/completed")) {
        const turn = jsonl.field(event.params, "turn");
        if (!child.turn_active or !jsonl.is(jsonl.field(turn, "id"), child.turn[0..child.turn_len])) {
            return true;
        }
        child.turn_active = false;
        child.status = if (jsonl.is(jsonl.field(turn, "status"), "failed")) .failed else if (jsonl.is(jsonl.field(turn, "status"), "interrupted")) .interrupted else .idle;
        publish(child, transcript, .{ .retain_text = true });
    } else if (std.mem.eql(u8, event.method, "thread/status/changed")) {
        const status = jsonl.field(jsonl.field(event.params, "status"), "type");
        child.status = if (jsonl.is(status, "active")) .running else if (jsonl.is(status, "idle")) .idle else if (jsonl.is(status, "systemError")) .failed else child.status;
        publish(child, transcript, .{ .retain_text = true });
    } else if (std.mem.eql(u8, event.method, "thread/closed")) {
        child.status = .closed;
        child.turn_active = false;
        publish(child, transcript, .{ .retain_text = true });
    } else if (std.mem.eql(u8, event.method, "item/started") or std.mem.eql(u8, event.method, "item/completed")) {
        const value = jsonl.field(event.params, "item");
        if (jsonl.is(jsonl.field(value, "type"), "agentMessage") and child.turn_active) {
            const id = jsonl.string(jsonl.field(value, "id"));
            const completed = std.mem.eql(u8, event.method, "item/completed");
            if (id.len == 0 or id.len > child.message.len) {
                return true;
            }
            if (completed and child.message_len != 0 and !std.mem.eql(u8, id, child.message[0..child.message_len])) {
                return true;
            }
            @memcpy(child.message[0..id.len], id);
            child.message_len = @intCast(id.len);
            child.message_complete = completed;
            publish(child, transcript, .{ .text = jsonl.string(jsonl.field(value, "text")) });
        } else if (child.turn_active) {
            var normalizer: ItemNormalizer = .{};
            if (normalizer.item(value, std.mem.eql(u8, event.method, "item/completed"))) |update| {
                const activity = std.fmt.bufPrint(&child.activity, "{s} · {s}\n{s}", .{ update.title orelse "Activity", @tagName(update.status orelse .running), update.detail orelse "" }) catch child.activity[0..];
                child.activity_len = @intCast(activity.len);
                publish(child, transcript, .{ .retain_text = true });
            }
        }
    } else if (std.mem.eql(u8, event.method, "item/agentMessage/delta")) {
        const id = jsonl.string(jsonl.field(event.params, "itemId"));
        if (!child.turn_active or child.message_complete or id.len == 0 or id.len > child.message.len) {
            return true;
        }
        if (child.message_len != 0 and !std.mem.eql(u8, id, child.message[0..child.message_len])) {
            return true;
        }
        const first = child.message_len == 0;
        @memcpy(child.message[0..id.len], id);
        child.message_len = @intCast(id.len);
        publish(child, transcript, .{ .text = jsonl.string(jsonl.field(event.params, "delta")), .append = !first });
    }

    return true;
}

fn register(self: *ChildAgents, transcript: *Transcript, id: []const u8) ?*ChildAgent {
    if (id.len == 0 or id.len > 128 or std.mem.indexOfScalar(u8, id, 0) != null or !std.unicode.utf8ValidateSlice(id) or std.mem.eql(u8, id, self.root[0..self.root_len])) {
        return null;
    }
    if (self.find(id)) |child| {
        return child;
    }
    const child = slot: {
        if (self.count < self.entries.len) {
            const entry = &self.entries[self.count];
            self.count += 1;
            break :slot entry;
        }

        for (self.entries[0..self.count]) |*entry| {
            if (entry.status == .closed) {
                break :slot entry;
            }
        }

        transcript.value.truncated = true;
        return null;
    };
    child.* = .{ .turn_identity = transcript.turn_identity };
    @memcpy(child.id[0..id.len], id);
    child.id_len = @intCast(id.len);
    return child;
}

fn find(self: *ChildAgents, id: []const u8) ?*ChildAgent {
    for (self.entries[0..self.count]) |*child| {
        if (std.mem.eql(u8, id, child.id[0..child.id_len])) {
            return child;
        }
    }

    return null;
}

fn setMetadata(child: *ChildAgent, metadata: struct { name: []const u8, detail: []const u8 }) void {
    if (metadata.name.len != 0) {
        child.name_len = @intCast(@min(metadata.name.len, child.name.len));
        @memcpy(child.name[0..child.name_len], metadata.name[0..child.name_len]);
    }

    if (metadata.detail.len != 0) {
        child.detail_len = @intCast(@min(metadata.detail.len, child.detail.len));
        @memcpy(child.detail[0..child.detail_len], metadata.detail[0..child.detail_len]);
    }
}

fn publish(child: *ChildAgent, transcript: *Transcript, content: struct { text: []const u8 = "", retain_text: bool = false, append: bool = false }) void {
    const retained = transcript.get(child.row_identity) != null;
    const next_identity = transcript.next_identity;
    var detail_buffer: [1281]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buffer, "{s}\n{s}", .{ child.activity[0..child.activity_len], child.detail[0..child.detail_len] }) catch unreachable;
    transcript.update(.{
        .identity = child.row_identity,
        .role = .tool,
        .kind = .subagent,
        .status = child.status,
        .parent_identity = child.parent_identity,
        .turn_identity = child.turn_identity,
        .title = if (child.name_len == 0) "Agent" else child.name[0..child.name_len],
        .detail = std.mem.trimStart(u8, detail, "\n"),
        .reference = child.id[0..child.id_len],
        .text = content.text,
        .retain_text = content.retain_text,
        .append = content.append,
        .complete = child.status != .running and child.status != .pending,
    });
    if (!retained) {
        child.row_identity = if (transcript.get(next_identity) != null) next_identity else 0;
    }
}

fn agentStatus(value: std.json.Value) core.agent_thread.ItemStatus {
    if (jsonl.is(value, "running")) {
        return .running;
    }
    if (jsonl.is(value, "completed")) {
        return .idle;
    }
    if (jsonl.is(value, "interrupted")) {
        return .interrupted;
    }
    if (jsonl.is(value, "errored") or jsonl.is(value, "notFound")) {
        return .failed;
    }
    if (jsonl.is(value, "shutdown")) {
        return .closed;
    }
    return .pending;
}
