const std = @import("std");
const core = @import("telar-core");
const Codex = @import("Codex.zig");
const Prompt = @import("Prompt.zig");

fn init() Codex {
    return .{ .cwd = "/tmp", .transcript = .{ .value = .{ .pane_id = @enumFromInt(3), .pane_generation = 7 } } };
}

fn receive(codex: *Codex, line: []const u8) !?[]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    return codex.receive(.{ .value = parsed.value });
}

fn ready(codex: *Codex) !void {
    _ = try codex.initialize();
    _ = try receive(codex, "{\"id\":1,\"result\":{}} ");
    _ = try receive(codex, "{\"id\":0,\"result\":{\"data\":[{\"model\":\"fake-model\",\"displayName\":\"Fake model\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"},{\"reasoningEffort\":\"ultra\"}],\"defaultReasoningEffort\":\"low\"}]}}");
    _ = try receive(codex, "{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"},\"model\":\"fake-model\",\"reasoningEffort\":\"low\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}");
}

fn working(codex: *Codex) !void {
    try ready(codex);
    var prompt: Prompt = .{ .len = 4, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..4], "test");
    _ = try codex.command(.{ .prompt = prompt });
    _ = try receive(codex, "{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}");
}

test "Codex owns an optional thread start name independently from its preview" {
    var codex = init();
    _ = try receive(&codex, "{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\",\"name\":\"Review input ownership\",\"preview\":\"First user prompt\"},\"model\":\"fake-model\",\"reasoningEffort\":\"low\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}");
    try std.testing.expectEqualStrings("Review input ownership", codex.metadata.nameSlice().?);
    try std.testing.expectEqual(1, codex.metadata.revision);
    var unnamed = init();
    try ready(&unnamed);
    try std.testing.expect(unnamed.metadata.nameSlice() == null);
    try std.testing.expectEqual(0, unnamed.metadata.revision);
}

test "Codex root thread name events distinguish omission clear and duplicate updates" {
    var codex = init();
    try ready(&codex);
    _ = try receive(&codex, "{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"thread-1\",\"name\":\"First name\"}}}");
    try std.testing.expectEqualStrings("First name", codex.metadata.nameSlice().?);
    _ = try receive(&codex, "{\"method\":\"thread/name/updated\",\"params\":{\"threadId\":\"thread-1\",\"threadName\":\"Second name\"}}");
    try std.testing.expectEqualStrings("Second name", codex.metadata.nameSlice().?);
    try std.testing.expectEqual(2, codex.metadata.revision);
    _ = try receive(&codex, "{\"method\":\"thread/name/updated\",\"params\":{\"threadId\":\"thread-1\",\"threadName\":\"Second name\"}}");
    _ = try receive(&codex, "{\"method\":\"thread/name/updated\",\"params\":{\"threadId\":\"thread-1\"}}");
    _ = try receive(&codex, "{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"thread-1\"}}}");
    try std.testing.expectEqual(2, codex.metadata.revision);
    _ = try receive(&codex, "{\"method\":\"thread/name/updated\",\"params\":{\"threadId\":\"thread-1\",\"threadName\":null}}");
    try std.testing.expectEqualStrings("", codex.metadata.nameSlice().?);
    try std.testing.expectEqual(3, codex.metadata.revision);
    try std.testing.expectEqual(core.agent_thread.Status.ready, codex.transcript.value.status);
}

test "Codex initializes before creating a thread with explicit user approvals" {
    var codex = init();
    const initialize = try codex.initialize();
    try std.testing.expect(std.mem.indexOf(u8, initialize, "initialize") != null);
    try std.testing.expect(std.mem.indexOf(u8, initialize, "\"experimentalApi\":true") != null);
    const next = (try receive(&codex, "{\"id\":1,\"result\":{}} ")).?;
    try std.testing.expect(std.mem.startsWith(u8, next, "{\"method\":\"initialized\"}\n"));
    try std.testing.expect(std.mem.indexOf(u8, next, "\"approvalPolicy\":\"untrusted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "\"approvalsReviewer\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "\"sandbox\":\"workspace-write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "\"historyMode\":\"paginated\"") != null);
    _ = try receive(&codex, "{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"},\"model\":\"fake-model\",\"reasoningEffort\":\"low\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}");
    try std.testing.expectEqual(core.agent_thread.Status.starting, codex.transcript.value.status);
    _ = try receive(&codex, "{\"id\":0,\"result\":{\"data\":[{\"model\":\"fake-model\",\"displayName\":\"Fake model\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"},{\"reasoningEffort\":\"ultra\"}],\"defaultReasoningEffort\":\"low\"}]}}");
    try std.testing.expectEqual(core.agent_thread.Status.ready, codex.transcript.value.status);
}

test "Codex official user item attaches its source identity to the accepted prompt" {
    var codex = init();
    try working(&codex);
    const identity = codex.transcript.value.items()[0].identity;
    const message = "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"user-message-1\",\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"test\"}]}}}";
    _ = try receive(&codex, message);
    _ = try receive(&codex, message);
    try std.testing.expectEqual(@as(u8, 1), codex.transcript.value.item_count);
    try std.testing.expectEqual(identity, codex.transcript.value.items()[0].identity);
    try std.testing.expectEqualStrings("user-message-1", codex.transcript.value.items()[0].sourceId(&codex.transcript.value));
    try std.testing.expectEqualStrings("turn-1", codex.transcript.value.items()[0].sourceTurn(&codex.transcript.value));
    try std.testing.expectEqualStrings("test", codex.transcript.value.items()[0].text(&codex.transcript.value));
}

test "Codex reused assistant IDs in a second turn preserve the first reply" {
    var codex = init();
    try working(&codex);
    _ = try receive(&codex, "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"same\",\"type\":\"agentMessage\",\"text\":\"First reply\"}}}");
    _ = try receive(&codex, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-1\",\"turn\":{\"id\":\"turn-1\",\"status\":\"completed\"}}}");
    var prompt: Prompt = .{ .len = 4, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..4], "next");
    _ = try codex.command(.{ .prompt = prompt });
    _ = try receive(&codex, "{\"id\":4,\"result\":{\"turn\":{\"id\":\"turn-2\"}}}");
    _ = try receive(&codex, "{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-2\",\"itemId\":\"same\",\"delta\":\"Second reply\"}}");
    try std.testing.expectEqual(@as(u8, 4), codex.transcript.value.item_count);
    try std.testing.expectEqualStrings("First reply", codex.transcript.value.items()[1].text(&codex.transcript.value));
    try std.testing.expectEqualStrings("Second reply", codex.transcript.value.items()[3].text(&codex.transcript.value));
    try std.testing.expectEqualStrings("turn-1", codex.transcript.value.items()[1].sourceTurn(&codex.transcript.value));
    try std.testing.expectEqualStrings("turn-2", codex.transcript.value.items()[3].sourceTurn(&codex.transcript.value));
}

