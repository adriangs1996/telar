const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("ConversationFixture.zig");
const Flow = @import("../widgets/ThreadFlow.zig");
const Target = @import("../widgets/interaction/Target.zig");
const Window = client.AgentHistoryWindow;

fn snapshot(first: u64) !*core.AgentThreadSnapshot {
    const value = try std.testing.allocator.create(core.AgentThreadSnapshot);
    value.* = .{ .pane_id = @enumFromInt(1), .pane_generation = 7, .revision = first, .status = .ready, .item_count = 4, .truncated = true };
    for (value.item_storage[0..4], 0..) |*item, index| {
        var source: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&source, "message-{d}", .{first + index});
        const text = "A message with several readable words that wraps across the conversation.\nAnother line preserves a visible reading position.";
        item.* = .{ .identity = first + index, .role = .assistant, .status = .completed, .complete = true, .text_offset = value.text_len, .text_len = text.len, .source_offset = value.metadata_len, .source_len = @intCast(id.len) };
        @memcpy(value.text_storage[value.text_len..][0..text.len], text);
        @memcpy(value.metadata_storage[value.metadata_len..][0..id.len], id);
        value.text_len += text.len;
        value.metadata_len += @intCast(id.len);
    }
    const turn = "Turn-1";
    for (value.item_storage[0..4]) |*item| {
        item.source_turn_offset = value.metadata_len;
        item.source_turn_len = turn.len;
    }
    @memcpy(value.metadata_storage[value.metadata_len..][0..turn.len], turn);
    value.metadata_len += turn.len;
    return value;
}

fn flowFor(live: *const core.AgentThreadSnapshot) Flow {
    return .{ .bounds = .{ .x = 10, .y = 20, .width = 440, .height = 220 }, .thread = .{ .pane_id = live.pane_id, .agent = null, .composer = "", .kind = .agent, .attachment_generation = 3, .transcript = live } };
}

fn publish(fixture: *Fixture, flow: *Flow) !void {
    var canvas = fixture.canvas();
    const dispatcher = &fixture.state.?.dispatcher;
    _ = dispatcher.begin();
    try flow.resolve(&canvas);
    _ = try dispatcher.add(flow.navigation(.{ .bounds = flow.bounds, .id = .{ .generation = flow.thread.attachment_generation }, .action = .{ .transcript = flow.thread.pane_id }, .scroll_limit = flow.scroll_limit, .scroll_step = 24 }));
    dispatcher.seal();
    dispatcher.present(true);
}

fn rowY(flow: *const Flow, id: u64) !f32 {
    for (flow.rows[0..flow.len]) |view| {
        if (view.item.identity == id) {
            return view.bounds.y;
        }
    }
    return error.MissingHistoryRow;
}

fn foldedTurn(first: u64) !*core.AgentThreadSnapshot {
    const value = try snapshot(first);
    for (value.item_storage[0..3]) |*item| {
        item.role = .tool;
        item.kind = .command;
    }
    const turn = try std.fmt.bufPrint(value.metadata_storage[value.metadata_len..], "turn-{d}", .{first});
    for (value.item_storage[0..4]) |*item| {
        item.source_turn_offset = value.metadata_len;
        item.source_turn_len = @intCast(turn.len);
    }
    value.metadata_len += @intCast(turn.len);
    return value;
}

