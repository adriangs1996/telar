const std = @import("std");
const core = @import("telar-core");
const Session = @import("Session.zig");

const fake_provider =
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    \\    *'"method":"model/list"'*) printf '%s\n' '{"id":0,"result":{"data":[{"model":"fake-model","displayName":"Fake model","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low"}]}}' ;;
    \\    *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-1","name":"Provider session"},"model":"fake-model","reasoningEffort":"low","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}' ;;
    \\    *'"method":"turn/start"'*) printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","itemId":"a","delta":"Hello "}}' '{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","itemId":"a","delta":"from fake Codex"}}' '{"id":"approve-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","command":"true","reason":"Testing approval"}}' ;;
    \\    *'"id":"approve-1"'*) printf '%s\n' '{"method":"thread/name/updated","params":{"threadId":"thread-1","threadName":"Approved session"}}' '{"method":"item/completed","params":{"threadId":"thread-1","item":{"id":"a","type":"agentMessage","text":"Explicitly approved"}}}' '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}' ;;
    \\  esac
    \\done
;

fn awaitStatus(session: *Session, status: core.agent_thread.Status) !core.AgentThreadSnapshot {
    const io = std.testing.io;
    const started = std.Io.Timestamp.now(io, .awake);
    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() - started.toMilliseconds() < 5000) {
        var snapshot: core.AgentThreadSnapshot = undefined;
        if (session.snapshot(io, &snapshot) != null and snapshot.status == status) {
            return snapshot;
        }

        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }

    return error.TestProviderDeadline;
}

test "agent pane provider streams while detached and reconnect snapshot retains explicit approval" {
    const io = std.testing.io;
    const session = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 4,
        .cwd = "/tmp",
        .arguments = &.{ "/bin/sh", "-c", fake_provider },
    });
    defer session.close(io);
    const initial = try awaitStatus(session, .ready);
    var invalid = initial.options;
    invalid.effort = try core.AgentEffort.init("unsupported");
    try std.testing.expect(!session.submit(io, .{ .text = "keep this draft", .options = invalid }));
    try std.testing.expect(!session.prompt_pending.load(.acquire));
    try std.testing.expect(session.submit(io, .{ .text = "hello", .options = initial.options }));
    const blocked = try awaitStatus(session, .blocked);
    try std.testing.expectEqualStrings("Hello from fake Codex", blocked.items()[1].text(&blocked));
    try std.testing.expectEqual(@as(u64, 4), blocked.pane_generation);
    try std.testing.expect(!session.submit(io, .{ .text = "cannot overwrite turn", .options = .{} }));
    var reconnect: core.AgentThreadSnapshot = undefined;
    const metadata = session.snapshot(io, &reconnect) orelse return error.MissingThreadSnapshot;
    try std.testing.expectEqualStrings("Provider session", metadata.nameSlice().?);
    try std.testing.expectEqual(blocked.pending_approval.?.id, reconnect.pending_approval.?.id);
    try std.testing.expect(session.approve(io, .{ .id = reconnect.pending_approval.?.id, .accepted = true }));
    const done = try awaitStatus(session, .ready);
    try std.testing.expectEqualStrings("Explicitly approved", done.items()[1].text(&done));
    try std.testing.expect(done.pending_approval == null);
    const renamed = session.snapshot(io, &reconnect) orelse return error.MissingThreadSnapshot;
    try std.testing.expectEqualStrings("Approved session", renamed.nameSlice().?);
    try std.testing.expect(renamed.revision > metadata.revision);
    try std.testing.expectEqualStrings("Explicitly approved", reconnect.items()[1].text(&reconnect));
}

test "agent pane provider startup timeout leaves a failed snapshot and shutdown joins idle reads" {
    const io = std.testing.io;
    const session = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 4,
        .cwd = "/tmp",
        .arguments = &.{ "/bin/sh", "-c", "while IFS= read -r line; do :; done" },
        .startup_timeout_ms = 20,
    });
    defer session.close(io);
    const failed = try awaitStatus(session, .failed);
    try std.testing.expect(std.mem.indexOf(u8, failed.items()[0].text(&failed), "ProviderStartupTimeout") != null);
    try std.testing.expect(!session.submit(io, .{ .text = "unavailable", .options = .{} }));
}