test "Codex approval requires matching explicit decision and preserves string RPC identity" {
    var codex = init();
    try working(&codex);
    const request = "{\"id\":\"approval-42\",\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"tool-1\",\"command\":\"touch example\",\"cwd\":\"/tmp\",\"reason\":\"Write a file\"}}";
    try std.testing.expect(try receive(&codex, request) == null);
    try std.testing.expectEqual(core.agent_thread.Status.blocked, codex.transcript.value.status);
    const approval = codex.transcript.value.pending_approval.?;
    try std.testing.expect(std.mem.indexOf(u8, approval.text(), "touch example") != null);
    try std.testing.expect(try codex.command(.{ .approval = .{ .id = approval.id + 1, .accepted = true } }) == null);
    try std.testing.expectEqualStrings("{\"id\":\"approval-42\",\"result\":{\"decision\":\"accept\"}}\n", (try codex.command(.{ .approval = .{ .id = approval.id, .accepted = true } })).?);
    try std.testing.expect(codex.transcript.value.pending_approval == null);
    try std.testing.expect(try codex.command(.{ .approval = .{ .id = approval.id, .accepted = true } }) == null);
}

test "Codex stale approval is declined and completed turn revokes every approval" {
    var codex = init();
    try working(&codex);
    const stale = "{\"id\":9,\"method\":\"item/fileChange/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"old-turn\"}}";
    try std.testing.expectEqualStrings("{\"id\":9,\"result\":{\"decision\":\"decline\"}}\n", (try receive(&codex, stale)).?);
    codex.transcript.update(.{ .id = "file-1", .role = .tool, .text = "example.zig\n+const answer = 42;" });
    _ = try receive(&codex, "{\"id\":10,\"method\":\"item/fileChange/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"file-1\",\"reason\":\"Changes\"}}");
    const id = codex.transcript.value.pending_approval.?.id;
    _ = try receive(&codex, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-1\",\"turn\":{\"id\":\"turn-1\",\"status\":\"interrupted\"}}}");
    try std.testing.expect(codex.transcript.value.pending_approval == null);
    try std.testing.expect(try codex.command(.{ .approval = .{ .id = id, .accepted = true } }) == null);
    try std.testing.expectEqual(core.agent_thread.Status.ready, codex.transcript.value.status);
}

test "Codex turn failure keeps the submitted user message and a visible error" {
    var codex = init();
    try ready(&codex);
    var prompt: Prompt = .{ .len = 5, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..5], "hello");
    _ = try codex.command(.{ .prompt = prompt });
    _ = try receive(&codex, "{\"id\":3,\"error\":{\"code\":-1,\"message\":\"Sign in required\"}}");
    try std.testing.expectEqualStrings("hello", codex.transcript.value.items()[0].text(&codex.transcript.value));
    try std.testing.expectEqualStrings("Sign in required", codex.transcript.value.items()[1].text(&codex.transcript.value));
    try std.testing.expectEqual(core.agent_thread.Status.ready, codex.transcript.value.status);
}

test "Codex deltas stay scoped to thread and completion replaces assistant text" {
    var codex = init();
    try working(&codex);
    _ = try receive(&codex, "{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"other\",\"itemId\":\"a\",\"delta\":\"hidden\"}}");
    _ = try receive(&codex, "{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"itemId\":\"a\",\"delta\":\"Hi\"}}");
    _ = try receive(&codex, "{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"itemId\":\"a\",\"delta\":\" there\"}}");
    try std.testing.expectEqualStrings("Hi there", codex.transcript.value.items()[1].text(&codex.transcript.value));
    _ = try receive(&codex, "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"item\":{\"id\":\"a\",\"type\":\"agentMessage\",\"text\":\"Final\"}}}");
    try std.testing.expectEqualStrings("Final", codex.transcript.value.items()[1].text(&codex.transcript.value));
    try std.testing.expect(codex.transcript.value.items()[1].complete);
}

test "Codex unsupported server requests receive explicit errors without authorization" {
    var codex = init();
    try working(&codex);
    const reply = (try receive(&codex, "{\"id\":99,\"method\":\"item/permissions/requestApproval\",\"params\":{}}")).?;
    try std.testing.expect(std.mem.indexOf(u8, reply, "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "accept") == null);
}

test "Codex interrupts a turn even when requested before the start acknowledgement" {
    var codex = init();
    try ready(&codex);
    var prompt: Prompt = .{ .len = 4, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..4], "test");
    _ = try codex.command(.{ .prompt = prompt });
    try std.testing.expect(try codex.command(.interrupt) == null);
    const interrupt = (try receive(&codex, "{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}")).?;
    try std.testing.expect(std.mem.indexOf(u8, interrupt, "\"method\":\"turn/interrupt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, interrupt, "\"turnId\":\"turn-1\"") != null);
    try std.testing.expect(!codex.interrupt_pending);
}

test "Codex rejects invalid envelopes and never consumes stale turn deltas" {
    var codex = init();
    try working(&codex);
    _ = try receive(&codex, "{\"method\":\"item/agentMessage/delta\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"old\",\"itemId\":\"a\",\"delta\":\"stale\"}}");
    try std.testing.expectEqual(@as(u8, 1), codex.transcript.value.item_count);
    try std.testing.expectError(error.InvalidProviderFrame, receive(&codex, "[]"));
    try std.testing.expectError(error.InvalidProviderFrame, receive(&codex, "{\"id\":null}"));
}

test "Codex preserves multiline prompts as one escaped JSONL request" {
    var codex = init();
    try ready(&codex);
    const message = "Explain \"this\"\nThen implement it.\nSeñal";
    var prompt: Prompt = .{ .len = message.len, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..message.len], message);
    const line = (try codex.command(.{ .prompt = prompt })).?;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const input = parsed.value.object.get("params").?.object.get("input").?.array.items[0];
    try std.testing.expectEqualStrings(message, input.object.get("text").?.string);
}

