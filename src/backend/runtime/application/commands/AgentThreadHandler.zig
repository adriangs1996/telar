const std = @import("std");
const PaneStore = @import("../../../pane/PaneStore.zig");
const Operation = @import("AgentThreadOperation.zig");
const PaneKey = @import("../../../pane/PaneKey.zig");
const Tracker = @import("../../../agent/Tracker.zig");
const agent_identity = @import("../coordinators/agent_identity.zig");

io: std.Io,
panes: *PaneStore,
agent_descriptions: ?*Tracker = null,

/// Validates exact pane authority and admits a bounded provider command.
/// Example: `const pane = try handler.execute(operation);`.
pub fn execute(handler: *@This(), operation: Operation) !PaneKey {
    const pane = handler.panes.resolve(operation.pane) orelse return error.PaneNotFound;
    if (pane.kind != .agent) {
        return error.NotAnAgentPane;
    }
    if (pane.close_requested or pane.exit != null) {
        return error.PaneExited;
    }
    if (operation.action == .prompt) {
        const snapshot = pane.agent_thread orelse return error.InvalidAgentOptions;
        if (!snapshot.accepts(operation.action.prompt.options)) {
            return error.InvalidAgentOptions;
        }
    }
    const session = pane.session.agent.session;
    const accepted = switch (operation.action) {
        .prompt => |text| session.submit(handler.io, text),
        .interrupt => session.interrupt(handler.io),
        .approval => |decision| session.approve(handler.io, decision),
        .query => true,
        .resume_conversation => |index| blk: {
            const snapshot = pane.agent_thread orelse return error.InvalidConversation;
            if (!snapshot.canResume() or snapshot.recent.phase != .ready or index >= snapshot.recent.count) {
                return error.InvalidConversation;
            }

            const entry = snapshot.recent.entries[index];
            for (handler.panes.items) |slot| {
                const other = slot orelse continue;
                if (other == pane or other.kind != .agent or other.exit != null) {
                    continue;
                }

                if (try other.session.agent.session.claims(handler.io, entry.idSlice())) {
                    return error.ConversationAlreadyOpen;
                }
            }

            break :blk session.resumeConversation(handler.io, entry);
        },
    };
    if (!accepted) {
        return error.AgentBusy;
    }

    if (operation.action == .prompt and @import("telar-core").AgentCommand.parse(operation.action.prompt.text) == null) {
        if (handler.agent_descriptions) |tracker| {
            _ = tracker.observeSubmittedPrompt(agent_identity.fromPane(pane), operation.action.prompt.text);
        }
    }
    return pane.key();
}

test "agent controls reject a terminal and stale generation before touching provider state" {
    var fixture: @import("../../tests/PaneFixture.zig") = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try panes.insert(fixture.pane);
    var titles: Tracker = .{};
    var handler: @This() = .{ .io = std.testing.io, .panes = &panes, .agent_descriptions = &titles };
    try std.testing.expectError(error.NotAnAgentPane, handler.execute(.{ .pane = fixture.pane.key(), .action = .{ .prompt = .{ .text = "hello", .options = .{} } } }));
    var stale = fixture.pane.key();
    stale.generation += 1;
    try std.testing.expectError(error.PaneNotFound, handler.execute(.{ .pane = stale, .action = .interrupt }));
    try std.testing.expectEqual(@as(usize, 0), fixture.pane.input_queue.len);
    try std.testing.expect(titles.nextDescriptionJob() == null);
    try std.testing.expectEqual(@as(u64, 1), titles.revision);
}

test "rejected managed prompt cannot consume first title capture" {
    const core = @import("telar-core");
    const Session = @import("../../../agent_panes/Session.zig");
    var fixture: @import("../../tests/PaneFixture.zig") = .{};
    try fixture.init();
    defer fixture.deinit();
    var panes: PaneStore = .{};
    try panes.insert(fixture.pane);
    var titles: Tracker = .{};
    var handler: @This() = .{ .io = std.testing.io, .panes = &panes, .agent_descriptions = &titles };

    const session = try Session.init(std.testing.io, std.testing.allocator, .{
        .pane_id = fixture.pane.id,
        .pane_generation = fixture.pane.generation,
        .cwd = "/",
        .arguments = &.{ "/bin/sleep", "60" },
    });
    defer session.close(std.testing.io);
    const original = fixture.pane.session;
    fixture.pane.session = .{ .agent = .{ .io = std.testing.io, .session = session } };
    fixture.pane.kind = .agent;
    defer {
        fixture.pane.session = original;
        fixture.pane.kind = .terminal;
        fixture.pane.agent_thread = null;
    }

    var snapshot: core.AgentThreadSnapshot = .{ .pane_id = fixture.pane.id, .pane_generation = fixture.pane.generation, .model_count = 1 };
    try snapshot.options.setModel("fake-model");
    snapshot.options.effort = try core.AgentEffort.init("low");
    snapshot.model_storage[0].id_len = snapshot.options.model_len;
    @memcpy(snapshot.model_storage[0].id[0..snapshot.options.model_len], snapshot.options.modelSlice());
    snapshot.model_storage[0].effort_storage[0] = snapshot.options.effort;
    snapshot.model_storage[0].effort_count = 1;
    fixture.pane.agent_thread = &snapshot;
    const identity = agent_identity.fromPane(fixture.pane);
    _ = titles.observeManaged(identity, .{ .status = .ready, .observed_at_ms = 100 });
    const before = titles.revision;

    try std.testing.expectError(error.InvalidAgentOptions, handler.execute(.{ .pane = fixture.pane.key(), .action = .{ .prompt = .{ .text = "Rejected options", .options = .{} } } }));
    try std.testing.expectError(error.AgentBusy, handler.execute(.{ .pane = fixture.pane.key(), .action = .{ .prompt = .{ .text = "Provider is not ready", .options = snapshot.options } } }));
    try std.testing.expectEqual(before, titles.revision);
    try std.testing.expect(titles.nextDescriptionJob() == null);
    try std.testing.expect(titles.observeSubmittedPrompt(identity, "Later accepted prompt"));
    var job = titles.nextDescriptionJob().?;
    defer std.crypto.secureZero(u8, &job.query);
    try std.testing.expectEqualStrings("Later accepted prompt", job.querySlice());
}

