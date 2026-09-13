const std = @import("std");
const core = @import("telar-core");
const Fixture = @import("LinkFixture.zig");
const Session = @import("Session.zig");

test "native links highlight with the platform modifier and open only on release" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    var move = fixture.event(6);
    move.mods = 0;
    try fixture.send(move);
    try std.testing.expectEqual(.text, gui.input.pointer.hover.shape);
    try std.testing.expect(gui.input.pointer.hover.link == null);
    try fixture.send(fixture.event(6));
    try std.testing.expectEqual(.pointer, gui.input.pointer.hover.shape);
    try std.testing.expectEqualStrings("https://a.b", gui.input.pointer.hover.link.?.match.target.uri());
    const revision = gui.input.pointer.hover.revision;
    var within_cell = fixture.event(6);
    within_cell.x += 0.25;
    try fixture.send(within_cell);
    try std.testing.expectEqual(revision, gui.input.pointer.hover.revision);
    try fixture.send(fixture.event(1));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
    try std.testing.expect(gui.input.pointer.owners[0] == .link);
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 1), fixture.open_count);
    try std.testing.expectEqualStrings("https://a.b", fixture.opened.?.uri());
    try std.testing.expectEqual(@as(usize, 0), fixture.session.input_len);
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 1), fixture.open_count);
}

test "native link drags changed targets pointer leave and focus loss cancel opening" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.send(fixture.event(1));
    try fixture.send(fixture.event(3));
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
    try fixture.send(fixture.event(1));
    fixture.text("https://b.c");
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
    try fixture.send(fixture.event(1));
    try fixture.send(fixture.event(7));
    try std.testing.expectEqual(.default, fixture.session.gui.input.pointer.hover.shape);
    try std.testing.expect(fixture.session.gui.input.pointer.hover.link == null);
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
    try fixture.send(fixture.event(1));
    try fixture.session.gui.focus(false);
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
    try std.testing.expectEqual(.default, fixture.session.gui.input.pointer.hover.shape);
}

test "native links require Shift to override child reporting and never leak a captured gesture" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const pane = fixture.session.gui.app.model.workspace.findPane(Session.pane_id).?;
    pane.mouse = .{ .tracking = .button, .sgr = true };
    try fixture.send(fixture.event(1));
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
    try std.testing.expect(fixture.session.input_len != 0);
    const before = fixture.session.input_len;
    var press = fixture.event(1);
    press.mods |= 1;
    try fixture.send(press);
    press.code = 2;
    try fixture.send(press);
    try std.testing.expectEqual(@as(usize, 1), fixture.open_count);
    try std.testing.expectEqual(before, fixture.session.input_len);
}

test "native pane pointer shapes refresh under a stationary pointer and modal blocks links" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    var move = fixture.event(6);
    move.mods = 0;
    try fixture.send(move);
    const pane = gui.app.model.workspace.findPane(Session.pane_id).?;
    inline for (@typeInfo(core.PointerShape).@"enum".fields) |field| {
        const shape: core.PointerShape = @enumFromInt(field.value);
        pane.pointer_shape = shape;
        gui.input.pointer.hover.dirty = true;
        _ = try gui.pump();
        try std.testing.expectEqual(if (shape == .default) .text else shape, gui.input.pointer.hover.shape);
    }

    gui.app.model.name_prompt.begin(.create_workspace);
    try fixture.send(fixture.event(6));
    try std.testing.expect(gui.input.pointer.hover.link == null);
    try fixture.send(fixture.event(1));
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
}

test "native link highlight reuses retained cells and disappears without changing atlas pixels" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const renderer = &fixture.session.renderer;
    const atlas = renderer.atlas.?.version;
    try fixture.send(fixture.event(6));
    try fixture.present();
    const highlighted = renderer.quads.items().len;
    try std.testing.expectEqual(@as(usize, 0), renderer.repainted_cells);
    try std.testing.expectEqual(atlas, renderer.atlas.?.version);
    try fixture.send(fixture.event(7));
    try fixture.present();
    try std.testing.expect(renderer.quads.items().len < highlighted);
    try std.testing.expectEqual(@as(usize, 0), renderer.repainted_cells);
    try std.testing.expectEqual(atlas, renderer.atlas.?.version);
}