test "Codex catalog retains arbitrary efforts and the effective configured default" {
    var codex = init();
    _ = try codex.initialize();
    _ = try receive(&codex, "{\"id\":1,\"result\":{}}");
    _ = try receive(&codex, "{\"id\":0,\"result\":{\"data\":[{\"id\":\"opaque-id\",\"model\":\"future-model\",\"displayName\":\"Future model\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"},{\"reasoningEffort\":\"future-effort\"}],\"defaultReasoningEffort\":\"low\"}]}}");
    try std.testing.expectEqual(core.agent_thread.Status.starting, codex.transcript.value.status);
    _ = try receive(&codex, "{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"},\"model\":\"future-model\",\"reasoningEffort\":\"future-effort\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}");
    const snapshot = &codex.transcript.value;
    try std.testing.expectEqualStrings("future-model", snapshot.options.modelSlice());
    try std.testing.expectEqualStrings("future-effort", snapshot.options.effort.idSlice());
    try std.testing.expectEqualStrings("low", snapshot.models()[0].default_effort.idSlice());
    try std.testing.expect(snapshot.accepts(snapshot.options));
}

test "Codex sends complete settings on every turn and lowers access after full access" {
    var codex = init();
    try ready(&codex);
    var prompt: Prompt = .{ .len = 4, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..4], "test");
    prompt.options.effort = try core.AgentEffort.init("ultra");
    for ([_]core.AgentAccess{ .full_access, .workspace, .read_only }, 0..) |access, index| {
        prompt.options.access = access;
        const previous = codex.transcript.value.options;
        const line = (try codex.command(.{ .prompt = prompt })).?;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params").?.object;
        try std.testing.expectEqualStrings("fake-model", params.get("model").?.string);
        try std.testing.expectEqualStrings("ultra", params.get("effort").?.string);
        try std.testing.expectEqualStrings("user", params.get("approvalsReviewer").?.string);
        try std.testing.expectEqualStrings(if (access == .full_access) "never" else "untrusted", params.get("approvalPolicy").?.string);
        const sandbox = params.get("sandboxPolicy").?.object;
        const expected_type: []const u8 = switch (access) {
            .full_access => "dangerFullAccess",
            .workspace => "workspaceWrite",
            .read_only => "readOnly",
        };
        try std.testing.expectEqualStrings(expected_type, sandbox.get("type").?.string);
        if (access != .full_access) {
            try std.testing.expect(!sandbox.get("networkAccess").?.bool);
        }

        if (access == .workspace) {
            try std.testing.expectEqual(@as(usize, 0), sandbox.get("writableRoots").?.array.items.len);
        }

        try std.testing.expect(codex.transcript.value.options.eql(previous));
        var response: [128]u8 = undefined;
        _ = try receive(&codex, try std.fmt.bufPrint(&response, "{{\"id\":{d},\"result\":{{\"turn\":{{\"id\":\"turn-1\"}}}}}}", .{3 + index}));
        try std.testing.expect(codex.transcript.value.options.eql(prompt.options));
        _ = try receive(&codex, "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-1\",\"turn\":{\"id\":\"turn-1\",\"status\":\"completed\"}}}");
    }
}

test "Codex rejects unknown models and preserves effective settings when a turn is rejected" {
    var codex = init();
    try ready(&codex);
    const original = codex.transcript.value.options;
    var prompt: Prompt = .{ .len = 4, .options = original };
    @memcpy(prompt.bytes[0..4], "test");
    try prompt.options.setModel("unknown");
    try std.testing.expect(try codex.command(.{ .prompt = prompt }) == null);
    try std.testing.expectEqual(core.agent_thread.Status.ready, codex.transcript.value.status);
    prompt.options = original;
    prompt.options.effort = try core.AgentEffort.init("ultra");
    _ = try codex.command(.{ .prompt = prompt });
    _ = try receive(&codex, "{\"id\":3,\"error\":{\"code\":-1,\"message\":\"Model unavailable\"}}");
    try std.testing.expect(codex.transcript.value.options.eql(original));
    try std.testing.expect(codex.pending_options == null);
    try std.testing.expectEqualStrings("test", codex.transcript.value.items()[2].text(&codex.transcript.value));
}

test "Codex catalog bounds fail explicitly and an unmarked catalog supplies its first available model" {
    var codex = init();
    try std.testing.expectError(error.InvalidProviderModelCatalog, receive(&codex, "{\"id\":0,\"result\":{\"data\":[]}}"));
    try std.testing.expectError(error.InvalidProviderModelCatalog, receive(&codex, "{\"id\":0,\"result\":{\"data\":[{\"model\":\"fake-model\",\"displayName\":\"Fake\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"}],\"defaultReasoningEffort\":\"missing\"}]}}"));
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.writeAll("{\"id\":0,\"result\":{\"data\":[");
    for (0..core.agent_thread.max_models + 1) |index| {
        if (index != 0) {
            try writer.writeByte(',');
        }

        try writer.writeAll("{\"model\":\"model\",\"displayName\":\"Model\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"}],\"defaultReasoningEffort\":\"low\"}");
    }

    try writer.writeAll("]}}");
    try std.testing.expectError(error.InvalidProviderModelCatalog, receive(&codex, writer.buffered()));
    _ = try receive(&codex, "{\"id\":0,\"result\":{\"data\":[{\"model\":\"fake-model\",\"displayName\":\"Fake\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"}],\"defaultReasoningEffort\":\"low\"}]}}");
    _ = try receive(&codex, "{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"},\"model\":\"missing\",\"reasoningEffort\":\"low\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}");
    try std.testing.expectEqual(core.agent_thread.Status.ready, codex.transcript.value.status);
    try std.testing.expectEqualStrings("fake-model", codex.transcript.value.options.modelSlice());
    try std.testing.expect(codex.transcript.value.accepts(codex.transcript.value.options));
}

