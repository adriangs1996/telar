const std = @import("std");
const core = @import("telar-core");
const Codex = @import("Codex.zig");
const Prompt = @import("Prompt.zig");
const protocol = @import("protocol.zig");

fn receive(codex: *Codex, value: anytype) !?[]const u8 {
    var buffer: [8192]u8 = undefined;
    const line = try protocol.encode(&buffer, value);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    return codex.receive(.{ .value = parsed.value });
}

fn ready() !Codex {
    var codex: Codex = .{ .cwd = "/tmp", .transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 } } };
    _ = try codex.initialize();
    _ = try receive(&codex, .{ .id = 1, .result = .{} });
    _ = try receive(&codex, .{ .id = 0, .result = .{ .data = .{.{ .model = "fake-model", .displayName = "Fake model", .supportedReasoningEfforts = .{.{ .reasoningEffort = "low" }}, .defaultReasoningEffort = "low" }} } });
    _ = try receive(&codex, .{ .id = 2, .result = .{ .thread = .{ .id = "root" }, .model = "fake-model", .reasoningEffort = "low", .approvalPolicy = "untrusted", .approvalsReviewer = "user", .sandbox = .{ .type = "workspaceWrite" } } });
    return codex;
}

fn start(codex: *Codex, turn_id: []const u8) !void {
    var prompt: Prompt = .{ .len = 4, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..4], "test");
    _ = try codex.command(.{ .prompt = prompt });
    _ = try receive(codex, .{ .id = codex.pending_turn_request.?, .result = .{ .turn = .{ .id = turn_id } } });
}

fn spawn(codex: *Codex) !void {
    _ = try receive(codex, .{ .method = "item/completed", .params = .{ .threadId = "root", .turnId = codex.transcript.value.currentTurnId(), .item = .{ .id = "dispatch", .type = "collabAgentToolCall", .status = "completed", .tool = "spawnAgent", .receiverThreadIds = .{"child"}, .agentsStates = .{ .child = .{ .status = "running" } } } } });
    _ = try receive(codex, .{ .method = "turn/started", .params = .{ .threadId = "child", .turn = .{ .id = "child-turn-1" } } });
}

fn child(snapshot: *const core.AgentThreadSnapshot, id: []const u8) !*const core.AgentThreadItem {
    for (snapshot.items()) |*item| {
        if (item.kind == .subagent and std.mem.eql(u8, item.reference(snapshot), id)) {
            return item;
        }
    }

    return error.MissingChild;
}

test "Codex adversarial metadata requires an exact known root and never accepts child titles" {
    var codex: Codex = .{ .cwd = "/tmp", .transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 } } };
    _ = try receive(&codex, .{ .method = "thread/name/updated", .params = .{ .threadId = "", .threadName = "Before start" } });
    _ = try receive(&codex, .{ .method = "thread/started", .params = .{ .thread = .{ .id = "root", .name = "Not yet bound" } } });
    try std.testing.expectEqual(0, codex.metadata.revision);
    codex = try ready();
    try start(&codex, "main-turn");
    try spawn(&codex);
    _ = try receive(&codex, .{ .method = "thread/name/updated", .params = .{ .threadId = "root", .threadName = "Root name" } });
    _ = try receive(&codex, .{ .method = "thread/name/updated", .params = .{ .threadName = "No identity" } });
    _ = try receive(&codex, .{ .method = "thread/name/updated", .params = .{ .threadId = "child", .threadName = "Child name" } });
    _ = try receive(&codex, .{ .method = "thread/name/updated", .params = .{ .threadId = "another-root", .threadName = null } });
    _ = try receive(&codex, .{ .method = "thread/started", .params = .{ .thread = .{ .id = "child", .name = "Child title" } } });
    try std.testing.expectEqual(1, codex.metadata.revision);
    try std.testing.expectEqualStrings("Root name", codex.metadata.nameSlice().?);
    try std.testing.expectEqual(core.agent_thread.Status.working, codex.transcript.value.status);
    try std.testing.expectEqualStrings("main-turn", codex.transcript.value.currentTurnId());
}

