//! Native hover and link ownership across asynchronous state transitions.
const keyinput = @import("keyinput");
const cellgrid = @import("cellgrid");
const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("LinkFixture.zig");
const HostRequest = @import("../native/HostRequest.zig").HostRequest;
const Session = @import("Session.zig");
const PointerHover = @import("../input/PointerHover.zig");

test "captured native link consumes stationary modifier motion before release" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const session = fixture.session;
    session.gui.app.model.panes.find(Session.pane_id).?.mouse = .{ .tracking = .any, .sgr = true };
    try fixture.present();
    var event = fixture.event(1);
    event.mods |= 1;
    try fixture.send(event);
    try std.testing.expect(session.gui.pointer.owners[0] == .link);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    // AppKit flagsChanged and Wayland modifiers emit motion without a drag.
    event.code = 6;
    event.mods = 1;
    try fixture.send(event);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    // Dropping the modifier leaves the same link under the pointer, so the
    // claimed press still opens on release without leaking to the child.
    event.code = 2;
    try fixture.send(event);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expectEqual(@as(usize, 1), fixture.session.link_open_count);
}

test "native link click cannot open a replacement URL before its frame is presented" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try receiveLink(fixture, 2, "https://b.c");
    try fixture.session.settle();
    try std.testing.expectEqual(@as(u64, 2), fixture.session.gui.app.model.panes.find(Session.pane_id).?.pending_frame_id);
    try fixture.send(fixture.event(1));
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.session.link_open_count);

    try fixture.present();
    try fixture.send(fixture.event(1));
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 1), fixture.session.link_open_count);
    try std.testing.expectEqualStrings("https://b.c", fixture.session.opened_link.?.uri());
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
    try std.testing.expectEqual(@as(usize, 0), fixture.session.link_open_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
}

test "native link gesture remains cancelled after switching tabs away and back" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const model = &fixture.session.gui.app.model;
    const second: core.TabId = @enumFromInt(2);
    _ = try data.tab_creation.create(model, .{ .created = .{ .location = .{ .workspace = Session.location.workspace, .tab_id = second }, .position = 1, .label = "second", .root_pane_id = @enumFromInt(20) }, .size = model.host.host_size });
    _ = try data.tab_selection.commitSelection(model, .{ .tab_id = Session.location.tab_id });
    try fixture.present();
    try fixture.send(fixture.event(1));
    _ = try data.tab_selection.commitSelection(model, .{ .tab_id = second });
    try fixture.present();
    _ = try data.tab_selection.commitSelection(model, .{ .tab_id = Session.location.tab_id });
    try fixture.present();
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.session.link_open_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
}

test "native link hover clears on focus loss while transport defers gesture recovery" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    try fixture.send(fixture.event(1));
    try std.testing.expect(gui.pointer.hover.link != null);
    while (gui.app.model.to_runtime.hasCapacity()) {
        try gui.app.model.to_runtime.push(.{ .detach_pane = .{ .pane_id = Session.pane_id } });
    }

    try input_support.focus(gui, false);
    _ = try gui.update();
    try std.testing.expectEqual(@as(usize, 0), gui.app.model.to_runtime.availableCapacity());
    try std.testing.expect(gui.input_queue.recovery.queued);
    try std.testing.expect(gui.pointer.hover.link == null);
    try std.testing.expectEqual(.default, gui.pointer.hover.shape);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.link_open_count);
}