test "Codex replaces an unavailable configured model with the advertised default in either response order" {
    const catalog = "{\"id\":0,\"result\":{\"data\":[{\"model\":\"first\",\"displayName\":\"First\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"}],\"defaultReasoningEffort\":\"low\",\"isDefault\":false},{\"model\":\"available-default\",\"displayName\":\"Available\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"high\"},{\"reasoningEffort\":\"ultra\"}],\"defaultReasoningEffort\":\"high\",\"isDefault\":true}]}}";
    const thread = "{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"},\"model\":\"retired-model\",\"reasoningEffort\":\"ultra\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}";
    for ([_]bool{ false, true }) |thread_first| {
        var codex = init();
        _ = try receive(&codex, if (thread_first) thread else catalog);
        try std.testing.expectEqual(core.agent_thread.Status.starting, codex.transcript.value.status);
        _ = try receive(&codex, if (thread_first) catalog else thread);
        const snapshot = &codex.transcript.value;
        try std.testing.expectEqual(core.agent_thread.Status.ready, snapshot.status);
        try std.testing.expectEqualStrings("available-default", snapshot.options.modelSlice());
        try std.testing.expectEqualStrings("high", snapshot.options.effort.idSlice());
        try std.testing.expect(snapshot.accepts(snapshot.options));
        try std.testing.expect(snapshot.findModel("retired-model") == null);
        try std.testing.expectEqual(@as(u8, 2), snapshot.model_count);
        try std.testing.expectEqual(core.AgentAccess.workspace, snapshot.options.access);
        const notice = snapshot.items()[0];
        try std.testing.expectEqual(core.agent_thread.Role.system, notice.role);
        try std.testing.expect(std.mem.indexOf(u8, notice.text(snapshot), "retired-model") != null);
        try std.testing.expect(std.mem.indexOf(u8, notice.text(snapshot), "available-default") != null);

        var prompt: Prompt = .{ .len = 4, .options = snapshot.options };
        @memcpy(prompt.bytes[0..4], "test");
        const encoded = (try codex.command(.{ .prompt = prompt })).?;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params").?.object;
        try std.testing.expectEqualStrings("available-default", params.get("model").?.string);
        try std.testing.expectEqualStrings("high", params.get("effort").?.string);
        try std.testing.expectEqualStrings("untrusted", params.get("approvalPolicy").?.string);
    }
}

test "Codex preserves an available model and replaces an unavailable configured effort with notice" {
    var codex = init();
    _ = try receive(&codex, "{\"id\":0,\"result\":{\"data\":[{\"model\":\"fake-model\",\"displayName\":\"Fake\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"}],\"defaultReasoningEffort\":\"low\",\"isDefault\":true}]}}");
    _ = try receive(&codex, "{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"},\"model\":\"fake-model\",\"reasoningEffort\":\"unavailable-effort\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}");
    const snapshot = &codex.transcript.value;
    try std.testing.expectEqual(core.agent_thread.Status.ready, snapshot.status);
    try std.testing.expectEqualStrings("fake-model", snapshot.options.modelSlice());
    try std.testing.expectEqualStrings("low", snapshot.options.effort.idSlice());
    try std.testing.expect(snapshot.accepts(snapshot.options));
    const notice = snapshot.items()[0];
    try std.testing.expectEqual(core.agent_thread.Role.system, notice.role);
    try std.testing.expect(std.mem.indexOf(u8, notice.text(snapshot), "unavailable-effort") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice.text(snapshot), "low") != null);
}

test "Codex file approval includes the full change and requested session write root" {
    var codex = init();
    try working(&codex);
    _ = try receive(&codex, "{\"method\":\"item/started\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"file-1\",\"type\":\"fileChange\",\"changes\":[{\"path\":\"/tmp/a.zig\",\"kind\":{\"type\":\"update\",\"move_path\":\"/tmp/b.zig\"},\"diff\":\"-const x = 1;\\n+const x = 2;\"}]}}}");
    _ = try receive(&codex, "{\"id\":9,\"method\":\"item/fileChange/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"file-1\",\"grantRoot\":\"/tmp/shared-project\",\"reason\":\"Apply changes\"}}");
    const text = codex.transcript.value.pending_approval.?.text();
    for ([_][]const u8{ "/tmp/a.zig", "/tmp/b.zig", "+const x = 2;", "session", "/tmp/shared-project" }) |required| {
        try std.testing.expect(std.mem.indexOf(u8, text, required) != null);
    }
}

test "Codex command approval shows additional permissions and future scope fields" {
    var codex = init();
    try working(&codex);
    _ = try receive(&codex, "{\"id\":9,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"command\":\"write to existing terminal\",\"kind\":\"writeStdin\",\"additionalPermissions\":{\"fileSystem\":{\"write\":[\"/private/outside\"]},\"network\":true},\"futureScope\":\"session-wide\"}}");
    const text = codex.transcript.value.pending_approval.?.text();
    for ([_][]const u8{ "writeStdin", "/private/outside", "network", "session-wide" }) |required| {
        try std.testing.expect(std.mem.indexOf(u8, text, required) != null);
    }
}

test "Codex commandless network approval shows target and fails without an actionable context" {
    var codex = init();
    try working(&codex);
    _ = try receive(&codex, "{\"id\":9,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"command\":null,\"networkApprovalContext\":{\"host\":\"example.com:8443\",\"protocol\":\"https\"}}}");
    const text = codex.transcript.value.pending_approval.?.text();
    try std.testing.expect(std.mem.indexOf(u8, text, "example.com:8443") != null);
    _ = try codex.command(.{ .approval = .{ .id = 1, .accepted = false } });
    try std.testing.expectError(error.ApprovalDetailsUnavailable, receive(&codex, "{\"id\":10,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"command\":null}}"));
    try std.testing.expect(codex.transcript.value.pending_approval == null);
}

test "Codex refuses to expose approvals with truncated or oversized details" {
    var codex = init();
    try working(&codex);
    codex.transcript.update(.{ .id = "file-1", .role = .tool, .text = "partial diff", .truncated = true });
    const request = "{\"id\":9,\"method\":\"item/fileChange/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"file-1\",\"grantRoot\":\"/tmp\"}}";
    try std.testing.expectError(error.ApprovalDetailsTruncated, receive(&codex, request));
    try std.testing.expect(codex.transcript.value.pending_approval == null);
    const large = [_]u8{'x'} ** 4096;
    codex.transcript.update(.{ .id = "file-1", .role = .tool, .text = &large });
    try std.testing.expectError(error.ApprovalDescriptionTooLarge, receive(&codex, request));
    try std.testing.expect(codex.transcript.value.pending_approval == null);
    try std.testing.expect(try codex.command(.{ .approval = .{ .id = 1, .accepted = true } }) == null);
}

test "Codex cannot present one-time approval when only broader grants are available" {
    var codex = init();
    try working(&codex);
    try std.testing.expectError(error.UnsupportedApprovalDecisions, receive(&codex, "{\"id\":9,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"command\":\"test\",\"availableDecisions\":[\"acceptForSession\",\"cancel\"]}}"));
    try std.testing.expect(codex.transcript.value.pending_approval == null);
}

test "Codex never exposes truncated RPC approval details or accepts truncated responses" {
    var codex = init();
    try working(&codex);
    const requests = [_][]const u8{
        "{\"id\":9,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"command\":\"true\"}}",
        "{\"id\":1,\"result\":{}}",
    };
    for (requests) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.ProviderControlTooLarge, codex.receive(.{ .value = parsed.value, .truncated = true }));
        try std.testing.expect(codex.transcript.value.pending_approval == null);
        try std.testing.expectEqual(.working, codex.transcript.value.status);
    }
}