test "Codex adversarial invalid names do not fail a turn or consume its pending approval" {
    var codex = try ready();
    try start(&codex, "main-turn");
    _ = try receive(&codex, .{ .id = "approval", .method = "item/commandExecution/requestApproval", .params = .{ .threadId = "root", .turnId = "main-turn", .command = "echo hello", .cwd = "/tmp" } });
    const approval = codex.transcript.value.pending_approval.?.id;
    _ = try receive(&codex, .{ .method = "thread/name/updated", .params = .{ .threadId = "root", .threadName = "Root name" } });
    _ = try receive(&codex, .{ .method = "thread/name/updated", .params = .{ .threadId = "root", .threadName = "bad\x00title" } });
    _ = try receive(&codex, .{ .method = "thread/name/updated", .params = .{ .threadId = "root", .threadName = 4 } });
    _ = try receive(&codex, .{ .method = "thread/started", .params = .{ .thread = .{ .id = "root", .name = "bad\ntitle" } } });
    try std.testing.expectEqual(1, codex.metadata.revision);
    try std.testing.expectEqualStrings("Root name", codex.metadata.nameSlice().?);
    try std.testing.expectEqual(approval, codex.transcript.value.pending_approval.?.id);
    try std.testing.expectEqual(core.agent_thread.Status.blocked, codex.transcript.value.status);
}

test "Codex adversarial child completion cannot finish a later main turn" {
    var codex = try ready();
    try start(&codex, "main-turn-1");
    try spawn(&codex);
    const snapshot = &codex.transcript.value;
    const original = (try child(snapshot, "child")).*;
    try std.testing.expectEqual(core.agent_thread.ItemStatus.running, original.status);
    try std.testing.expectEqual(core.agent_thread.ItemStatus.completed, snapshot.findItem(original.parent_identity).?.status);
    _ = try receive(&codex, .{ .method = "turn/completed", .params = .{ .threadId = "root", .turn = .{ .id = "main-turn-1", .status = "completed" } } });
    try std.testing.expectEqual(core.agent_thread.Status.ready, snapshot.status);
    try std.testing.expectEqual(core.agent_thread.ItemStatus.running, (try child(snapshot, "child")).status);
    try start(&codex, "main-turn-2");
    _ = try receive(&codex, .{ .method = "turn/completed", .params = .{ .threadId = "child", .turn = .{ .id = "child-turn-1", .status = "completed" } } });
    try std.testing.expectEqual(core.agent_thread.Status.working, snapshot.status);
    try std.testing.expectEqualStrings("main-turn-2", snapshot.currentTurnId());
    try std.testing.expectEqual(original.identity, (try child(snapshot, "child")).identity);
    try std.testing.expectEqual(core.agent_thread.ItemStatus.idle, (try child(snapshot, "child")).status);
    _ = try receive(&codex, .{ .method = "item/agentMessage/delta", .params = .{ .threadId = "child", .turnId = "child-turn-1", .itemId = "late", .delta = "stale" } });
    try std.testing.expectEqualStrings("", (try child(snapshot, "child")).text(snapshot));
    _ = try receive(&codex, .{ .method = "turn/started", .params = .{ .threadId = "child", .turn = .{ .id = "child-turn-1" } } });
    try std.testing.expectEqual(core.agent_thread.ItemStatus.idle, (try child(snapshot, "child")).status);
}