test "agent pane provider process launch failure reports an explicit error" {
    const io = std.testing.io;
    const session = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 4,
        .cwd = "/tmp",
        .arguments = &.{"/definitely/not/a/codex"},
    });
    defer session.close(io);
    const failed = try awaitStatus(session, .failed);
    try std.testing.expect(std.mem.indexOf(u8, failed.items()[0].text(&failed), "FileNotFound") != null);
}

test "agent pane provider startup deadline covers a missing model catalog after thread creation" {
    const io = std.testing.io;
    const session = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 4,
        .cwd = "/tmp",
        .startup_timeout_ms = 100,
        .arguments = &.{
            "/bin/sh", "-c",
            \\while IFS= read -r line; do
            \\  case "$line" in
            \\    *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            \\    *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-1"},"model":"fake-model","reasoningEffort":"low","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}' ;;
            \\  esac
            \\done
        },
    });
    defer session.close(io);
    const failed = try awaitStatus(session, .failed);
    try std.testing.expect(std.mem.indexOf(u8, failed.items()[0].text(&failed), "ProviderStartupTimeout") != null);
    try std.testing.expectEqual(@as(u8, 0), failed.model_count);
}

test "agent pane provider rejects malformed and oversized control frames without growing memory" {
    const io = std.testing.io;
    const malformed = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 4,
        .cwd = "/tmp",
        .arguments = &.{ "/bin/sh", "-c", "read -r line; printf '%s\\n' 'not json'; while read -r line; do :; done" },
    });
    defer malformed.close(io);
    _ = try awaitStatus(malformed, .failed);

    const oversized = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(10),
        .pane_generation = 4,
        .cwd = "/tmp",
        .arguments = &.{ "/bin/sh", "-c", "read -r line; /usr/bin/awk 'BEGIN {printf \"{\\\"id\\\":\\\"\"; for(i=0;i<270000;i++)printf \"x\"; print \"\\\"}\"}'; while read -r line; do :; done" },
    });
    defer oversized.close(io);
    const failed = try awaitStatus(oversized, .failed);
    try std.testing.expect(std.mem.indexOf(u8, failed.items()[0].text(&failed), "ProviderFrameTooLarge") != null);
}

test "agent pane survives megabyte command output then approval completion and another prompt" {
    const provider =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        \\    *'"method":"model/list"'*) printf '%s\n' '{"id":0,"result":{"data":[{"model":"fake-model","displayName":"Fake","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low"}]}}' ;;
        \\    *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-1"},"model":"fake-model","reasoningEffort":"low","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}' ;;
        \\    *'"text":"continue"'*) printf '%s\n' '{"id":4,"result":{"turn":{"id":"turn-2"}}}' '{"id":"approve-2","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-2","command":"true","reason":"Next turn"}}' ;;
        \\    *'"method":"turn/start"'*)
        \\      printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-1"}}}'
        \\      /usr/bin/awk 'BEGIN {printf "{\"method\":\"item/completed\",\"params\":{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"item\":{\"id\":\"cmd\",\"type\":\"commandExecution\",\"command\":\"cat image.png\",\"aggregatedOutput\":\""; for(i=0;i<350000;i++)printf "\\u0000\\ufffd"; print "\",\"status\":\"failed\",\"exitCode\":7}}}"}'
        \\      printf '%s\n' '{"id":"approve-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","command":"true","reason":"After large output"}}' ;;
        \\    *'"id":"approve-1"'*) printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"final","type":"agentMessage","text":"Still alive"}}}' '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}' ;;
        \\  esac
        \\done
    ;
    const io = std.testing.io;
    const session = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 4,
        .cwd = "/tmp",
        .arguments = &.{ "/bin/sh", "-c", provider },
    });
    defer session.close(io);
    const initial = try awaitStatus(session, .ready);
    try std.testing.expect(session.submit(io, .{ .text = "produce large output", .options = initial.options }));
    const blocked = try awaitStatus(session, .blocked);
    try std.testing.expect(blocked.truncated);
    const command = blocked.items()[1];
    try std.testing.expectEqual(.command, command.kind);
    try std.testing.expectEqual(.failed, command.status);
    try std.testing.expect(command.complete and !command.fragment_end);
    try std.testing.expect(std.mem.indexOf(u8, command.text(&blocked), "Output truncated by Telar") != null);
    try std.testing.expect(std.mem.indexOf(u8, command.text(&blocked), "Exit code: 7") != null);
    try std.testing.expect(session.approve(io, .{ .id = blocked.pending_approval.?.id, .accepted = true }));
    const done = try awaitStatus(session, .ready);
    try std.testing.expectEqualStrings("Still alive", done.items()[done.item_count - 1].text(&done));
    try std.testing.expect(session.submit(io, .{ .text = "continue", .options = done.options }));
    const next = try awaitStatus(session, .blocked);
    try std.testing.expectEqualStrings("turn-2", next.currentTurnId());
}