test "Codex tracks projected output incompleteness for deltas and completed items" {
    var codex = init();
    try working(&codex);
    const lines = [_][]const u8{
        "{\"method\":\"item/commandExecution/outputDelta\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"cmd\",\"delta\":\"preview\"}}",
        "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"cmd\",\"type\":\"commandExecution\",\"command\":\"cat image.png\",\"aggregatedOutput\":\"preview\",\"status\":\"completed\",\"exitCode\":0}}}",
    };
    for (lines) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        _ = try codex.receive(.{ .value = parsed.value, .truncated = true });
        try std.testing.expect(codex.transcript.value.truncated);
        try std.testing.expect(!codex.transcript.value.items()[1].fragment_end);
        try std.testing.expectError(error.ApprovalDetailsTruncated, codex.transcript.reviewText("cmd"));
    }
}

test "Codex typed command lifecycle preserves title and status while authoritative completion replaces output" {
    var codex = init();
    try working(&codex);
    _ = try receive(&codex, "{\"method\":\"item/started\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"cmd\",\"type\":\"commandExecution\",\"command\":\"zig test\",\"cwd\":\"/tmp\",\"status\":\"inProgress\"}}}");
    const identity = codex.transcript.value.items()[1].identity;
    _ = try receive(&codex, "{\"method\":\"item/commandExecution/outputDelta\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"cmd\",\"delta\":\"partial\"}}");
    try std.testing.expectEqual(.command, codex.transcript.value.items()[1].kind);
    try std.testing.expectEqual(.running, codex.transcript.value.items()[1].status);
    try std.testing.expectEqualStrings("Command", codex.transcript.value.items()[1].title(&codex.transcript.value));
    _ = try receive(&codex, "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"cmd\",\"type\":\"commandExecution\",\"command\":\"zig test\",\"cwd\":\"/tmp\",\"status\":\"failed\",\"exitCode\":1,\"aggregatedOutput\":\"FAILED test\"}}}");
    const item = codex.transcript.value.items()[1];
    try std.testing.expectEqual(identity, item.identity);
    try std.testing.expectEqual(.failed, item.status);
    try std.testing.expectEqualStrings("$ zig test\nFAILED test\nExit code: 1\n", item.text(&codex.transcript.value));
    try std.testing.expectEqualStrings("thread-1", codex.transcript.value.threadId());
    try std.testing.expectEqualStrings("turn-1", codex.transcript.value.currentTurnId());
    _ = try receive(&codex, "{\"method\":\"item/commandExecution/outputDelta\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"cmd\",\"delta\":\"late\"}}");
    try std.testing.expectEqualStrings("$ zig test\nFAILED test\nExit code: 1\n", codex.transcript.value.items()[1].text(&codex.transcript.value));
}

test "Codex distinguishes final message reasoning summary tools and structured plan updates" {
    var codex = init();
    try working(&codex);
    _ = try receive(&codex, "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"final\",\"type\":\"agentMessage\",\"phase\":\"final_answer\",\"text\":\"Done\"}}}");
    try std.testing.expectEqual(.final_answer, codex.transcript.value.items()[1].phase);
    _ = try receive(&codex, "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"reason\",\"type\":\"reasoning\",\"summary\":[\"Checking files\"],\"content\":[\"Never display raw reasoning\"]}}}");
    try std.testing.expectEqual(.reasoning, codex.transcript.value.items()[2].kind);
    try std.testing.expectEqualStrings("Checking files\n", codex.transcript.value.items()[2].text(&codex.transcript.value));
    _ = try receive(&codex, "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"tool\",\"type\":\"mcpToolCall\",\"server\":\"docs\",\"tool\":\"lookup\",\"arguments\":{\"query\":\"Zig\"},\"status\":\"failed\",\"error\":{\"message\":\"Unavailable\"}}}}");
    try std.testing.expectEqual(.mcp, codex.transcript.value.items()[3].kind);
    try std.testing.expectEqual(.failed, codex.transcript.value.items()[3].status);
    try std.testing.expectEqualStrings("docs · lookup", codex.transcript.value.items()[3].title(&codex.transcript.value));
    try std.testing.expect(std.mem.indexOf(u8, codex.transcript.value.items()[3].text(&codex.transcript.value), "Unavailable") != null);
    _ = try receive(&codex, "{\"method\":\"turn/plan/updated\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"explanation\":\"Two steps\",\"plan\":[{\"step\":\"Inspect\",\"status\":\"completed\"},{\"step\":\"Test\",\"status\":\"inProgress\"}]}}");
    const plan_identity = codex.transcript.value.items()[4].identity;
    try std.testing.expectEqual(.plan, codex.transcript.value.items()[4].kind);
    try std.testing.expectEqualStrings("[x] Inspect\n[>] Test\n", codex.transcript.value.items()[4].text(&codex.transcript.value));
    _ = try receive(&codex, "{\"method\":\"turn/plan/updated\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"plan\":[{\"step\":\"Inspect\",\"status\":\"completed\"},{\"step\":\"Test\",\"status\":\"completed\"}]}}");
    try std.testing.expectEqual(plan_identity, codex.transcript.value.items()[4].identity);
    try std.testing.expectEqual(.completed, codex.transcript.value.items()[4].status);
}

test "Codex child tool preview does not replace the child response and retains public metadata" {
    var codex: @import("Codex.zig") = .{ .cwd = "/tmp", .transcript = .{ .value = .{ .pane_id = @enumFromInt(1), .pane_generation = 2 } } };
    codex.children.setRoot("root");
    const events = [_][]const u8{
        "{\"method\":\"thread/started\",\"params\":{\"thread\":{\"id\":\"child\",\"source\":{\"subAgent\":{\"thread_spawn\":{\"parent_thread_id\":\"root\",\"agent_path\":\"/root/review\",\"agent_nickname\":\"Reviewer\",\"agent_role\":\"explorer\"}}}}}}",
        "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"child\",\"turn\":{\"id\":\"child-turn\"}}}",
        "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"child\",\"turnId\":\"child-turn\",\"item\":{\"type\":\"agentMessage\",\"id\":\"message\",\"text\":\"Reviewing the patch\"}}}",
        "{\"method\":\"item/started\",\"params\":{\"threadId\":\"child\",\"turnId\":\"child-turn\",\"item\":{\"type\":\"commandExecution\",\"id\":\"tool\",\"command\":\"zig test\",\"cwd\":\"/tmp\",\"status\":\"inProgress\"}}}",
    };
    for (events) |event| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, event, .{});
        defer parsed.deinit();
        _ = try codex.receive(.{ .value = parsed.value });
    }

    const item = codex.transcript.value.items()[0];
    try std.testing.expectEqual(.subagent, item.kind);
    try std.testing.expectEqual(.running, item.status);
    try std.testing.expectEqualStrings("Reviewer", item.title(&codex.transcript.value));
    try std.testing.expectEqualStrings("Reviewing the patch", item.text(&codex.transcript.value));
    try std.testing.expectEqualStrings("Command · running\nzig test\n/tmp\n/root/review\nexplorer", item.detail(&codex.transcript.value));
}