test "Codex adversarial child deltas stay with their current message identity" {
    var codex = try ready();
    try start(&codex, "main-turn-1");
    try spawn(&codex);
    _ = try receive(&codex, .{ .method = "item/started", .params = .{ .threadId = "child", .turnId = "child-turn-1", .item = .{ .id = "a", .type = "agentMessage", .text = "Commentary" } } });
    _ = try receive(&codex, .{ .method = "item/started", .params = .{ .threadId = "child", .turnId = "child-turn-1", .item = .{ .id = "b", .type = "agentMessage", .text = "Final" } } });
    _ = try receive(&codex, .{ .method = "item/agentMessage/delta", .params = .{ .threadId = "child", .turnId = "child-turn-1", .itemId = "a", .delta = " stale" } });
    _ = try receive(&codex, .{ .method = "item/completed", .params = .{ .threadId = "child", .turnId = "child-turn-1", .item = .{ .id = "a", .type = "agentMessage", .text = "Old completion" } } });
    const snapshot = &codex.transcript.value;
    try std.testing.expectEqualStrings("Final", (try child(snapshot, "child")).text(snapshot));
    _ = try receive(&codex, .{ .method = "item/completed", .params = .{ .threadId = "child", .turnId = "child-turn-1", .item = .{ .id = "b", .type = "agentMessage", .text = "Final answer" } } });
    _ = try receive(&codex, .{ .method = "item/agentMessage/delta", .params = .{ .threadId = "child", .turnId = "child-turn-1", .itemId = "b", .delta = " duplicated" } });
    try std.testing.expectEqualStrings("Final answer", (try child(snapshot, "child")).text(snapshot));
}

test "Codex adversarial child row eviction retires controls without changing its parent turn" {
    var codex = try ready();
    try start(&codex, "main-turn-1");
    try spawn(&codex);
    const snapshot = &codex.transcript.value;
    const original = (try child(snapshot, "child")).*;
    _ = try receive(&codex, .{ .method = "turn/completed", .params = .{ .threadId = "root", .turn = .{ .id = "main-turn-1", .status = "completed" } } });
    try start(&codex, "main-turn-2");
    for (0..core.agent_thread.max_items) |_| {
        codex.transcript.update(.{ .role = .system, .text = "Retained activity", .complete = true });
    }
    try std.testing.expect(snapshot.findItem(original.identity) == null);
    try std.testing.expect(snapshot.findItem(original.parent_identity) == null);
    _ = try receive(&codex, .{ .method = "item/agentMessage/delta", .params = .{ .threadId = "child", .turnId = "child-turn-1", .itemId = "result", .delta = "Still working" } });
    const restored = try child(snapshot, "child");
    try std.testing.expect(restored.identity > original.identity);
    try std.testing.expectEqual(original.parent_identity, restored.parent_identity);
    try std.testing.expectEqual(original.turn_identity, restored.turn_identity);
    try std.testing.expectEqualStrings("Still working", restored.text(snapshot));
    var encoded: [96 * 1024]u8 = undefined;
    _ = try core.decodeServer(try core.encodeAgentThreadSnapshot(&encoded, snapshot));
}

test "Codex adversarial closed child slots admit subsequent agents without losing historical rows" {
    var codex = try ready();
    try start(&codex, "main-turn-1");
    const snapshot = &codex.transcript.value;
    var last_identity: u64 = 0;
    for (0..20) |index| {
        var name: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&name, "child-{d}", .{index});
        _ = try receive(&codex, .{ .method = "item/completed", .params = .{ .threadId = "root", .turnId = "main-turn-1", .item = .{ .id = "dispatch", .type = "collabAgentToolCall", .status = "completed", .tool = "spawnAgent", .receiverThreadIds = .{id} } } });
        const running = try child(snapshot, id);
        try std.testing.expect(running.identity > last_identity);
        last_identity = running.identity;
        _ = try receive(&codex, .{ .method = "thread/closed", .params = .{ .threadId = id } });
        try std.testing.expectEqual(core.agent_thread.ItemStatus.closed, (try child(snapshot, id)).status);
    }
    try std.testing.expectEqual(core.agent_thread.ItemStatus.closed, (try child(snapshot, "child-0")).status);
    try std.testing.expectEqual(core.agent_thread.ItemStatus.closed, (try child(snapshot, "child-19")).status);
}

