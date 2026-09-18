const std = @import("std");
const client = @import("telar-client");
const Fixture = @import("ThreadSelectionFixture.zig");

test "configured copy-mode action enters the agent reader without VT state or draft edits" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    try fixture.send(.{ .text = .{ .bytes = "keep draft" } });
    const composer = try fixture.target(.composer);
    const binding = try client.config_model.ConfiguredBinding.parse(&.{"ctrl+q"}, .enter_copy_mode);
    gui.input.adopt(&gui.app, .{ .prefix = client.default_prefix, .bindings = &.{binding}, .escape_timeout_ns = std.time.ns_per_s, .sequence_timeout_ns = std.time.ns_per_s });
    try fixture.send(.{ .key = .{ .target_id = composer.id.target_id, .generation = composer.id.generation, .code = .{ .char = .init("q") }, .mods = .{ .ctrl = true }, .physical = .{ .value = 61 } } });
    try std.testing.expect(client.controllers.copy_modes.active(&gui.app));
    try std.testing.expect(!gui.app.model.copyModeActive());
    try std.testing.expect(gui.app.model.copy_state == null);
    try std.testing.expectEqual(.transcript, std.meta.activeTag(gui.widgets.dispatcher.focusedTarget().?.action));
    try fixture.send(.{ .key = .{ .target_id = composer.id.target_id, .generation = composer.id.generation, .code = .{ .char = .init("q") }, .physical = .{ .value = 61 }, .phase = .release } });
    try fixture.publish();
    const before = gui.widgets.thread_selection.head.?;
    try fixture.send(.{ .key = .{ .code = .left } });
    try std.testing.expect(gui.widgets.thread_selection.head.?.before(before));
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("v") } } });
    try fixture.send(.{ .key = .{ .code = .left } });
    try std.testing.expect(gui.widgets.thread_selection.selected());
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("y") } } });
    const request = try fixture.clipboard();
    try std.testing.expect(request.len > 0);
    try std.testing.expect(gui.widgets.thread_selection.keyboard);
    try fixture.ack(request, .success);
    try std.testing.expect(!gui.widgets.thread_selection.keyboard);
    try std.testing.expect(composer.id.eql(gui.widgets.dispatcher.focused.?));
    try std.testing.expectEqualStrings("keep draft", gui.app.model.agentPane(Fixture.pane_id).?.composerSlice());
    try std.testing.expectEqual(@as(usize, 0), gui.widgets.dispatcher.keys.len);
    try std.testing.expectEqual(@as(usize, 0), gui.input.router.leases.len);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
}

test "reader select-all copies rendered text and Escape restores the composer" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    try std.testing.expect(client.controllers.copy_modes.enter(&gui.app));
    try fixture.publish();
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("a") }, .mods = .{ .super = true } } });
    try std.testing.expect(gui.widgets.thread_selection.selected());
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("c") }, .mods = .{ .super = true } } });
    const request = try fixture.clipboard();
    const text = request.text.?[0..request.len];
    for ([_][]const u8{ "User **literal** request.", "First bold answer and input.", "const value = 42;", "Second answer with selectable words." }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);
    }
    for ([_][]const u8{ "https://example.test", "**bold**", "```" }) |hidden| {
        try std.testing.expect(std.mem.indexOf(u8, text, hidden) == null);
    }
    try fixture.ack(request, .success);
    try std.testing.expect(gui.widgets.thread_selection.keyboard);
    try fixture.send(.{ .key = .{ .code = .escape } });
    try std.testing.expect(!client.controllers.copy_modes.active(&gui.app));
    try std.testing.expect((try fixture.target(.composer)).id.eql(gui.widgets.dispatcher.focused.?));
    try fixture.publish();
    try std.testing.expect(gui.app.model.agentPane(Fixture.pane_id).?.agent_history == null);
}

test "reader Tab leaves selection and retains the focus selected by traversal" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    try std.testing.expect(client.controllers.copy_modes.enter(&gui.app));
    try fixture.publish();
    const transcript = try fixture.target(.transcript);
    try fixture.send(.{ .key = .{ .code = .tab } });
    const focused = gui.widgets.dispatcher.focused orelse return error.MissingTraversedFocus;
    try std.testing.expect(!focused.eql(transcript.id));
    try std.testing.expect(!client.controllers.copy_modes.active(&gui.app));
    try fixture.publish();
    try std.testing.expect(focused.eql(gui.widgets.dispatcher.focused.?));
    try std.testing.expect(gui.app.model.agentPane(Fixture.pane_id).?.agent_history == null);
    try std.testing.expectEqualStrings("", gui.app.model.agentPane(Fixture.pane_id).?.composerSlice());
}

test "reader failed copy keeps selection and an old success cannot close a newer range" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    try std.testing.expect(client.controllers.copy_modes.enter(&gui.app));
    try fixture.publish();
    try fixture.send(.{ .key = .{ .code = .home } });
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("v") } } });
    try fixture.send(.{ .key = .{ .code = .right } });
    const selected = gui.widgets.thread_selection.range().?;
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("y") } } });
    const failed = try fixture.clipboard();
    try fixture.ack(failed, .unavailable);
    try std.testing.expect(gui.widgets.thread_selection.keyboard);
    try std.testing.expectEqual(.copy_failed, gui.widgets.thread_selection.problem.?);
    try std.testing.expectEqualDeep(selected, gui.widgets.thread_selection.range().?);
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("y") } } });
    const previous = try fixture.clipboard();
    try fixture.send(.{ .key = .{ .code = .right, .mods = .{ .shift = true } } });
    const replacement = gui.widgets.thread_selection.range().?;
    try std.testing.expect(!replacement[1].eql(selected[1]));
    try fixture.ack(previous, .success);
    try std.testing.expect(gui.widgets.thread_selection.keyboard);
    try std.testing.expectEqualDeep(replacement, gui.widgets.thread_selection.range().?);
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("y") } } });
    try fixture.ack(try fixture.clipboard(), .success);
    try std.testing.expect(!gui.widgets.thread_selection.keyboard);
}

test "reader page movement retains a delivered caret for subsequent vertical keys" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.messages(&.{"line with readable words\n" ** 120});
    try fixture.publish();
    const gui = fixture.session.gui;
    try std.testing.expect(client.controllers.copy_modes.enter(&gui.app));
    try fixture.publish();
    const previous = gui.widgets.thread_selection.head.?;
    try fixture.send(.{ .key = .{ .code = .page_up } });
    try fixture.publish();
    const paged = gui.widgets.thread_selection.head.?;
    try std.testing.expect(paged.before(previous));
    try std.testing.expectEqual(@as(i8, 0), gui.widgets.thread_selection.pending_vertical);
    try fixture.send(.{ .key = .{ .code = .up } });
    try fixture.publish();
    const higher = gui.widgets.thread_selection.head.?;
    try std.testing.expect(higher.before(paged));
    try fixture.send(.{ .key = .{ .code = .down } });
    try fixture.publish();
    try std.testing.expect(higher.before(gui.widgets.thread_selection.head.?));
    try std.testing.expect(gui.widgets.thread_selection.keyboard);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
}