test "Codex file change headings preserve actions move destinations and complete reviewable diffs" {
    var codex = init();
    try working(&codex);
    _ = try receive(&codex,
        \\{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"files","type":"fileChange","status":"inProgress","changes":[{"path":"/tmp/new.zig","kind":{"type":"add"},"diff":"+const new = 1;\n"},{"path":"/tmp/old.zig","kind":{"type":"delete"},"diff":"-const old = 2;"},{"path":"/tmp/current.zig","kind":{"type":"update","move_path":null},"diff":"-const current = 3;\n+const current = 4;"},{"path":"/tmp/from.zig","kind":{"type":"update","move_path":"/tmp/to.zig"},"diff":"-const moved = 5;\n+const moved = 6;"}]}}}
    );
    const body = codex.transcript.value.items()[1].text(&codex.transcript.value);
    try std.testing.expectEqualStrings("Added /tmp/new.zig\n+const new = 1;\nDeleted /tmp/old.zig\n-const old = 2;\nUpdated /tmp/current.zig\n-const current = 3;\n+const current = 4;\nMoved /tmp/from.zig → /tmp/to.zig\n-const moved = 5;\n+const moved = 6;\n", body);
    try std.testing.expectEqualStrings(body, (try codex.transcript.reviewText("files")).?);
    _ = try receive(&codex, "{\"id\":9,\"method\":\"item/fileChange/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"files\"}}");
    try std.testing.expect(std.mem.indexOf(u8, codex.transcript.value.pending_approval.?.text(), body) != null);
}

test "Codex unrepresentable file change metadata cannot expose an approval" {
    const changes = [_][]const u8{
        \\{"path":"/tmp/a","kind":{"type":"futureOperation"},"diff":"change"}
        ,
        \\{"path":"/tmp/a","kind":{"type":"update","movePath":"/tmp/b"},"diff":"change"}
        ,
        \\{"path":"/tmp/a","kind":{"type":"update","move_path":42},"diff":"change"}
        ,
        \\{"path":"/tmp/a","kind":{"type":"update","move_path":""},"diff":"change"}
        ,
        \\{"path":"/tmp/a","kind":{"type":"delete","move_path":"/tmp/b"},"diff":"change"}
        ,
        \\{"path":"/tmp/a","kind":{"type":"update","futureScope":"whole-directory"},"diff":"change"}
        ,
        \\{"path":"/tmp/a","kind":{"type":"update"},"diff":"change","extraTarget":"/tmp/b"}
        ,
        \\{"path":"/tmp/a\u0000hidden","kind":{"type":"update"},"diff":"change"}
        ,
        \\{"path":"/tmp/a","kind":{"type":"update"},"diff":null}
        ,
    };
    for (changes) |change| {
        var codex = init();
        try working(&codex);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, change, .{});
        defer parsed.deinit();
        var buffer: [2048]u8 = undefined;
        const notification = try @import("protocol.zig").encode(&buffer, .{
            .method = "item/started",
            .params = .{ .threadId = "thread-1", .turnId = "turn-1", .item = .{ .id = "files", .type = "fileChange", .changes = .{parsed.value} } },
        });
        _ = try receive(&codex, notification);
        try std.testing.expect(codex.transcript.value.truncated);
        try std.testing.expectEqualStrings("File change details could not be represented safely.\n", codex.transcript.value.items()[1].text(&codex.transcript.value));
        try std.testing.expectError(error.ApprovalDetailsTruncated, receive(&codex, "{\"id\":9,\"method\":\"item/fileChange/requestApproval\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"itemId\":\"files\"}}"));
        try std.testing.expect(codex.transcript.value.pending_approval == null);
    }
}

test "recent conversations are scoped bounded normalized and selected without sending a prompt" {
    var codex = init();
    try ready(&codex);
    const listing = "{\"id\":2147483647,\"result\":{\"data\":[{\"id\":\"previous-thread\",\"cwd\":\"/tmp\",\"preview\":\"Fix parser\\nContinue\"}],\"nextCursor\":\"more\"}}";
    _ = try receive(&codex, listing);
    try std.testing.expectEqual(.ready, codex.transcript.value.recent.phase);
    try std.testing.expectEqual(1, codex.transcript.value.recent.count);
    try std.testing.expectEqualStrings("Fix parser Continue", codex.transcript.value.recent.entries[0].titleSlice());
    try std.testing.expect(codex.transcript.value.recent.has_more);
    const request = (try codex.command(.{ .resume_conversation = codex.transcript.value.recent.entries[0] })).?;
    try std.testing.expect(std.mem.indexOf(u8, request, "\"method\":\"thread/resume\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"threadId\":\"previous-thread\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"excludeTurns\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"approvalPolicy\":\"untrusted\"") != null);
    try std.testing.expectEqual(.starting, codex.transcript.value.status);
    try std.testing.expectEqual(0, codex.transcript.value.item_count);
    _ = try receive(&codex, "{\"id\":3,\"result\":{\"thread\":{\"id\":\"previous-thread\",\"cwd\":\"/tmp\",\"name\":\"Parser fixes\"},\"model\":\"fake-model\",\"reasoningEffort\":\"low\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}");
    try std.testing.expectEqual(.ready, codex.transcript.value.status);
    try std.testing.expect(codex.transcript.value.resumed and codex.transcript.value.truncated);
    try std.testing.expect(!codex.transcript.value.canResume());
    try std.testing.expectEqualStrings("previous-thread", codex.transcript.value.threadId());
    try std.testing.expectEqualStrings("Parser fixes", codex.metadata.nameSlice().?);
    var prompt: Prompt = .{ .len = 8, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..8], "Continue");
    const turn = (try codex.command(.{ .prompt = prompt })).?;
    try std.testing.expect(std.mem.indexOf(u8, turn, "\"threadId\":\"previous-thread\"") != null);
}

