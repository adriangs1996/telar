//! Native hover and link ownership across asynchronous state transitions.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("LinkFixture.zig");
const Session = @import("Session.zig");

test "captured native link consumes stationary modifier motion before release" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const session = fixture.session;
    session.gui.app.model.workspace.findPane(Session.pane_id).?.mouse = .{ .tracking = .any, .sgr = true };
    try fixture.present();
    var event = fixture.event(1);
    event.mods |= 1;
    try fixture.send(event);
    try std.testing.expect(session.gui.input.pointer.owners[0] == .link);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    // AppKit flagsChanged and Wayland modifiers emit motion without a drag.
    event.code = 6;
    event.mods = 1;
    try fixture.send(event);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    event.code = 2;
    try fixture.send(event);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
}

test "native link click cannot open a replacement URL before its frame is presented" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try receiveLink(fixture, 2, "https://b.c");
    try fixture.session.settle();
    try std.testing.expectEqual(@as(u64, 2), fixture.session.gui.app.model.workspace.findPane(Session.pane_id).?.pending_frame_id);
    try fixture.send(fixture.event(1));
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);

    try fixture.present();
    try fixture.send(fixture.event(1));
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 1), fixture.open_count);
    try std.testing.expectEqualStrings("https://b.c", fixture.opened.?.uri());
}

test "native link gesture remains cancelled after URL state changes from A to B to A" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.send(fixture.event(1));
    try receiveLink(fixture, 2, "https://b.c");
    try fixture.session.settle();
    try fixture.present();
    try receiveLink(fixture, 3, "https://a.b");
    try fixture.session.settle();
    try fixture.present();
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
}

test "native link gesture remains cancelled after switching tabs away and back" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    const second: core.TabId = @enumFromInt(2);
    _ = try model.createTab(.{ .created = .{ .location = .{ .workspace = Session.location.workspace, .tab_id = second }, .position = 1, .label = "second", .root_pane_id = @enumFromInt(20) }, .size = model.hostSize() });
    _ = try model.selectTab(.{ .tab_id = Session.location.tab_id });
    try fixture.present();
    try fixture.send(fixture.event(1));
    _ = try model.selectTab(.{ .tab_id = second });
    try fixture.present();
    _ = try model.selectTab(.{ .tab_id = Session.location.tab_id });
    try fixture.present();
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
}

test "native link hover clears on focus loss while transport defers gesture recovery" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    try fixture.send(fixture.event(1));
    try std.testing.expect(gui.input.pointer.hover.link != null);
    while (gui.app.runtime_transport.outbox.hasCapacity()) {
        try gui.app.runtime_transport.outbox.push(.{ .detach_pane = .{ .pane_id = Session.pane_id } });
    }

    try gui.focus(false);
    _ = try gui.pump();
    try std.testing.expectEqual(@as(usize, 0), client.runtime_io.availableCapacity(&gui.app));
    try std.testing.expect(gui.input.recovery.queued);
    try std.testing.expect(gui.input.pointer.hover.link == null);
    try std.testing.expectEqual(.default, gui.input.pointer.hover.shape);
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
}

test "native pointer refreshes after resize ownership ends without a model or GPU update" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const session = fixture.session;
    const gui = session.gui;
    const size = try session.renderer.measure(.{ .width = @as(u32, session.renderer.metrics.cell_width) * 120, .height = @as(u32, session.renderer.metrics.cell_height) * 12, .scale = 1 });
    try gui.resize(size, session.renderer.theme);
    gui.input.setGeometry(.{ 0, 0 }, size);
    try fixture.present();
    const hits = &gui.chrome.presented().hits;
    const divider = for (hits.items[0..hits.len]) |hit| {
        if (hit.action == .resize_sidebar) {
            break hit.area;
        }
    } else return error.MissingSidebarDivider;
    _ = gui.chrome.pointer(.{ .x = divider.x, .y = divider.y, .kind = .press });
    var moved = fixture.event(6);
    moved.mods = 0;
    try fixture.send(moved);
    try std.testing.expectEqual(.col_resize, gui.input.pointer.hover.shape);

    const version = gui.app.model.version();
    const mouse = gui.input.pointer.geometry.resolve(moved).?;
    _ = gui.chrome.pointer(.{ .x = mouse.x, .y = mouse.y, .kind = .release });
    try std.testing.expect(!gui.chrome.sidebar_resize_active);
    try std.testing.expectEqualDeep(version, gui.app.model.version());
    _ = try gui.pump();
    try std.testing.expectEqual(.text, gui.input.pointer.hover.shape);
}

test "native Ctrl-Space prefix survives stationary modifier motion" {
    try prefixAfterPointer(6);
}

test "native Ctrl-Space prefix survives pointer leave" {
    try prefixAfterPointer(7);
}

fn prefixAfterPointer(code: u32) !void {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    gui.input.adopt(&gui.app, .{ .prefix = try client.parseKey("ctrl+space"), .bindings = &.{}, .escape_timeout_ns = std.time.ns_per_s, .sequence_timeout_ns = 10 * std.time.ns_per_s });
    try fixture.send(.{ .kind = 4, .code = ' ', .mods = 4, .physical = 50 });
    try fixture.send(.{ .kind = 4, .code = ' ', .physical = 50, .phase = 3 });
    try std.testing.expect(gui.input.router.prefixPending());
    var pointer = fixture.event(code);
    pointer.mods = 0;
    try fixture.send(pointer);
    try std.testing.expect(gui.input.router.prefixPending());
    try fixture.send(.{ .kind = 1, .text = "z".ptr, .len = 1 });
    try std.testing.expect(gui.app.model.activeTabModel().?.layout.isFullscreen());
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
}

fn receiveLink(fixture: *Fixture, frame_id: u64, text: []const u8) !void {
    const pane = fixture.session.gui.app.model.workspace.findPane(Session.pane_id).?;
    var cells: [256]core.Cell = @splat(.{});
    const count = pane.buffer.cells.len;
    if (count > cells.len or text.len > pane.buffer.w) {
        return error.TestScreenTooLarge;
    }

    for (text, 0..) |byte, index| {
        cells[index].bytes[0] = byte;
    }

    var wire: [8192]u8 = undefined;
    const encoded = try core.encodePaneFrame(&wire, .{
        .pane_id = pane.id,
        .frame_id = frame_id,
        .base_frame_id = frame_id - 1,
        .cols = pane.buffer.w,
        .rows = pane.buffer.h,
        .cursor = .{ .visible = false, .x = 0, .y = 0 },
        .scroll = .{ .total_rows = pane.buffer.h, .offset = 0 },
        .spans = &.{.{ .start = 0, .cells = cells[0..count] }},
    });
    _ = try client.server_messages.handleServerMessage(&fixture.session.gui.app, try core.decodeServer(encoded));
    @memset(&wire, 0xff);
}