test "Codex adversarial provider failure resolves active rows and revokes pending approvals" {
    var codex = try ready();
    try start(&codex, "main-turn-1");
    try spawn(&codex);
    _ = try receive(&codex, .{ .id = 42, .method = "item/commandExecution/requestApproval", .params = .{ .threadId = "root", .turnId = "main-turn-1", .itemId = "command", .command = "touch example", .cwd = "/tmp" } });
    const approval_id = codex.transcript.value.pending_approval.?.id;
    codex.fail("Disconnected");
    const snapshot = &codex.transcript.value;
    try std.testing.expectEqual(core.agent_thread.Status.failed, snapshot.status);
    try std.testing.expect(snapshot.pending_approval == null);
    try std.testing.expect(try codex.command(.{ .approval = .{ .id = approval_id, .accepted = true } }) == null);
    for (snapshot.items()) |item| {
        try std.testing.expect(item.status != .running and item.status != .pending);
    }
}

test "Codex adversarial exhausted identities cannot bind child or plan updates to an unrelated row" {
    var codex = try ready();
    try start(&codex, "main-turn-1");
    codex.transcript.next_identity = std.math.maxInt(u64) - 1;
    codex.transcript.update(.{ .id = "last", .role = .system, .text = "Retain this row", .complete = true });
    const snapshot = &codex.transcript.value;
    const identity = std.math.maxInt(u64) - 1;
    const original = snapshot.findItem(identity).?.*;
    try spawn(&codex);
    _ = try receive(&codex, .{ .method = "thread/status/changed", .params = .{ .threadId = "child", .status = .{ .type = "active" } } });
    for (0..2) |_| {
        _ = try receive(&codex, .{ .method = "turn/plan/updated", .params = .{ .threadId = "root", .turnId = "main-turn-1", .plan = .{.{ .step = "Investigate", .status = "inProgress" }} } });
    }
    try std.testing.expectEqual(core.agent_thread.Status.failed, snapshot.status);
    try std.testing.expectEqualDeep(original, snapshot.findItem(identity).?.*);
    try std.testing.expectEqualStrings("Retain this row", snapshot.findItem(identity).?.text(snapshot));
}

test "Codex adversarial stale main start cannot revoke a later pending prompt" {
    var codex = try ready();
    try start(&codex, "main-turn-1");
    _ = try receive(&codex, .{ .method = "turn/completed", .params = .{ .threadId = "root", .turn = .{ .id = "main-turn-1", .status = "completed" } } });
    var prompt: Prompt = .{ .len = 4, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..4], "next");
    _ = try codex.command(.{ .prompt = prompt });
    const request_id = codex.pending_turn_request.?;
    _ = try receive(&codex, .{ .method = "turn/started", .params = .{ .threadId = "root", .turn = .{ .id = "main-turn-1" } } });
    _ = try receive(&codex, .{ .method = "turn/completed", .params = .{ .threadId = "root", .turn = .{ .id = "main-turn-1", .status = "completed" } } });
    try std.testing.expectEqual(request_id, codex.pending_turn_request.?);
    _ = try receive(&codex, .{ .id = request_id, .result = .{ .turn = .{ .id = "main-turn-2" } } });
    const snapshot = &codex.transcript.value;
    try std.testing.expectEqualStrings("main-turn-2", snapshot.currentTurnId());
    try std.testing.expectEqual(core.agent_thread.Status.working, snapshot.status);
    _ = try receive(&codex, .{ .method = "turn/started", .params = .{ .threadId = "root", .turn = .{ .id = "main-turn-1" } } });
    try std.testing.expectEqualStrings("main-turn-2", snapshot.currentTurnId());
}