test "resume failure leaves the unused conversation available and rejects busy replacement" {
    var codex = init();
    try ready(&codex);
    const entry = try core.RecentConversation.init("previous-thread", "Previous");
    _ = try codex.command(.{ .resume_conversation = entry });
    try std.testing.expectError(error.ProviderResumeTimeout, codex.expireResume());
    _ = try receive(&codex, "{\"id\":3,\"error\":{\"message\":\"Conversation no longer exists\"}}");
    try std.testing.expectEqual(.ready, codex.transcript.value.status);
    try std.testing.expectEqualStrings("thread-1", codex.transcript.value.threadId());
    try std.testing.expect(codex.transcript.value.canResume());
    try std.testing.expect(std.mem.indexOf(u8, codex.transcript.value.items()[0].text(&codex.transcript.value), "no longer exists") != null);
    var busy = init();
    try working(&busy);
    try std.testing.expect(try busy.command(.{ .resume_conversation = entry }) == null);
    try std.testing.expectEqualStrings("thread-1", busy.transcript.value.threadId());
}

test "malformed duplicate and wrong-directory recent references cannot be selected" {
    const responses = [_][]const u8{
        "{\"data\":[{\"id\":\"--option\",\"cwd\":\"/tmp\"}]}",
        "{\"data\":[{\"id\":\"valid\",\"cwd\":\"/elsewhere\"}]}",
        "{\"data\":[{\"id\":\"same\",\"cwd\":\"/tmp\"},{\"id\":\"same\",\"cwd\":\"/tmp\"}]}",
    };
    for (responses) |response| {
        var codex = init();
        try ready(&codex);
        var storage: [1024]u8 = undefined;
        _ = try receive(&codex, try std.fmt.bufPrint(&storage, "{{\"id\":2147483647,\"result\":{s}}}", .{response}));
        try std.testing.expectEqual(.failed, codex.transcript.value.recent.phase);
        try std.testing.expectEqual(0, codex.transcript.value.recent.count);
        try std.testing.expectEqual(.ready, codex.transcript.value.status);
    }
}

test "resume validates identity directory and permissions before replacing the conversation" {
    const cases = [_][3][]const u8{
        .{ "wrong-thread", "/tmp", "workspaceWrite" },
        .{ "previous-thread", "/elsewhere", "workspaceWrite" },
        .{ "previous-thread", "/tmp", "dangerFullAccess" },
    };
    for (cases, 0..) |fields, index| {
        var codex = init();
        try ready(&codex);
        _ = try codex.command(.{ .resume_conversation = try core.RecentConversation.init("previous-thread", "Parser fixes") });
        var storage: [1024]u8 = undefined;
        const response = try std.fmt.bufPrint(&storage, "{{\"id\":3,\"result\":{{\"thread\":{{\"id\":\"{s}\",\"cwd\":\"{s}\"}},\"model\":\"fake-model\",\"reasoningEffort\":\"low\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{{\"type\":\"{s}\"}}}}}}", .{ fields[0], fields[1], fields[2] });
        try std.testing.expectError(if (index == 2) error.UnexpectedProviderPermissions else error.InvalidResumedConversation, receive(&codex, response));
        try std.testing.expectEqualStrings("thread-1", codex.transcript.value.threadId());
        try std.testing.expect(!codex.transcript.value.resumed);
    }
}

test "unnamed resumed conversation retains its preview and skips reserved request IDs" {
    var codex = init();
    try ready(&codex);
    _ = try codex.command(.{ .resume_conversation = try core.RecentConversation.init("previous-thread", "Parser fixes") });
    _ = try receive(&codex, "{\"id\":3,\"result\":{\"thread\":{\"id\":\"previous-thread\",\"cwd\":\"/tmp\",\"name\":null},\"model\":\"fake-model\",\"reasoningEffort\":\"low\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}");
    try std.testing.expectEqualStrings("Parser fixes", codex.metadata.nameSlice().?);
    codex.next_request = 2147483647;
    var prompt: Prompt = .{ .len = 4, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..4], "Next");
    _ = try codex.command(.{ .prompt = prompt });
    try std.testing.expectEqual(@as(?u64, 2147483648), codex.pending_turn_request);
}

fn commandText(codex: *Codex, text: []const u8) !?[]const u8 {
    var prompt: Prompt = .{ .len = @intCast(text.len), .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..text.len], text);
    return codex.command(.{ .prompt = prompt });
}