test "collapsed turns prefetch enough visible content without replacing the last response" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const live = try foldedTurn(1000);
    defer std.testing.allocator.destroy(live);
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);
    window.start(live, 1);
    const page = try std.testing.allocator.create(core.AgentHistoryPage);
    defer std.testing.allocator.destroy(page);
    var flow = flowFor(live);
    flow.bounds.height = 900;
    flow.thread.history = window;
    flow.thread.history_generation = 1;
    var loaded: usize = 0;
    while (loaded < Window.capacity) : (loaded += 1) {
        try publish(&fixture, &flow);
        flow.thread.transcript_scroll = flow.resolved_scroll;
        flow.thread.transcript_anchor_revision += 1;
        _ = try rowY(&flow, 1003);
        const navigation = flow.navigation(.{ .bounds = flow.bounds, .action = .{ .transcript = live.pane_id } });
        if (navigation.thread_prefetch == null) {
            break;
        }
        try std.testing.expectEqual(.older, navigation.thread_prefetch.?);
        const earlier = try foldedTurn(990 - loaded * 10);
        defer std.testing.allocator.destroy(earlier);
        page.* = .{ .request_id = @enumFromInt(1), .view_generation = 1, .snapshot = earlier.*, .has_before = true, .has_after = true };
        window.pending = .older;
        try std.testing.expect(window.apply(page));
    }
    try std.testing.expect(loaded > 2 and loaded < Window.capacity);
    try std.testing.expect(flow.height >= flow.bounds.height);
    try std.testing.expectEqual(2 * @as(usize, window.count), flow.len);
    for (flow.rows[1..flow.len], flow.rows[0 .. flow.len - 1]) |row, previous| {
        try std.testing.expectApproxEqAbs(previous.bounds.y + previous.bounds.height, row.bounds.y, 0.001);
    }
    const response_y = try rowY(&flow, 1003);
    flow.thread.transcript_scroll += 0.125 / 24.0;
    try publish(&fixture, &flow);
    try std.testing.expectApproxEqAbs(response_y + 0.125, try rowY(&flow, 1003), 0.001);
}

test "prefetch replaces only offscreen pages at capacity and preserves fractional anchors" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const live = try snapshot(1000);
    defer std.testing.allocator.destroy(live);
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);
    window.start(live, 1);
    for (0..Window.capacity) |index| {
        const source = try snapshot(100 + index * 10);
        defer std.testing.allocator.destroy(source);
        window.pages[index] = .{ .request_id = @enumFromInt(1), .view_generation = 1, .snapshot = source.*, .has_before = true, .has_after = true };
    }
    window.count = Window.capacity;
    var flow = flowFor(live);
    flow.thread.history = window;
    flow.thread.history_generation = 1;
    var canvas = fixture.canvas();
    try flow.resolve(&canvas);
    flow.thread.transcript_scroll = flow.scroll_limit - 0.125 / 24.0;
    try publish(&fixture, &flow);
    const before = try rowY(&flow, 100);
    try std.testing.expectEqual(.older, flow.navigation(.{ .bounds = flow.bounds, .action = .{ .transcript = live.pane_id } }).thread_prefetch.?);
    const earlier = try snapshot(90);
    defer std.testing.allocator.destroy(earlier);
    const page = try std.testing.allocator.create(core.AgentHistoryPage);
    defer std.testing.allocator.destroy(page);
    page.* = .{ .request_id = @enumFromInt(1), .view_generation = 1, .snapshot = earlier.*, .has_before = true, .has_after = true };
    window.pending = .older;
    try std.testing.expect(window.apply(page));
    try publish(&fixture, &flow);
    try std.testing.expectApproxEqAbs(before, try rowY(&flow, 100), 0.001);
    try std.testing.expectError(error.MissingHistoryRow, rowY(&flow, 100 + (Window.capacity - 1) * 10));
    try std.testing.expectEqual(@as(u8, Window.capacity), window.count);

    flow.bounds.height = flow.height + 100;
    flow.thread.transcript_scroll = 0;
    try publish(&fixture, &flow);
    try std.testing.expect(flow.navigation(.{ .bounds = flow.bounds, .action = .{ .transcript = live.pane_id } }).thread_prefetch == null);
}

test "prepending history preserves the delivered message anchor through failed delivery and resize" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const live = try snapshot(20);
    defer std.testing.allocator.destroy(live);
    const earlier = try snapshot(10);
    defer std.testing.allocator.destroy(earlier);
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);
    var flow = flowFor(live);
    var canvas = fixture.canvas();
    try flow.resolve(&canvas);
    flow.thread.transcript_scroll = flow.scroll_limit;
    try publish(&fixture, &flow);
    const before = try rowY(&flow, 20);
    window.start(live, 1);
    window.pending = .older;
    const page = try std.testing.allocator.create(core.AgentHistoryPage);
    defer std.testing.allocator.destroy(page);
    page.* = .{ .request_id = @enumFromInt(1), .view_generation = 1, .snapshot = earlier.*, .has_before = true, .has_after = true };
    try std.testing.expect(window.apply(page));
    flow.thread.history = window;
    flow.thread.history_generation = 1;
    _ = fixture.state.?.dispatcher.begin();
    try flow.resolve(&canvas);
    try std.testing.expect(flow.reanchored);
    try std.testing.expectApproxEqAbs(before, try rowY(&flow, 20), 0.01);
    fixture.state.?.dispatcher.seal();
    fixture.state.?.dispatcher.present(false);
    try publish(&fixture, &flow);
    try std.testing.expectApproxEqAbs(before, try rowY(&flow, 20), 0.01);
    flow.thread.transcript_scroll = flow.resolved_scroll;
    flow.thread.transcript_anchor_revision += 1;
    const position = try rowY(&flow, 20);
    try publish(&fixture, &flow);
    try std.testing.expectApproxEqAbs(position, try rowY(&flow, 20), 0.01);
    flow.bounds.width = 240;
    try publish(&fixture, &flow);
    try std.testing.expectApproxEqAbs(position, try rowY(&flow, 20), 0.01);
}