test "Codex adversarial provider NUL identities cannot poison a shared snapshot" {
    var codex: Codex = .{ .cwd = "/tmp", .transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 1 } } };
    try std.testing.expectError(error.InvalidProviderId, receive(&codex, .{ .id = 2, .result = .{ .thread = .{ .id = "bad\x00id" }, .model = "fake-model", .reasoningEffort = "low", .approvalPolicy = "untrusted", .approvalsReviewer = "user", .sandbox = .{ .type = "workspaceWrite" } } }));
    var encoded: [96 * 1024]u8 = undefined;
    _ = try core.decodeServer(try core.encodeAgentThreadSnapshot(&encoded, &codex.transcript.value));

    codex = try ready();
    var prompt: Prompt = .{ .len = 4, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..4], "test");
    _ = try codex.command(.{ .prompt = prompt });
    try std.testing.expectError(error.InvalidProviderId, receive(&codex, .{ .id = codex.pending_turn_request.?, .result = .{ .turn = .{ .id = "bad\x00turn" } } }));
    _ = try core.decodeServer(try core.encodeAgentThreadSnapshot(&encoded, &codex.transcript.value));
}

test "Codex adversarial source before dispatch receives task without overwriting child replies" {
    var codex = try ready();
    try start(&codex, "main-turn-1");
    _ = try receive(&codex, .{ .method = "thread/started", .params = .{ .thread = .{ .id = "child", .source = .{ .subAgent = .{ .thread_spawn = .{ .parent_thread_id = "root", .agent_path = "/root/review", .agent_nickname = "Reviewer", .agent_role = "explorer" } } } } } });
    const snapshot = &codex.transcript.value;
    const original_identity = (try child(snapshot, "child")).identity;
    try std.testing.expectEqualStrings("", (try child(snapshot, "child")).text(snapshot));
    _ = try receive(&codex, .{ .method = "item/started", .params = .{ .threadId = "root", .turnId = "main-turn-1", .item = .{ .id = "dispatch", .type = "collabAgentToolCall", .status = "inProgress", .tool = "spawnAgent", .prompt = "Review the parser", .receiverThreadIds = .{"child"}, .agentsStates = .{ .child = .{ .status = "running", .message = null } } } } });
    try std.testing.expectEqual(original_identity, (try child(snapshot, "child")).identity);
    try std.testing.expectEqualStrings("Review the parser", (try child(snapshot, "child")).text(snapshot));
    try std.testing.expectEqualStrings("Reviewer", (try child(snapshot, "child")).title(snapshot));
    try std.testing.expect((try child(snapshot, "child")).parent_identity != 0);
    _ = try receive(&codex, .{ .method = "turn/started", .params = .{ .threadId = "child", .turn = .{ .id = "child-turn-1" } } });
    _ = try receive(&codex, .{ .method = "item/agentMessage/delta", .params = .{ .threadId = "child", .turnId = "child-turn-1", .itemId = "reply", .delta = "Checking bounds" } });
    _ = try receive(&codex, .{ .method = "item/completed", .params = .{ .threadId = "root", .turnId = "main-turn-1", .item = .{ .id = "dispatch", .type = "collabAgentToolCall", .status = "completed", .tool = "spawnAgent", .prompt = "Review the parser", .receiverThreadIds = .{"child"}, .agentsStates = .{ .child = .{ .status = "running", .message = "Old dispatch summary" } } } } });
    try std.testing.expectEqualStrings("Checking bounds", (try child(snapshot, "child")).text(snapshot));
    _ = try receive(&codex, .{ .method = "item/agentMessage/delta", .params = .{ .threadId = "child", .turnId = "child-turn-1", .itemId = "reply", .delta = " carefully" } });
    try std.testing.expectEqualStrings("Checking bounds carefully", (try child(snapshot, "child")).text(snapshot));
    _ = try receive(&codex, .{ .method = "item/completed", .params = .{ .threadId = "child", .turnId = "child-turn-1", .item = .{ .id = "reply", .type = "agentMessage", .text = "Bounds are correct" } } });
    _ = try receive(&codex, .{ .method = "item/completed", .params = .{ .threadId = "root", .turnId = "main-turn-1", .item = .{ .id = "late-dispatch", .type = "collabAgentToolCall", .status = "completed", .tool = "wait", .prompt = "Older task", .receiverThreadIds = .{"child"}, .agentsStates = .{ .child = .{ .status = "completed", .message = "Older result" } } } } });
    try std.testing.expectEqualStrings("Bounds are correct", (try child(snapshot, "child")).text(snapshot));
}