test "Codex skill catalog excludes disabled and foreign cwd entries and invokes exact paths" {
    var codex = init();
    try ready(&codex);
    _ = try receive(&codex,
        \\{"id":2147483646,"result":{"data":[{"cwd":"/other","skills":[{"name":"foreign","enabled":true,"path":"/other/SKILL.md","scope":"repo"}],"errors":[]},{"cwd":"/tmp","skills":[{"name":"review","description":"Review code","enabled":true,"path":"/skills/review/SKILL.md","scope":"repo","interface":{"displayName":"Code Review","shortDescription":"Inspect the diff"}},{"name":"hidden","enabled":false,"path":"/skills/hidden/SKILL.md","scope":"user"},{"name":"bad","enabled":true,"path":"relative/SKILL.md","scope":"user"}],"errors":[]}]}}
    );
    try std.testing.expectEqual(@as(u8, 1), codex.transcript.value.skills.count);
    try std.testing.expectEqualStrings("Code Review", codex.transcript.value.skills.entries[0].label(&codex.transcript.value.skills));
    const line = (try commandText(&codex, "Please $review this, then $review-extra")).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const inputs = parsed.value.object.get("params").?.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), inputs.len);
    try std.testing.expectEqualStrings("skill", inputs[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("review", inputs[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("/skills/review/SKILL.md", inputs[1].object.get("path").?.string);
    const refresh = (try receive(&codex, "{\"method\":\"skills/changed\"}")).?;
    try std.testing.expect(std.mem.indexOf(u8, refresh, "skills/list") != null);
    try std.testing.expect(std.mem.indexOf(u8, refresh, "forceReload\":true") != null);
}

test "Codex slash rename updates metadata only after provider success and never starts a turn" {
    var codex = init();
    try ready(&codex);
    const line = (try commandText(&codex, "/rename Parser work")).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("thread/name/set", parsed.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("Parser work", parsed.value.object.get("params").?.object.get("name").?.string);
    try std.testing.expect(codex.metadata.nameSlice() == null);
    try std.testing.expectEqual(@as(u8, 0), codex.transcript.value.item_count);
    _ = try receive(&codex, "{\"id\":3,\"result\":{}}");
    try std.testing.expectEqualStrings("Parser work", codex.metadata.nameSlice().?);
    try std.testing.expectEqual(.ready, codex.transcript.value.status);
    _ = try commandText(&codex, "/rename Rejected name");
    _ = try receive(&codex, "{\"id\":4,\"error\":{\"message\":\"Cannot rename\"}}");
    try std.testing.expectEqualStrings("Parser work", codex.metadata.nameSlice().?);
    try std.testing.expectEqual(.ready, codex.transcript.value.status);
}

test "Codex slash clear keeps the old transcript until a new thread is ready" {
    var codex = init();
    try ready(&codex);
    codex.transcript.update(.{ .role = .assistant, .text = "Previous conversation", .complete = true });
    const line = (try commandText(&codex, "/clear")).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("thread/start", parsed.value.object.get("method").?.string);
    try std.testing.expectEqualStrings("thread-1", codex.transcript.value.threadId());
    try std.testing.expectEqual(@as(u8, 1), codex.transcript.value.item_count);
    _ = try receive(&codex, "{\"id\":3,\"result\":{\"thread\":{\"id\":\"thread-2\"},\"model\":\"fake-model\",\"reasoningEffort\":\"low\",\"approvalPolicy\":\"untrusted\",\"approvalsReviewer\":\"user\",\"sandbox\":{\"type\":\"workspaceWrite\"}}}");
    try std.testing.expectEqualStrings("thread-2", codex.transcript.value.threadId());
    try std.testing.expectEqual(@as(u8, 0), codex.transcript.value.item_count);
    try std.testing.expectEqual(.ready, codex.transcript.value.status);
    try std.testing.expect(codex.transcript.value.canResume());
    const next = (try commandText(&codex, "Continue here")).?;
    try std.testing.expect(std.mem.indexOf(u8, next, "\"threadId\":\"thread-2\"") != null);
}

test "oversized skill references reject the turn without breaking the provider session" {
    var codex = init();
    try ready(&codex);
    var prompt: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&prompt);
    for (0..core.AgentSkills.capacity) |index| {
        var name: [8]u8 = undefined;
        const label = try std.fmt.bufPrint(&name, "skill{d}", .{index});
        try codex.skills.value.append(.{ .name = label });
        @memset(&codex.skills.paths[index], 'a');
        codex.skills.paths[index][0] = '/';
        codex.skills.path_lengths[index] = 1024;
        try writer.print("${s} ", .{label});
    }
    try std.testing.expect(try commandText(&codex, writer.buffered()) == null);
    try std.testing.expectEqual(.ready, codex.transcript.value.status);
    try std.testing.expect(codex.pending_turn_request == null);
    try std.testing.expect(codex.pending_options == null);
    const items = codex.transcript.value.items();
    try std.testing.expect(std.mem.indexOf(u8, items[items.len - 1].text(&codex.transcript.value), "request limit") != null);
    try std.testing.expect(try commandText(&codex, "$skill0 Continue") != null);
}

test "skill refresh ignores a late initial catalog and preserves correlation" {
    var codex = init();
    try ready(&codex);
    codex.skills_request = null;
    codex.skills.value.phase = .failed;
    _ = try receive(&codex, "{\"method\":\"skills/changed\"}");
    try std.testing.expectEqual(@as(?u64, 3), codex.skills_request);
    _ = try receive(&codex, "{\"id\":2147483646,\"result\":{\"data\":[]}}");
    try std.testing.expectEqual(@as(?u64, 3), codex.skills_request);
    _ = try receive(&codex, "{\"id\":3,\"result\":{\"data\":[{\"cwd\":\"/tmp\",\"skills\":[],\"errors\":[]}]}}");
    try std.testing.expect(codex.skills_request == null);
    try std.testing.expectEqual(.ready, codex.transcript.value.skills.phase);
    try std.testing.expectEqual(.ready, codex.transcript.value.status);
}

test "failed clear retains the current conversation and permits retry" {
    var codex = init();
    try ready(&codex);
    codex.transcript.update(.{ .role = .assistant, .text = "Keep this", .complete = true });
    _ = try commandText(&codex, "/clear");
    _ = try receive(&codex, "{\"id\":3,\"error\":{\"message\":\"Cannot start a conversation\"}}");
    try std.testing.expectEqualStrings("thread-1", codex.transcript.value.threadId());
    try std.testing.expectEqualStrings("Keep this", codex.transcript.value.items()[0].text(&codex.transcript.value));
    try std.testing.expectEqual(.ready, codex.transcript.value.status);
    try std.testing.expect(try commandText(&codex, "/clear") != null);
}

test "Codex image-only turn sends localImage inputs without an empty text block" {
    var codex = init();
    try ready(&codex);
    var prompt: Prompt = .{ .options = codex.transcript.value.options };
    try prompt.images.append("/tmp/first.png");
    try prompt.images.append("/tmp/second.png");
    const encoded = (try codex.command(.{ .prompt = prompt })).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("turn/start", parsed.value.object.get("method").?.string);
    const inputs = parsed.value.object.get("params").?.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), inputs.len);
    try std.testing.expectEqualStrings("localImage", inputs[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("/tmp/first.png", inputs[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("/tmp/second.png", inputs[1].object.get("path").?.string);
}

test "Codex mixed images preserve text and do not execute a slash command instead of the turn" {
    var codex = init();
    try ready(&codex);
    var prompt: Prompt = .{ .len = 7, .options = codex.transcript.value.options };
    @memcpy(prompt.bytes[0..7], "/rename");
    try prompt.images.append("/tmp/example.png");
    const encoded = (try codex.command(.{ .prompt = prompt })).?;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("turn/start", parsed.value.object.get("method").?.string);
    const inputs = parsed.value.object.get("params").?.object.get("input").?.array.items;
    try std.testing.expectEqualStrings("/rename", inputs[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("localImage", inputs[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("/rename\n[Image 1]", codex.transcript.value.items()[0].text(&codex.transcript.value));
}

test "provider image echoes never display local paths or inline image bytes" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"Inspect\"},{\"type\":\"localImage\",\"path\":\"/private/image.png\"},{\"type\":\"image\",\"url\":\"data:image/png;base64,private\"}]}", .{});
    defer parsed.deinit();
    var normalizer: @import("ItemNormalizer.zig") = .{};
    const item = normalizer.item(parsed.value, true).?;
    try std.testing.expectEqualStrings("Inspect\n[Image 1]\n[Image 2]", item.text);
}