test "history seam deduplicates exact provider fragments and preserves the newer copy" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const live = try snapshot(20);
    defer std.testing.allocator.destroy(live);
    const earlier = try snapshot(17);
    defer std.testing.allocator.destroy(earlier);
    earlier.item_storage[3].identity = 999;
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);
    window.start(live, 1);
    window.pages[1] = window.pages[0];
    window.pages[0].snapshot = earlier.*;
    window.count = 2;
    var flow = flowFor(live);
    flow.thread.history = window;
    var canvas = fixture.canvas();
    try flow.resolve(&canvas);
    try std.testing.expectEqual(@as(usize, 7), flow.len);
    try std.testing.expectError(error.MissingHistoryRow, rowY(&flow, 999));
    _ = try rowY(&flow, 20);
    window.pages[0].snapshot.item_storage[3].fragment_offset = 400;
    window.pages[0].snapshot.item_storage[3].fragment_start = false;
    try flow.resolve(&canvas);
    try std.testing.expectEqual(@as(usize, 8), flow.len);
}

test "partial message fragments remain literal and expose an honest copy segment action" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const live = try snapshot(20);
    defer std.testing.allocator.destroy(live);
    const source = "[not a parsed link](https://example.test)\n```mermaid\nflowchart TD\n";
    live.item_count = 1;
    live.text_len = source.len;
    @memcpy(live.text_storage[0..source.len], source);
    live.item_storage[0].text_len = source.len;
    live.item_storage[0].fragment_start = false;
    live.item_storage[0].fragment_offset = 100;
    var flow = flowFor(live);
    flow.bounds.height = 500;
    var canvas = fixture.canvas();
    _ = fixture.state.?.dispatcher.begin();
    try flow.resolve(&canvas);
    try flow.draw(&canvas);
    const registry = fixture.state.?.dispatcher.maps.preparing();
    var copied = false;
    for (registry.targets[0..registry.len]) |target| {
        try std.testing.expect(target.action != .message_link);
        if (target.action == .thread_item and target.action.thread_item.operation == .copy) {
            copied = true;
            try std.testing.expectEqualStrings("Copy segment", target.label[0..target.label_len]);
        }
    }
    try std.testing.expect(copied);
}

test "history scroll can reach the beginning of two newline-heavy pages" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const live = try snapshot(20);
    defer std.testing.allocator.destroy(live);
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);
    window.start(live, 1);
    window.pages[1] = window.pages[0];
    window.count = 2;
    for (window.pages[0..window.count], 0..) |*page, index| {
        page.snapshot.item_count = 1;
        page.snapshot.item_storage[0].identity = index + 1;
        page.snapshot.item_storage[0].source_len = 0;
        page.snapshot.item_storage[0].fragment_end = false;
        page.snapshot.item_storage[0].text_offset = 0;
        page.snapshot.item_storage[0].text_len = core.agent_thread.max_text_bytes;
        page.snapshot.text_len = core.agent_thread.max_text_bytes;
        @memset(&page.snapshot.text_storage, '\n');
    }
    var flow = flowFor(live);
    flow.thread.history = window;
    var canvas = fixture.canvas();
    try flow.resolve(&canvas);
    try std.testing.expect(flow.scroll_limit > 65536);
    flow.thread.transcript_scroll = flow.scroll_limit;
    try flow.resolve(&canvas);
    try std.testing.expectApproxEqAbs(flow.bounds.y + 12, flow.rows[0].bounds.y, 0.01);
}

const Session = @import("Session.zig");