test "native pointer refreshes after resize ownership ends without a model or GPU update" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const session = fixture.session;
    const gui = session.gui;
    const size = try gui.resizeViewport(
        .{
            .width = @as(u32, session.gui.renderer.metrics.cell_width) * 120 + 292,
            .height = @as(u32, session.gui.renderer.metrics.cell_height) * 12 + session.gui.renderer.chrome.vertical(),
            .scale = 1,
        },
    );
    try gui.resize(size, session.gui.renderer.theme);
    gui.pointer.configure(session.gui.renderer.origin, size);
    try fixture.present();
    const hits = &gui.chrome.presented().band_hits;
    const divider = for (hits.items[0..hits.len]) |hit| {
        if (hit.action == .resize_sidebar) {
            break hit.area;
        }
    } else return error.MissingSidebarDivider;
    _ = gui.chrome.bandPointer(.{ .kind = .press, .x = divider.x + 1, .y = divider.y + 1 });
    try std.testing.expect(gui.chrome.sidebar_resize_active);
    // The pointer moves over pane text while the band owns the drag.
    var moved = fixture.event(6);
    moved.mods = 0;
    try fixture.send(moved);
    try std.testing.expectEqual(.col_resize, gui.pointer.hover.shape);

    const version = gui.app.model.version();
    var released = moved;
    released.code = 2;
    try fixture.send(released);
    try std.testing.expect(!gui.chrome.sidebar_resize_active);
    try std.testing.expectEqualDeep(version, gui.app.model.version());
    _ = try gui.update();
    try std.testing.expectEqual(.pointer, gui.pointer.hover.shape);
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
    gui.adoptBindings(
        .{
            .prefix = try keyinput.chord.parseKey("ctrl+space"),
            .bindings = &.{},
            .sequence_timeout_ns = 10 * std.time.ns_per_s,
        },
    );
    try fixture.send(.{ .kind = 4, .code = ' ', .mods = 4, .physical = 50 });
    try fixture.send(.{ .kind = 4, .code = ' ', .physical = 50, .phase = 3 });
    try std.testing.expect(gui.router.prefixPending());
    var pointer = fixture.event(code);
    pointer.mods = 0;
    try fixture.send(pointer);
    try std.testing.expect(gui.router.prefixPending());
    try fixture.send(.{ .kind = 1, .text = "z".ptr, .len = 1 });
    try std.testing.expect(gui.app.model.tabs.layout[gui.app.model.tabs.active].isFullscreen());
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
}

fn receiveLink(fixture: *Fixture, frame_id: u64, text: []const u8) !void {
    const pane = fixture.session.gui.app.model.panes.find(Session.pane_id).?;
    var cells: [256]cellgrid.Cell = @splat(.{});
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
    _ = try client.runtime_messages.handleServerMessage(fixture.session.gui.app, try core.decodeServer(encoded));
    @memset(&wire, 0xff);
}

test "native displayed link tooltips consume hidden URL clicks until replacement delivery" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const pane = gui.app.model.panes.find(Session.pane_id).?;
    try fixture.send(fixture.event(6));
    try fixture.present();
    const preview = gui.pointer.hover.shown_preview.?;
    // A second URL sits on a pane row the card covers.
    const view = data.tab_layout.view(&gui.app.model, gui.app.model.tabs.active, Session.pane_id, data.workbench.region(&gui.app.model).area).?;
    try std.testing.expect(preview.y > view.content.y and preview.y < view.content.y + view.content.h);
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = preview.y - view.content.y }, .text = "https://b.c", .style = .{} });
    pane.markSpan(0, @intCast(pane.buffer.cells.len));
    try fixture.present();
    try std.testing.expectEqualDeep(@as(?cellgrid.Rect, preview), gui.pointer.hover.shown_preview);
    const size = gui.app.model.host.host_size;
    var pointer = fixture.event(6);
    pointer.x = @as(f64, @floatFromInt(preview.x + 2)) * size.cell_width_px + @as(f64, @floatFromInt(fixture.session.gui.renderer.origin[0])) + 1;
    pointer.y = @as(f64, @floatFromInt(preview.y)) * size.cell_height_px + @as(f64, @floatFromInt(fixture.session.gui.renderer.origin[1])) + 1;
    try fixture.send(pointer);
    try std.testing.expect(gui.pointer.hover.link == null);
    try std.testing.expectEqual(.default, gui.pointer.hover.shape);
    pointer.code = 1;
    try fixture.send(pointer);
    try std.testing.expectEqual(@as(?u8, 0), gui.overlays.gesture);
    pointer.code = 2;
    try fixture.send(pointer);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.link_open_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);

    try fixture.present();
    try std.testing.expect(gui.pointer.hover.shown_preview == null);
    pointer.code = 6;
    try fixture.send(pointer);
    try std.testing.expectEqualStrings("https://b.c", gui.pointer.hover.link.?.match.target.uri());
    pointer.code = 1;
    try fixture.send(pointer);
    pointer.code = 2;
    try fixture.send(pointer);
    try std.testing.expectEqual(@as(usize, 1), fixture.session.link_open_count);
    try std.testing.expectEqualStrings("https://b.c", fixture.session.opened_link.?.uri());
}

