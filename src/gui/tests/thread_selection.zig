const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ThreadSelectionFixture.zig");
const reader = @import("../widgets/interaction/thread_selection.zig");

fn copy(fixture: *Fixture) !@import("../native/native.zig").HostRequest {
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("c") }, .mods = .{ .super = true } } });
    return fixture.clipboard();
}

test "mouse selection spans Markdown code and messages and copies only displayed text" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.drag(.{ try fixture.point(2, "First"), try fixture.point(3, "selectable") });
    const gui = fixture.session.gui;
    try std.testing.expect(gui.widgets.thread_selection.selected());
    try fixture.publish();
    try std.testing.expect(gui.app.model.agentPane(Fixture.pane_id).?.agent_history.?.retained);
    const request = try copy(&fixture);
    const text = request.text.?[0..request.len];
    try std.testing.expect(std.mem.indexOf(u8, text, "First bold answer and input.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "const value = 42;") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Second answer with ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "https://") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "```zig") == null);
    try std.testing.expect(!gui.app.model.copyModeActive());
    try std.testing.expectEqualStrings("", gui.app.model.agentPane(Fixture.pane_id).?.composerSlice());
}

test "user text is literal and warm drag and copy allocate nothing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const first = try fixture.point(1, "User");
    const last = try fixture.point(1, " request");
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const pane = gui.app.model.workspace.findPane(Fixture.pane_id).?;
    pane.gpa = failing.allocator();
    gui.app.gpa = failing.allocator();
    defer pane.gpa = std.testing.allocator;
    defer gui.app.gpa = std.testing.allocator;
    try fixture.drag(.{ first, last });
    const request = try copy(&fixture);
    try std.testing.expectEqualStrings("User **literal**", request.text.?[0..request.len]);
    try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
}

test "shift click keeps the pinned source after live updates and resizing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.drag(.{ try fixture.point(2, "First"), try fixture.point(2, " answer") });
    try fixture.publish();
    const gui = fixture.session.gui;
    const pinned = gui.app.model.agentPane(Fixture.pane_id).?.agent_history.?;
    try fixture.messages(&.{ "changed user", "new response with unrelated bytes", "latest output" });
    const size = try gui.measure(&fixture.session.renderer, .{ .width = 850, .height = 800, .scale = 1 });
    try gui.resize(size, fixture.session.renderer.theme);
    gui.input.setGeometry(fixture.session.renderer.origin, size);
    try fixture.publish();
    const point = try fixture.point(3, "selectable");
    try fixture.send(.{ .pointer = .{ .kind = .press, .mods = 1, .x = point[0], .y = point[1] } });
    try fixture.send(.{ .pointer = .{ .kind = .release, .x = point[0], .y = point[1] } });
    try fixture.publish();
    try std.testing.expect(gui.widgets.thread_selection.selected());
    try std.testing.expect(pinned == gui.app.model.agentPane(Fixture.pane_id).?.agent_history.?);
    const request = try copy(&fixture);
    try std.testing.expect(std.mem.startsWith(u8, request.text.?[0..request.len], "First bold answer"));
    try std.testing.expect(std.mem.indexOf(u8, request.text.?[0..request.len], "latest output") == null);
}

test "selection freezes paging and exposes edge state until Escape releases the window" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.drag(.{ try fixture.point(1, "User"), try fixture.point(3, "words") });
    try fixture.publish();
    const gui = fixture.session.gui;
    const target = try fixture.target(.transcript);
    try fixture.send(.{ .scroll = .{ .x = target.bounds.x + 5, .y = target.bounds.y + 5, .delta_y = -10000 } });
    try std.testing.expect(gui.widgets.thread_selection.blocked_edge);
    try std.testing.expect(gui.app.model.agentPane(Fixture.pane_id).?.history_intent == null);
    try std.testing.expect(!client.request_lifecycle.has(&gui.app, .agent_history));
    try fixture.send(.{ .key = .{ .code = .escape } });
    try fixture.publish();
    try std.testing.expect(gui.widgets.thread_selection.owner == null);
    try std.testing.expect(gui.app.model.agentPane(Fixture.pane_id).?.agent_history == null);
    try std.testing.expectEqual(Fixture.pane_id, gui.widgets.dispatcher.focusedTarget().?.action.composer);
}