fn historySession() !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    const model = &session.gui.app.model;
    try std.testing.expect(model.identifyPane(.{ .request_id = @enumFromInt(1), .pane_id = Session.pane_id, .location = Session.location, .created = false, .kind = .agent, .pane_generation = 7 }));
    const live = try snapshot(20);
    defer std.testing.allocator.destroy(live);
    live.pane_id = Session.pane_id;
    var bytes: [4096]u8 = undefined;
    _ = try model.applyAgentThread((try core.decodeServer(try core.encodeAgentThreadSnapshot(&bytes, live))).agent_thread_snapshot);
    return session;
}

test "history request admission failure is retryable and stale failure only wakes queued navigation" {
    const session = try historySession();
    defer session.deinit();
    const app = &session.gui.app;
    const pane = app.model.workspace.findPane(Session.pane_id).?;
    app.request_lifecycle.next_request_id = std.math.maxInt(u64);
    client.agent_history.navigate(app, pane.id, .older);
    try client.agent_history.flush(app);
    try std.testing.expect(pane.agent_history.?.pending == null);
    try std.testing.expectEqualStrings("RequestIdExhausted", pane.agent_history.?.failureMessage());
    try std.testing.expect(!client.request_lifecycle.has(app, .agent_history));
    try client.agent_history.flush(app);
    try std.testing.expect(pane.agent_history.?.pending == null);
    app.request_lifecycle.next_request_id = 200;
    client.agent_history.navigate(app, pane.id, .older);
    try client.agent_history.flush(app);
    try std.testing.expect(client.request_lifecycle.has(app, .agent_history));
    client.agent_history.navigate(app, pane.id, .newer);
    const revision = app.model.panes_revision;
    const notification_revision = app.model.notifications_revision;
    var buffer: [1024]u8 = undefined;
    const bytes = try core.encodeRequestFailed(&buffer, .{ .request_id = @enumFromInt(200), .code = .internal, .message = "Obsolete timeout" });
    _ = try client.server_messages.handleServerMessage(app, try core.decodeServer(bytes));
    try std.testing.expect(!client.request_lifecycle.has(app, .agent_history));
    try std.testing.expect(app.model.panes_revision > revision);
    try std.testing.expectEqual(notification_revision, app.model.notifications_revision);
    try std.testing.expect(!pane.agent_history.?.failed);
    try client.agent_history.flush(app);
    try std.testing.expect(pane.agent_history != null);
    try std.testing.expect(pane.agent_history.?.pending == null);
}

test "history page loading starts after successful delivery and not after a failed frame" {
    const session = try historySession();
    defer session.deinit();
    const gui = session.gui;
    const pane = gui.app.model.workspace.findPane(Session.pane_id).?;
    client.agent_history.navigate(&gui.app, pane.id, .older);
    const failed = try gui.prepare(&session.renderer);
    try gui.complete(failed, false);
    try std.testing.expect(pane.agent_history == null);
    try std.testing.expect(!client.request_lifecycle.has(&gui.app, .agent_history));
    const delivered = try gui.prepare(&session.renderer);
    try gui.complete(delivered, true);
    try std.testing.expect(pane.agent_history != null);
    try std.testing.expect(client.request_lifecycle.has(&gui.app, .agent_history));
    try session.settle();
}

test "loading newer messages preserves the delivered anchor and earlier context" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const live = try snapshot(20);
    defer std.testing.allocator.destroy(live);
    const earlier = try snapshot(10);
    defer std.testing.allocator.destroy(earlier);
    const later = try snapshot(30);
    defer std.testing.allocator.destroy(later);
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);
    window.start(live, 1);
    window.pages[1] = window.pages[0];
    window.pages[0].snapshot = earlier.*;
    window.count = 2;
    var flow = flowFor(live);
    flow.thread.history = window;
    flow.thread.history_generation = 1;
    try publish(&fixture, &flow);
    const before = try rowY(&flow, 23);
    const page = try std.testing.allocator.create(core.AgentHistoryPage);
    defer std.testing.allocator.destroy(page);
    page.* = .{ .request_id = @enumFromInt(1), .view_generation = 1, .snapshot = later.*, .has_before = true, .has_after = true };
    window.pending = .newer;
    window.direction = .newer;
    try std.testing.expect(window.apply(page));
    try publish(&fixture, &flow);
    try std.testing.expectApproxEqAbs(before, try rowY(&flow, 23), 0.01);
    _ = try rowY(&flow, 10);
    try std.testing.expectEqual(@as(u8, 3), window.count);
    flow.thread.transcript_scroll = flow.resolved_scroll;
    flow.thread.transcript_anchor_revision += 1;
    const position = try rowY(&flow, 23);
    try publish(&fixture, &flow);
    try std.testing.expectApproxEqAbs(position, try rowY(&flow, 23), 0.01);
}

