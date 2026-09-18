const std = @import("std");
const core = @import("telar-core");
const protocol = @import("protocol.zig");
const Transcript = @import("Transcript.zig");
const ChildAgent = @import("ChildAgent.zig");
const ChildEvent = @import("ChildEvent.zig");
const ChildAgents = @This();

root: [128]u8 = undefined,
root_len: u8 = 0,
entries: [16]ChildAgent = undefined,
count: u8 = 0,

/// Example: `children.setRoot(thread_id);`
pub fn setRoot(children: *ChildAgents, id: []const u8) void {
    @memcpy(children.root[0..id.len], id);
    children.root_len = @intCast(id.len);
}

/// Registers explicit parent-side collaboration items after their dispatch row exists.
/// Example: `children.item(&transcript, item);`
pub fn item(children: *ChildAgents, transcript: *Transcript, value: std.json.Value) void {
    const kind = protocol.field(value, "type");
    if (protocol.is(kind, "subAgentActivity")) {
        const path = protocol.string(protocol.field(value, "agentPath"));
        if (std.mem.eql(u8, path, "/root") or std.mem.eql(u8, path, "/")) {
            return;
        }
        const child = children.register(transcript, protocol.string(protocol.field(value, "agentThreadId"))) orelse return;
        setMetadata(child, .{ .name = if (child.name_len == 0) std.fs.path.basename(path) else "", .detail = if (child.detail_len == 0) path else "" });
        const activity = protocol.field(value, "kind");
        if (protocol.is(activity, "started") and child.status == .pending) {
            child.status = .running;
        }
        if (protocol.is(activity, "interrupted") and child.status != .closed) {
            child.status = .interrupted;
        }
        if (protocol.is(activity, "completed") and child.status != .closed) {
            child.status = .idle;
            child.turn_active = false;
        }
        // Merely sending a message to a child does not imply its turn restarted.
        publish(child, transcript, .{ .retain_text = true });
    } else if (protocol.is(kind, "collabAgentToolCall")) {
        const parent = transcript.identity(protocol.string(protocol.field(value, "id"))) orelse 0;
        const receivers = protocol.field(value, "receiverThreadIds");
        if (receivers == .array) {
            for (receivers.array.items) |receiver| {
                const child = children.register(transcript, protocol.string(receiver)) orelse continue;
                if (child.parent_identity == 0) {
                    child.parent_identity = parent;
                }
                const prompt = protocol.string(protocol.field(value, "prompt"));
                const retained = transcript.get(child.row_identity);
                const has_content = child.message_len != 0 or if (retained) |row| row.text_len != 0 else false;
                publish(child, transcript, .{ .text = prompt, .retain_text = prompt.len == 0 or has_content });
            }
        }

        const states = protocol.field(value, "agentsStates");
        if (states == .object) {
            var iterator = states.object.iterator();
            while (iterator.next()) |entry| {
                const child = children.register(transcript, entry.key_ptr.*) orelse continue;
                if (child.parent_identity == 0) {
                    child.parent_identity = parent;
                }
                if (parent < child.last_dispatch_identity or (parent == child.last_dispatch_identity and child.last_dispatch_complete)) {
                    continue;
                }
                child.last_dispatch_identity = parent;
                child.last_dispatch_complete = !protocol.is(protocol.field(value, "status"), "inProgress");
                child.status = agentStatus(protocol.field(entry.value_ptr.*, "status"));
                const message = protocol.string(protocol.field(entry.value_ptr.*, "message"));
                publish(child, transcript, .{ .text = message, .retain_text = message.len == 0 or child.message_len != 0 });
            }
        }
    }
}