test "resume authority rejects stale selections and reserves a conversation across panes" {
    const core = @import("telar-core");
    const Session = @import("../../../agent_panes/Session.zig");
    const script =
        \\while IFS= read -r line; do
        \\ case "$line" in
        \\ *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
        \\ *'"method":"model/list"'*) printf '%s\n' '{"id":0,"result":{"data":[{"model":"fake-model","displayName":"Fake","supportedReasoningEfforts":[{"reasoningEffort":"low"}],"defaultReasoningEffort":"low"}]}}' ;;
        \\ *'"method":"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"fresh-thread"},"model":"fake-model","reasoningEffort":"low","approvalPolicy":"untrusted","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite"}}}' ;;
        \\ *'"method":"thread/list"'*) printf '%s\n' '{"id":2147483647,"result":{"data":[{"id":"previous-thread","cwd":"/","name":"Parser fixes"}]}}' ;;
        \\ esac
        \\done
    ;
    const io = std.testing.io;
    var fixture: @import("../../tests/PaneFixture.zig") = .{};
    try fixture.init();
    defer fixture.deinit();
    const second = try fixture.createPane(@enumFromInt(8));
    defer {
        second.session.shutdown();
        second.destroy();
    }
    const first_session = try Session.init(io, std.testing.allocator, .{ .pane_id = fixture.pane.id, .pane_generation = fixture.pane.generation, .cwd = "/", .arguments = &.{ "/bin/sh", "-c", script } });
    defer first_session.close(io);
    const second_session = try Session.init(io, std.testing.allocator, .{ .pane_id = second.id, .pane_generation = second.generation, .cwd = "/", .arguments = &.{ "/bin/sh", "-c", script } });
    defer second_session.close(io);
    var snapshots: [2]core.AgentThreadSnapshot = undefined;
    for ([_]*Session{ first_session, second_session }, &snapshots) |session, *snapshot| {
        var ready = false;
        for (0..2000) |_| {
            if (session.snapshot(io, snapshot) != null and snapshot.status == .ready and snapshot.recent.phase == .ready) {
                ready = true;
                break;
            }
            try io.sleep(.fromMilliseconds(1), .awake);
        }
        try std.testing.expect(ready);
    }

    const originals = .{ fixture.pane.session, second.session };
    fixture.pane.kind = .agent;
    fixture.pane.session = .{ .agent = .{ .io = io, .session = first_session } };
    fixture.pane.agent_thread = &snapshots[0];
    second.kind = .agent;
    second.session = .{ .agent = .{ .io = io, .session = second_session } };
    second.agent_thread = &snapshots[1];
    defer {
        fixture.pane.kind = .terminal;
        fixture.pane.session = originals[0];
        fixture.pane.agent_thread = null;
        second.kind = .terminal;
        second.session = originals[1];
        second.agent_thread = null;
    }

    var panes: PaneStore = .{};
    try panes.insert(fixture.pane);
    try panes.insert(second);
    var handler: @This() = .{ .io = io, .panes = &panes };
    var stale = fixture.pane.key();
    stale.generation += 1;
    try std.testing.expectError(error.PaneNotFound, handler.execute(.{ .pane = stale, .action = .{ .resume_conversation = 0 } }));
    try std.testing.expectError(error.InvalidConversation, handler.execute(.{ .pane = fixture.pane.key(), .action = .{ .resume_conversation = 1 } }));
    _ = try handler.execute(.{ .pane = fixture.pane.key(), .action = .{ .resume_conversation = 0 } });
    try std.testing.expectError(error.ConversationAlreadyOpen, handler.execute(.{ .pane = second.key(), .action = .{ .resume_conversation = 0 } }));
}