test "native preview coverage survives pointer leave failed presentation and late completions" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    try fixture.send(fixture.event(6));
    try fixture.present();
    const preview = gui.pointer.hover.shown_preview.?;
    try fixture.send(fixture.event(7));
    try std.testing.expect(gui.pointer.hover.link == null);
    try std.testing.expectEqualDeep(@as(?cellgrid.Rect, preview), gui.pointer.hover.shown_preview);
    const token = try fixture.session.draw();
    try std.testing.expect(gui.pointer.hover.prepared_preview == null);
    try input_support.presented(
        gui,
        token + 1,
        true,
    );
    try std.testing.expectEqualDeep(@as(?cellgrid.Rect, preview), gui.pointer.hover.shown_preview);
    try input_support.presented(
        gui,
        token,
        false,
    );
    try fixture.session.settle();
    try std.testing.expectEqualDeep(@as(?cellgrid.Rect, preview), gui.pointer.hover.shown_preview);

    const pane = gui.app.model.panes.find(Session.pane_id).?;
    pane.mouse = .{ .tracking = .button, .sgr = true };
    const size = gui.app.model.host.host_size;
    var pointer = fixture.event(1);
    pointer.mods = 0;
    pointer.x = @as(f64, @floatFromInt(preview.x)) * size.cell_width_px + @as(f64, @floatFromInt(fixture.session.gui.renderer.origin[0])) + 1;
    pointer.y = @as(f64, @floatFromInt(preview.y)) * size.cell_height_px + @as(f64, @floatFromInt(fixture.session.gui.renderer.origin[1])) + 1;
    try fixture.send(pointer);
    try fixture.present();
    try std.testing.expect(gui.pointer.hover.shown_preview == null);
    try std.testing.expectEqual(@as(?u8, 0), gui.overlays.gesture);
    pointer.code = 3;
    pointer.y = fixture.event(3).y;
    try fixture.send(pointer);
    pointer.code = 2;
    try fixture.send(pointer);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.link_open_count);
    try std.testing.expect(gui.overlays.gesture == null);
    // The pointer now rests on the link without a modifier: its card shows again.
    try fixture.present();
    try std.testing.expectEqualStrings("https://a.b", gui.pointer.hover.link.?.match.target.uri());
    try std.testing.expect(gui.pointer.hover.shown_preview != null);
}

test "native hover computes absolute rows without adding the host offset to history" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const tab = gui.app.model.tabs.active;
    const second: core.PaneId = @enumFromInt(11);
    try data.pane_split.split(&gui.app.model, tab, .{ .existing_pane = Session.pane_id, .new_pane = second, .location = Session.location, .axis = .vertical, .area = data.workbench.region(&gui.app.model).area });
    const pane = gui.app.model.panes.find(second).?;
    pane.attached = true;
    pane.cursor.visible = false;
    pane.scroll = .{ .total_rows = std.math.maxInt(u32), .offset = std.math.maxInt(u32) - @as(u32, pane.buffer.h) };
    pane.buffer.fill(pane.buffer.area(), .{ .glyph = " ", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 0 }, .text = "https://b.c", .style = .{} });
    pane.markSpan(0, @intCast(pane.buffer.cells.len));
    try fixture.present();
    const view = data.tab_layout.view(&gui.app.model, tab, second, data.workbench.region(&gui.app.model).area).?;
    try std.testing.expect(view.content.y > pane.buffer.h);
    const size = gui.app.model.host.host_size;
    var pointer = fixture.event(6);
    pointer.x = @as(f64, @floatFromInt(view.content.x + 2)) * size.cell_width_px + @as(f64, @floatFromInt(fixture.session.gui.renderer.origin[0])) + 1;
    pointer.y = @as(f64, @floatFromInt(view.content.y)) * size.cell_height_px + @as(f64, @floatFromInt(fixture.session.gui.renderer.origin[1])) + 1;
    try fixture.send(pointer);
    try std.testing.expectEqualStrings("https://b.c", gui.pointer.hover.link.?.match.target.uri());
    try std.testing.expectEqual(pane.scroll.offset, gui.pointer.hover.link.?.match.start.y);
}