test "agent pane provider explicit stop joins a live child and closes change receivers" {
    const io = std.testing.io;
    const session = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 4,
        .cwd = "/tmp",
        .arguments = &.{ "/bin/sh", "-c", fake_provider },
    });
    defer session.close(io);
    _ = try awaitStatus(session, .ready);
    session.stop(io);
    session.waitStopped(io);
    try std.testing.expect(session.worker == null);
    try std.testing.expect(!session.submit(io, .{ .text = "after shutdown", .options = .{} }));
    // A coalesced change already queued before close may be drained once.
    session.waitForChange(io) catch {};
    try std.testing.expectError(error.Closed, session.waitForChange(io));
}

fn allocationFailure(gpa: std.mem.Allocator) !void {
    const session = try Session.init(std.testing.io, gpa, .{
        .pane_id = @enumFromInt(1),
        .pane_generation = 1,
        .cwd = "/tmp",
        .arguments = &.{"/definitely/not/a/codex"},
    });
    session.close(std.testing.io);
}

test "agent pane provider rolls back every initialization allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

test "agent pane provider inherits authentication environment without runtime authority" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var inherited = std.process.Environ.Map.init(gpa);
    defer inherited.deinit();
    try inherited.put("HOME", "/tmp/test-agent-home");
    try inherited.put("TELAR_SOCKET", "/tmp/runtime.sock");
    try inherited.put("TELAR_PANE_TOKEN", "test-token");
    const block = try inherited.createPosixBlock(gpa, .{});
    defer block.deinit(gpa);
    const session = try Session.init(io, gpa, .{
        .pane_id = @enumFromInt(1),
        .pane_generation = 1,
        .cwd = "/tmp",
        .arguments = &.{"/definitely/not/a/codex"},
        .environment = .{ .block = block },
    });
    defer session.close(io);
    try std.testing.expectEqualStrings("/tmp/test-agent-home", session.history_options.environment.get("HOME").?);
    try std.testing.expect(!session.history_options.environment.contains("TELAR_SOCKET"));
    try std.testing.expect(!session.history_options.environment.contains("TELAR_PANE_TOKEN"));
}