test "history outbound pressure clears pending state and keeps a visible retry reason" {
    const session = try historySession();
    defer session.deinit();
    const app = &session.gui.app;
    const outbox = &app.runtime_transport.outbox;
    while (outbox.hasCapacity()) {
        try outbox.push(.{ .query_agent_thread = .{ .request_id = @enumFromInt(900), .pane_id = Session.pane_id, .pane_generation = 7 } });
    }
    client.agent_history.navigate(app, Session.pane_id, .older);
    try client.agent_history.flush(app);
    const window = app.model.agentPane(Session.pane_id).?.agent_history.?;
    try std.testing.expect(window.pending == null);
    try std.testing.expectEqualStrings("ClientOutboxFull", window.failureMessage());
    try std.testing.expect(!client.request_lifecycle.has(app, .agent_history));
}

test "retired history replies wake visible navigation waiting for the connection slot" {
    const session = try historySession();
    defer session.deinit();
    const app = &session.gui.app;
    client.agent_history.navigate(app, Session.pane_id, .older);
    try client.request_lifecycle.register(app, .{ .request_id = @enumFromInt(500), .continuation = .ignored });
    var before = app.model.panes_revision;
    try std.testing.expect(!try client.agent_history.apply(app, .{ .request_id = @enumFromInt(500), .view_generation = 1, .snapshot = .{ .pane_id = Session.pane_id, .pane_generation = 7, .revision = 1, .encoded = "" }, .before = "", .after = "", .has_before = false, .has_after = false }));
    try std.testing.expect(app.model.panes_revision > before);
    try client.request_lifecycle.register(app, .{ .request_id = @enumFromInt(501), .continuation = .ignored });
    before = app.model.panes_revision;
    const notifications = app.model.notifications_revision;
    var bytes: [1024]u8 = undefined;
    const encoded = try core.encodeRequestFailed(&bytes, .{ .request_id = @enumFromInt(501), .code = .internal, .message = "Retired provider" });
    _ = try client.server_messages.handleServerMessage(app, try core.decodeServer(encoded));
    try std.testing.expect(app.model.panes_revision > before);
    try std.testing.expectEqual(notifications, app.model.notifications_revision);
}

test "historical copy and link targets resolve owned page bytes and retire on eviction" {
    const session = try historySession();
    defer session.deinit();
    const gui = session.gui;
    const pane = gui.app.model.workspace.findPane(Session.pane_id).?;
    const window = try std.testing.allocator.create(Window);
    window.start(pane.agent_thread.?, 1);
    pane.agent_history = window;
    const page = &window.pages[0].snapshot;
    const text = "Read [documentation](https://example.test/history)";
    const url = "https://example.test/history";
    @memcpy(page.text_storage[0..text.len], text);
    page.text_len = text.len;
    page.item_count = 1;
    page.item_storage[0].identity = 700;
    page.item_storage[0].text_len = text.len;
    const link: @import("../widgets/interaction/MessageLinkControl.zig") = .{ .owner = .{ .pane_id = pane.id, .attachment_generation = pane.attachment_generation, .pane_generation = pane.pane_generation, .snapshot_revision = page.revision, .item_identity = 700, .section = .body, .source_offset = 0 }, .destination_offset = @intCast(std.mem.indexOf(u8, text, url).?), .destination_len = url.len, .fragment_offset = 6 };
    const links = @import("../widgets/interaction/message_links.zig");
    try std.testing.expectEqualStrings(url, links.destination(gui, link).?);
    const target: Target = .{ .id = .{ .target_id = 900, .generation = pane.attachment_generation }, .bounds = .{ .x = 0, .y = 0, .width = 30, .height = 30 }, .action = .{ .thread_item = .{ .pane_id = pane.id, .attachment_generation = pane.attachment_generation, .identity = 700, .operation = .copy } } };
    const items = @import("../widgets/interaction/thread_items.zig");
    try std.testing.expect(items.eligible(gui, target));
    try items.activate(gui, target);
    var request: @import("../native/native.zig").HostRequest = .{};
    try std.testing.expect(gui.host.next(&request));
    try std.testing.expectEqualStrings(text, request.text.?[0..request.len]);
    pane.clearHistory();
    try std.testing.expect(links.destination(gui, link) == null);
    try std.testing.expect(!items.eligible(gui, target));
}