test "a selected pane cannot steal focus from another agent composer" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const panes = gui.app.model.activeTabModel().?;
    const second: core.PaneId = @enumFromInt(20);
    try panes.split(.{ .existing_pane = Fixture.pane_id, .new_pane = second, .location = Fixture.location, .axis = .horizontal, .area = gui.region.area });
    try std.testing.expect(gui.app.model.identifyPane(.{ .request_id = @enumFromInt(2), .pane_id = second, .location = Fixture.location, .created = false, .kind = .agent, .pane_generation = 8 }));
    const snapshot = try std.testing.allocator.create(core.AgentThreadSnapshot);
    defer std.testing.allocator.destroy(snapshot);
    snapshot.* = panes.findConst(Fixture.pane_id).?.agent_thread.?.*;
    snapshot.pane_id = second;
    snapshot.pane_generation = 8;
    var bytes: [4096]u8 = undefined;
    _ = try gui.app.model.applyAgentThread((try core.decodeServer(try core.encodeAgentThreadSnapshot(&bytes, snapshot))).agent_thread_snapshot);
    _ = panes.focusPane(Fixture.pane_id);
    try fixture.publish();
    try fixture.drag(.{ try fixture.point(3, "Second"), try fixture.point(3, "words") });
    try fixture.publish();
    const registry = gui.widgets.dispatcher.maps.presented();
    const composer = for (registry.targets[0..registry.len]) |target| {
        if (target.action == .composer and target.action.composer == second) {
            break target;
        }
    } else return error.MissingSecondComposer;
    try fixture.send(.{ .pointer = .{ .kind = .press, .x = composer.bounds.x + 4, .y = composer.bounds.y + 4 } });
    try fixture.send(.{ .pointer = .{ .kind = .release, .x = composer.bounds.x + 4, .y = composer.bounds.y + 4 } });
    try fixture.publish();
    try fixture.send(.{ .text = .{ .bytes = "belongs to B" } });
    try std.testing.expectEqual(second, panes.layout.focused());
    try std.testing.expectEqualStrings("belongs to B", panes.findConst(second).?.composerSlice());
    try std.testing.expectEqualStrings("", panes.findConst(Fixture.pane_id).?.composerSlice());
    try std.testing.expect(gui.widgets.thread_selection.owner == null);
    try std.testing.expect(panes.findConst(Fixture.pane_id).?.agent_history == null);
}

test "stale text starts and focus loss cannot retain an invisible selection" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const start = try fixture.point(2, "First");
    const end = try fixture.point(3, "words");
    try fixture.messages(&.{ "changed", "changed", "changed" });
    try fixture.drag(.{ start, end });
    try std.testing.expect(!fixture.session.gui.widgets.thread_selection.selected());
    try fixture.publish();
    try std.testing.expect(reader.enter(fixture.session.gui, Fixture.pane_id));
    try fixture.publish();
    try fixture.session.gui.focus(false);
    try std.testing.expect(!reader.active(fixture.session.gui));
    try fixture.publish();
    try std.testing.expect(fixture.session.gui.app.model.agentPane(Fixture.pane_id).?.agent_history == null);
}

test "stationary drag scrolls delivered text and parks at the retained window edge" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.messages(&.{"line with readable words\n" ** 120});
    try fixture.publish();
    const gui = fixture.session.gui;
    const target = try fixture.target(.transcript);
    const x = target.bounds.x + 20;
    const y = target.bounds.y + target.bounds.height - 20;
    try fixture.send(.{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try fixture.send(.{ .pointer = .{ .kind = .drag, .x = x, .y = target.bounds.y - 12 } });
    const previous = gui.widgets.thread_selection.head.?;
    try fixture.publish();
    const pane = gui.app.model.agentPane(Fixture.pane_id).?;
    try std.testing.expect(pane.transcript_scroll > 0);
    try std.testing.expect(gui.widgets.thread_selection.head.?.before(previous));
    try std.testing.expect(gui.widgets.thread_selection.next_scroll_ns > 0);
    try std.testing.expect(pane.agent_history.?.retained);
    gui.app.model.workspace.findPane(Fixture.pane_id).?.transcript_scroll = (try fixture.target(.transcript)).scroll_limit;
    gui.widgets.thread_selection.next_scroll_ns = 0;
    try fixture.publish();
    try std.testing.expect(gui.widgets.thread_selection.blocked_edge);
    try std.testing.expect(pane.history_intent == null);
    try fixture.send(.{ .pointer = .{ .kind = .release, .x = x, .y = target.bounds.y - 12 } });
    try std.testing.expect(!gui.widgets.thread_selection.dragging);
    try std.testing.expectEqual(@as(i8, 0), gui.widgets.thread_selection.outside);
    const scroll = pane.transcript_scroll;
    try fixture.publish();
    try std.testing.expectEqual(scroll, pane.transcript_scroll);
}

test "copying a large retained window fails visibly without writing a partial clipboard" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.messages(&.{"word " ** 8000});
    const gui = fixture.session.gui;
    const pane = gui.app.model.agentPane(Fixture.pane_id).?;
    try std.testing.expect(try client.agent_history.freeze(&gui.app, Fixture.pane_id, pane.attachment_generation));
    const window = pane.agent_history.?;
    window.pages[1] = window.pages[0];
    window.pages[1].snapshot.item_storage[0].identity = 2;
    window.pages[1].snapshot.metadata_storage[window.pages[1].snapshot.item_storage[0].source_offset] = 'x';
    window.count = 2;
    try fixture.publish();
    try std.testing.expect(reader.enter(gui, Fixture.pane_id));
    try fixture.publish();
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("a") }, .mods = .{ .super = true } } });
    try fixture.send(.{ .key = .{ .code = .{ .char = .init("c") }, .mods = .{ .super = true } } });
    try std.testing.expectEqual(.copy_limit, gui.widgets.thread_selection.problem.?);
    try std.testing.expect(gui.widgets.thread_selection.selected());
    try std.testing.expect(gui.widgets.thread_selection.clipboard == null);
    try std.testing.expectError(error.MissingClipboardWrite, fixture.clipboard());
}