test "resume admission reserves the thread before provider progress and rejects racing prompts" {
    const provider =
        \\while IFS= read -r line; do
        \\ case "$line" in
        \\ *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        \\ *'"method":"model/list"'*) printf '%s\n' '{"id":0,"result":{"data":[{"model":"fake-model","displayName":"Fake","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low"}]}}' ;;
        \\ *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"new-thread"},"model":"fake-model","reasoningEffort":"low","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}' ;;
        \\ esac
        \\done
    ;
    const session = try Session.init(std.testing.io, std.testing.allocator, .{ .pane_id = @enumFromInt(1), .pane_generation = 2, .cwd = "/tmp", .arguments = &.{ "/bin/sh", "-c", provider }, .startup_timeout_ms = 100 });
    defer session.close(std.testing.io);
    const initial = try awaitStatus(session, .ready);
    const entry = try core.RecentConversation.init("previous-thread", "Parser fixes");
    try std.testing.expect(session.resumeConversation(std.testing.io, entry));
    try std.testing.expect(!session.submit(std.testing.io, .{ .text = "Racing prompt", .options = initial.options }));
    try std.testing.expect(!session.resumeConversation(std.testing.io, entry));
    const failed = try awaitStatus(session, .failed);
    try std.testing.expect(std.mem.indexOf(u8, failed.items()[0].text(&failed), "ProviderResumeTimeout") != null);
    try std.testing.expectEqual(1, failed.item_count);
}

const restore_provider =
    \\while IFS= read -r line; do
    \\  case "$line" in
    \\    *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    \\    *'"method":"thread/start"'*) exit 1 ;;
    \\    *'"method":"thread/resume"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"saved-thread","cwd":"/tmp","name":"Saved conversation","status":{"type":"idle"}},"model":"fake-model","reasoningEffort":"low","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}' '{"id":0,"result":{"data":[{"model":"fake-model","displayName":"Fake model","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low"}]}}' ;;
    \\  esac
    \\done
;

test "agent checkpoint resumes directly before the catalog arrives and retains the startup claim" {
    const io = std.testing.io;
    const session = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 8,
        .cwd = "/tmp",
        .restore_conversation = try core.RecentConversation.init("saved-thread", "Saved conversation"),
        .arguments = &.{ "/bin/sh", "-c", restore_provider },
    });
    defer session.close(io);
    const snapshot = try awaitStatus(session, .ready);
    try std.testing.expect(snapshot.resumed);
    try std.testing.expect(snapshot.truncated);
    try std.testing.expectEqualStrings("saved-thread", snapshot.threadId());
    try std.testing.expectEqual(@as(u64, 8), snapshot.pane_generation);
    try std.testing.expect(snapshot.pending_approval == null);
    session.stop(io);
    session.waitStopped(io);
    try std.testing.expect(try session.claims(io, "saved-thread"));
    const saved = (try session.checkpoint(io)).?;
    try std.testing.expectEqualStrings("saved-thread", saved.idSlice());
}

test "agent checkpoint failed startup retains its reference and cannot accept a new prompt" {
    const io = std.testing.io;
    const session = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 8,
        .cwd = "/tmp",
        .restore_conversation = try core.RecentConversation.init("saved-thread", ""),
        .arguments = &.{
            "/bin/sh", "-c",
            \\while IFS= read -r line; do
            \\ case "$line" in
            \\ *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            \\ *'"method":"thread/resume"'*) printf '%s\n' '{"id":2,"error":{"message":"Conversation unavailable"}}' ;;
            \\ esac
            \\done
        },
    });
    defer session.close(io);
    const failed = try awaitStatus(session, .failed);
    try std.testing.expectEqualStrings("saved-thread", failed.threadId());
    try std.testing.expect(!session.submit(io, .{ .text = "must not start another thread", .options = .{} }));
    session.stop(io);
    session.waitStopped(io);
    const saved = (try session.checkpoint(io)).?;
    try std.testing.expectEqualStrings("saved-thread", saved.idSlice());
}

test "agent checkpoint startup rejects a provider returning a different working directory" {
    const io = std.testing.io;
    const session = try Session.init(io, std.testing.allocator, .{
        .pane_id = @enumFromInt(9),
        .pane_generation = 8,
        .cwd = "/",
        .restore_conversation = try core.RecentConversation.init("saved-thread", ""),
        .arguments = &.{ "/bin/sh", "-c", restore_provider },
    });
    defer session.close(io);
    const failed = try awaitStatus(session, .failed);
    try std.testing.expectEqualStrings("saved-thread", failed.threadId());
    try std.testing.expect(std.mem.indexOf(u8, failed.items()[0].text(&failed), "InvalidResumedConversation") != null);
}