test "reused provider item IDs in different turns retain both messages anchors and disclosures" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const live = try snapshot(20);
    defer std.testing.allocator.destroy(live);
    const earlier = try snapshot(17);
    defer std.testing.allocator.destroy(earlier);
    earlier.item_storage[3].identity = 999;
    const repeated = &earlier.item_storage[3];
    @memcpy(earlier.metadata_storage[repeated.source_turn_offset..][0..6], "Turn-2");
    try std.testing.expectEqualStrings(repeated.sourceId(earlier), live.item_storage[0].sourceId(live));
    try std.testing.expect(!Window.sameFragment(.{ .snapshot = earlier, .item = repeated }, .{ .snapshot = live, .item = &live.item_storage[0] }));
    try std.testing.expect(Window.itemKey(earlier, repeated) != Window.itemKey(live, &live.item_storage[0]));
    var flow = flowFor(live);
    var canvas = fixture.canvas();
    try flow.resolve(&canvas);
    flow.thread.transcript_scroll = flow.scroll_limit;
    try publish(&fixture, &flow);
    const before = try rowY(&flow, 20);
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);
    window.start(live, 1);
    window.pages[1] = window.pages[0];
    window.pages[0].snapshot = earlier.*;
    window.count = 2;
    flow.thread.history = window;
    flow.thread.history_generation = 1;
    try publish(&fixture, &flow);
    try std.testing.expectEqual(@as(usize, 8), flow.len);
    try std.testing.expectApproxEqAbs(before, try rowY(&flow, 20), 0.01);
    var expansions: @import("../widgets/interaction/ThreadExpansions.zig") = .{};
    const old = flow.rows[3].control();
    const current = flow.rows[4].control();
    try std.testing.expectEqual(@as(u64, 999), old.identity);
    try std.testing.expectEqual(@as(u64, 20), current.identity);
    expansions.toggle(old);
    try std.testing.expect(!expansions.contains(current));
    var rehydrated = old;
    rehydrated.identity = 1001;
    try std.testing.expect(expansions.contains(rehydrated));
}

fn foldedHistorySession() !*Session {
    const session = try historySession();
    errdefer session.deinit();
    const pane = session.gui.app.model.workspace.findPane(Session.pane_id).?;
    const live = pane.agent_thread.?;
    for (live.item_storage[0..3]) |*item| {
        item.role = .tool;
        item.kind = .command;
    }

    const earlier = try snapshot(10);
    defer std.testing.allocator.destroy(earlier);
    earlier.pane_id = pane.id;
    for (earlier.item_storage[0..4]) |*item| {
        item.role = .tool;
        item.kind = .command;
    }

    const window = try std.testing.allocator.create(Window);
    window.start(live, 1);
    window.pages[1] = window.pages[0];
    window.pages[0].snapshot = earlier.*;
    window.pages[0].before = try core.AgentHistoryCursor.init("older-10");
    window.count = 2;
    pane.agent_history = window;
    pane.history_generation = 1;
    pane.transcript_scroll = 10000;
    return session;
}

fn deliverHistory(session: *Session, page: *core.AgentHistoryPage) !void {
    const app = &session.gui.app;
    page.request_id = @enumFromInt(app.request_lifecycle.next_request_id - 1);
    page.view_generation = app.model.agentPane(Session.pane_id).?.history_generation;
    var buffer: [8192]u8 = undefined;
    const response = (try core.decodeServer(try core.encodeAgentHistoryPage(&buffer, page))).agent_history_page;
    try std.testing.expect(try client.agent_history.apply(app, response));
}