test "native link tooltips sit beside their row and skip a pane too short to hold one" {
    const Hit = @import("../input/LinkHit.zig");
    const LinkTooltip = @import("../widgets/LinkTooltip.zig");
    const TerminalMetrics = @import("../TerminalMetrics.zig");
    const metrics: TerminalMetrics = .{ .cell_width = 8, .cell_height = 16, .baseline = 12, .pixel_height = 14 };
    var hit: Hit = .{
        .pane_id = Session.pane_id,
        .generation = 1,
        .location = Session.location,
        .content = .{ .x = 2, .y = 3, .w = 20, .h = 1 },
        .area = .{ .x = 2, .y = 3, .w = 11, .h = 1 },
        .match = .{
            .target = try data.LinkTarget.init("https://a.b"),
            .start = .{
                .x = 0,
                .y = 0,
            },
            .end = .{
                .x = 11,
                .y = 0,
            },
        },
    };
    try std.testing.expect(LinkTooltip.place(&hit, metrics, .{ 0, 0 }, .{}) == null);
    var hover: PointerHover = .{ .link = hit };
    hover.prepare(null);
    hover.present(true);
    try std.testing.expect(hover.shown_preview == null);
    try std.testing.expect(hover.openable());

    hit.content.h = 8;
    const area = LinkTooltip.place(&hit, metrics, .{ 0, 0 }, .{}).?;
    const anchor = metrics.rect(.{ 0, 0 }, hit.area);
    try std.testing.expect(area.y >= anchor.y + anchor.height or area.y + area.height <= anchor.y);
    const bounds = metrics.rect(.{ 0, 0 }, hit.content);
    try std.testing.expect(area.x >= bounds.x and area.x + area.width <= bounds.x + bounds.width);
    try std.testing.expect(area.y >= bounds.y and area.y + area.height <= bounds.y + bounds.height);
    const covered = LinkTooltip.cover(area, metrics, .{ 0, 0 });
    try std.testing.expect(!covered.contains(hit.area.x, hit.area.y));
    try std.testing.expect(covered.w > 0 and covered.h > 0);
}

test "native right click copies a link without modifiers or child mouse reports" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const session = fixture.session;
    session.gui.app.model.panes.find(Session.pane_id).?.mouse = .{ .tracking = .any, .sgr = true };
    try fixture.present();
    var event = fixture.event(1);
    event.button = 2;
    event.mods = 0;
    try fixture.send(event);
    event.code = 3;
    try fixture.send(event);
    event.code = 2;
    try fixture.send(event);
    var request: HostRequest = .{};
    try std.testing.expect(session.gui.host.next(&request));
    try std.testing.expectEqualStrings("https://a.b", request.text.?[0..request.len]);
    try std.testing.expectEqual(@as(u64, 0), session.gui.widgets.copy_feedback.until_ns);
    try fixture.send(.{ .kind = 9, .code = 0, .request_id = request.request_id, .target_id = request.target_id, .generation = request.generation });
    try std.testing.expect(session.gui.widgets.copy_feedback.until_ns > 0);
    try std.testing.expect(session.gui.widgets.copy_feedback.pending == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.session.link_open_count);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try std.testing.expect(!session.gui.host.next(&request));
}