/// Intercepts only registered child threads or explicit thread_spawn provenance.
/// Example: `if (children.observe(&transcript, event)) return;`
pub fn observe(children: *ChildAgents, transcript: *Transcript, event: ChildEvent) bool {
    if (std.mem.eql(u8, event.method, "thread/started")) {
        const thread = protocol.field(event.params, "thread");
        const source = protocol.field(protocol.field(protocol.field(thread, "source"), "subAgent"), "thread_spawn");
        const parent = protocol.string(protocol.field(source, "parent_thread_id"));
        if (children.root_len == 0 or source != .object or parent.len == 0) {
            return false;
        }
        if (!std.mem.eql(u8, parent, children.root[0..children.root_len]) and children.find(parent) == null) {
            return false;
        }
        const path = protocol.string(protocol.field(source, "agent_path"));
        if (std.mem.eql(u8, path, "/root") or std.mem.eql(u8, path, "/")) {
            return true;
        }
        const child = children.register(transcript, protocol.string(protocol.field(thread, "id"))) orelse return false;
        const nickname = protocol.string(protocol.field(source, "agent_nickname"));
        var buffer: [1024]u8 = undefined;
        const details = std.fmt.bufPrint(&buffer, "{s}\n{s}", .{ path, protocol.string(protocol.field(source, "agent_role")) }) catch path;
        setMetadata(child, .{ .name = if (nickname.len != 0) nickname else std.fs.path.basename(path), .detail = details });
        publish(child, transcript, .{ .retain_text = true });
        return true;
    }

    const child = children.find(protocol.string(protocol.field(event.params, "threadId"))) orelse return false;
    const turn_id = protocol.string(protocol.field(event.params, "turnId"));
    if (turn_id.len != 0 and child.turn_len != 0 and !std.mem.eql(u8, turn_id, child.turn[0..child.turn_len])) {
        return true;
    }
    if (std.mem.eql(u8, event.method, "turn/started")) {
        const id = protocol.string(protocol.field(protocol.field(event.params, "turn"), "id"));
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
        const turn = protocol.field(event.params, "turn");
        if (!child.turn_active or !protocol.is(protocol.field(turn, "id"), child.turn[0..child.turn_len])) {
            return true;
        }
        child.turn_active = false;
        child.status = if (protocol.is(protocol.field(turn, "status"), "failed")) .failed else if (protocol.is(protocol.field(turn, "status"), "interrupted")) .interrupted else .idle;
        publish(child, transcript, .{ .retain_text = true });
    } else if (std.mem.eql(u8, event.method, "thread/status/changed")) {
        const status = protocol.field(protocol.field(event.params, "status"), "type");
        child.status = if (protocol.is(status, "active")) .running else if (protocol.is(status, "idle")) .idle else if (protocol.is(status, "systemError")) .failed else child.status;
        publish(child, transcript, .{ .retain_text = true });
    } else if (std.mem.eql(u8, event.method, "thread/closed")) {
        child.status = .closed;
        child.turn_active = false;
        publish(child, transcript, .{ .retain_text = true });
    } else if (std.mem.eql(u8, event.method, "item/started") or std.mem.eql(u8, event.method, "item/completed")) {
        const value = protocol.field(event.params, "item");
        if (protocol.is(protocol.field(value, "type"), "agentMessage") and child.turn_active) {
            const id = protocol.string(protocol.field(value, "id"));
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
            publish(child, transcript, .{ .text = protocol.string(protocol.field(value, "text")) });
        } else if (child.turn_active) {
            var normalizer: @import("ItemNormalizer.zig") = .{};
            if (normalizer.item(value, std.mem.eql(u8, event.method, "item/completed"))) |update| {
                const activity = std.fmt.bufPrint(&child.activity, "{s} · {s}\n{s}", .{ update.title orelse "Activity", @tagName(update.status orelse .running), update.detail orelse "" }) catch child.activity[0..];
                child.activity_len = @intCast(activity.len);
                publish(child, transcript, .{ .retain_text = true });
            }
        }
    } else if (std.mem.eql(u8, event.method, "item/agentMessage/delta")) {
        const id = protocol.string(protocol.field(event.params, "itemId"));
        if (!child.turn_active or child.message_complete or id.len == 0 or id.len > child.message.len) {
            return true;
        }
        if (child.message_len != 0 and !std.mem.eql(u8, id, child.message[0..child.message_len])) {
            return true;
        }
        const first = child.message_len == 0;
        @memcpy(child.message[0..id.len], id);
        child.message_len = @intCast(id.len);
        publish(child, transcript, .{ .text = protocol.string(protocol.field(event.params, "delta")), .append = !first });
    }

    return true;
}

fn register(children: *ChildAgents, transcript: *Transcript, id: []const u8) ?*ChildAgent {
    if (id.len == 0 or id.len > 128 or std.mem.indexOfScalar(u8, id, 0) != null or !std.unicode.utf8ValidateSlice(id) or std.mem.eql(u8, id, children.root[0..children.root_len])) {
        return null;
    }
    if (children.find(id)) |child| {
        return child;
    }
    const child = slot: {
        if (children.count < children.entries.len) {
            const entry = &children.entries[children.count];
            children.count += 1;
            break :slot entry;
        }

        for (children.entries[0..children.count]) |*entry| {
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

fn find(children: *ChildAgents, id: []const u8) ?*ChildAgent {
    for (children.entries[0..children.count]) |*child| {
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
    if (protocol.is(value, "running")) {
        return .running;
    }
    if (protocol.is(value, "completed")) {
        return .idle;
    }
    if (protocol.is(value, "interrupted")) {
        return .interrupted;
    }
    if (protocol.is(value, "errored") or protocol.is(value, "notFound")) {
        return .failed;
    }
    if (protocol.is(value, "shutdown")) {
        return .closed;
    }
    return .pending;
}