test "one history gesture crosses folded pages without evicting the visible answer" {
    const session = try foldedHistorySession();
    defer session.deinit();
    const gui = session.gui;
    const pane = gui.app.model.agentPane(Session.pane_id).?;
    const window = pane.agent_history.?;
    const answer = window.pages[1].snapshot.items()[3].identity;
    const failed = try gui.prepare(&session.renderer);
    try gui.complete(failed, false);
    try std.testing.expect(!client.request_lifecycle.has(&gui.app, .agent_history));
    const delivered = try gui.prepare(&session.renderer);
    try gui.complete(delivered, true);
    try session.settle();
    try std.testing.expect(client.request_lifecycle.has(&gui.app, .agent_history));
    try std.testing.expect(window.preserve_seam);

    const page = try std.testing.allocator.create(core.AgentHistoryPage);
    defer std.testing.allocator.destroy(page);
    page.* = window.pages[0];
    page.before = try core.AgentHistoryCursor.init("older-6");
    for (page.snapshot.item_storage[0..4]) |*item| {
        item.identity -= 4;
        item.source_len = 0;
    }
    try deliverHistory(session, page);
    try std.testing.expect(window.findItem(answer) != null);
    const next = try gui.prepare(&session.renderer);
    try gui.complete(next, true);
    try session.settle();
    try std.testing.expect(client.request_lifecycle.has(&gui.app, .agent_history));
    try std.testing.expect(window.preserve_seam);

    page.before = try core.AgentHistoryCursor.init("older-1");
    page.snapshot.item_count = 1;
    page.snapshot.item_storage[0].identity = 1;
    page.snapshot.item_storage[0].role = .user;
    page.snapshot.item_storage[0].kind = .message;
    page.has_before = false;
    try deliverHistory(session, page);
    const with_prompt = try gui.prepare(&session.renderer);
    try gui.complete(with_prompt, true);
    try session.settle();
    try std.testing.expect(!client.request_lifecycle.has(&gui.app, .agent_history));
    try std.testing.expect(window.findItem(1) != null);
    try std.testing.expect(window.findItem(answer) != null);
    try std.testing.expectEqual(@as(u8, 2), window.count);
    try std.testing.expectEqual(.older, window.gaps[1].?.direction);

    client.agent_history.revealWork(&gui.app, pane.id, window.gaps[1].?.key);
    try std.testing.expectEqual(@as(u8, 1), window.count);
    try std.testing.expect(window.gaps[0] == null);
    try std.testing.expectEqual(answer, window.pages[0].snapshot.items()[3].identity);
    try std.testing.expectEqualStrings("", window.cursor(.older));
    try std.testing.expectEqual(.older, pane.history_intent.?);
    try std.testing.expectEqual(@as(u8, Window.max_scan_pages), window.scan_remaining);
}

test "expanded work and a different folded turn remain ordinary history stops" {
    const session = try foldedHistorySession();
    defer session.deinit();
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    const window = pane.agent_history.?;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var flow = flowFor(pane.agent_thread.?);
    flow.bounds.height = 10000;
    flow.thread.history = window;
    var canvas = fixture.canvas();
    try flow.resolve(&canvas);
    const target: Target = .{ .bounds = flow.bounds, .action = .{ .transcript = pane.id } };
    try std.testing.expect(flow.navigation(target).thread_skip_folded);
    fixture.state.?.thread_expansions.toggle(flow.rows[0].control());
    try flow.resolve(&canvas);
    try std.testing.expect(!flow.navigation(target).thread_skip_folded);
    fixture.state.?.thread_expansions.toggle(flow.rows[0].control());
    const old = &window.pages[0].snapshot;
    @memcpy(old.metadata_storage[old.items()[0].source_turn_offset..][0..6], "Turn-2");
    try flow.resolve(&canvas);
    try std.testing.expect(!flow.navigation(target).thread_skip_folded);
}

test "newer folded pages preserve the prompt and stop at the next public response" {
    const session = try foldedHistorySession();
    defer session.deinit();
    const pane = session.gui.app.model.agentPane(Session.pane_id).?;
    const window = pane.agent_history.?;
    window.pages[0].snapshot.item_storage[0].role = .user;
    window.pages[0].snapshot.item_storage[0].kind = .message;
    window.pages[1].snapshot.item_count = 3;
    window.pages[1].has_after = true;
    window.direction = .newer;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    var flow = flowFor(pane.agent_thread.?);
    flow.bounds.height = 10000;
    flow.thread.history = window;
    var canvas = fixture.canvas();
    try flow.resolve(&canvas);
    const target: Target = .{ .bounds = flow.bounds, .action = .{ .transcript = pane.id } };
    try std.testing.expect(flow.navigation(target).thread_skip_folded);

    window.pages[0].snapshot.item_storage[3].role = .assistant;
    window.pages[0].snapshot.item_storage[3].kind = .message;
    try flow.resolve(&canvas);
    try std.testing.expect(!flow.navigation(target).thread_skip_folded);
    window.pages[0].snapshot.item_storage[3].role = .tool;
    window.pages[0].snapshot.item_storage[3].kind = .command;

    const page = try std.testing.allocator.create(core.AgentHistoryPage);
    defer std.testing.allocator.destroy(page);
    page.* = window.pages[1];
    page.after = try core.AgentHistoryCursor.init("next-30");
    window.pending = .newer;
    window.preserve_seam = true;
    try std.testing.expect(window.apply(page));
    try std.testing.expectEqual(.newer, window.gaps[1].?.direction);
    try std.testing.expectEqual(core.agent_thread.Role.user, window.pages[0].snapshot.items()[0].role);

    page.snapshot.item_storage[0].kind = .message;
    page.snapshot.item_storage[0].role = .assistant;
    page.snapshot.item_count = 1;
    page.has_after = false;
    window.pending = .newer;
    window.preserve_seam = true;
    try std.testing.expect(window.apply(page));
    try flow.resolve(&canvas);
    try std.testing.expect(!flow.navigation(target).thread_skip_folded);
    try std.testing.expectEqual(.newer, window.revealWork(window.gaps[1].?.key).?);
    try std.testing.expectEqual(@as(u8, 1), window.count);
    try std.testing.expectEqual(core.agent_thread.Role.user, window.pages[0].snapshot.items()[0].role);
}

test "opening one skipped work group retains the boundaries of other groups" {
    const live = try foldedTurn(100);
    defer std.testing.allocator.destroy(live);
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);
    window.start(live, 1);
    for (1..4) |index| {
        window.pages[index] = window.pages[0];
        window.pages[index].snapshot.item_storage[0].identity += index;
    }
    window.count = 4;
    window.gaps[1] = .{ .key = 100, .direction = .older };
    window.gaps[3] = .{ .key = 200, .direction = .newer };
    live.revision += 1;
    try std.testing.expect(window.followLive(live));
    try std.testing.expectEqual(@as(u64, 200), window.gaps[3].?.key);
    try std.testing.expect(window.revealWork(300) == null);
    try std.testing.expectEqual(@as(u8, 4), window.count);
    try std.testing.expectEqual(.older, window.revealWork(100).?);
    try std.testing.expectEqual(@as(u8, 3), window.count);
    try std.testing.expectEqual(@as(u64, 101), window.pages[0].snapshot.items()[0].identity);
    try std.testing.expect(window.gaps[0] == null);
    try std.testing.expectEqual(@as(u64, 200), window.gaps[2].?.key);
    try std.testing.expectEqual(.newer, window.revealWork(200).?);
    try std.testing.expectEqual(@as(u8, 2), window.count);
    try std.testing.expectEqual(@as(u64, 102), window.pages[1].snapshot.items()[0].identity);
}

test "new live text stays at the bottom without resetting earlier history" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.enableCache();
    const live = try snapshot(20);
    defer std.testing.allocator.destroy(live);
    const older = try snapshot(10);
    defer std.testing.allocator.destroy(older);
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);
    window.start(live, 1);
    window.pages[1] = window.pages[0];
    window.pages[0].snapshot = older.*;
    window.count = 2;
    var flow = flowFor(live);
    flow.thread.history = window;
    flow.thread.history_generation = 1;
    try publish(&fixture, &flow);
    const before = try rowY(&flow, 23);
    const text = "\nOne more streamed line.";
    @memcpy(live.text_storage[live.text_len..][0..text.len], text);
    live.item_storage[3].text_len += text.len;
    live.text_len += text.len;
    live.revision += 1;
    try std.testing.expect(window.followLive(live));
    try publish(&fixture, &flow);
    try std.testing.expectEqual(@as(f64, 0), flow.resolved_scroll);
    try std.testing.expect(try rowY(&flow, 23) < before);
    _ = try rowY(&flow, 10);
    const last = flow.rows[flow.len - 1].bounds;
    try std.testing.expectApproxEqAbs(flow.bounds.y + flow.bounds.height, last.y + last.height, 0.001);
}
