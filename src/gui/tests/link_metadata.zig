const std = @import("std");
const core = @import("telar-core");
const Fixture = @import("LinkFixture.zig");
const Session = @import("Session.zig");
const Regions = @import("../render/LinkRegions.zig");

test "native OSC 8 opens its destination and highlights separated runs of the same identity" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const pane = gui.app.model.workspace.findPane(Session.pane_id).?;
    fixture.text("Docs");
    var storage = try core.TextMetadata.init(std.testing.allocator, pane.buffer.h);
    defer storage.deinit(std.testing.allocator);
    var builder = core.TextMetadataBuilder.init(storage.buffer, pane.buffer.h);
    const link = try builder.addLink("https://actual.example/docs");
    const separate = try builder.addLink("https://actual.example/docs");
    builder.setRow(0, .{ .hyperlinks = true });
    builder.setRow(1, .{ .hyperlinks = true });
    try builder.addRun(.{ .start = 0, .len = 4, .link_index = link });
    try builder.addRun(.{ .start = pane.buffer.w, .len = 3, .link_index = separate });
    try builder.addRun(.{ .start = pane.buffer.w + 4, .len = 3, .link_index = link });
    pane.text_metadata.replace(builder.finish(.complete));
    try fixture.present();
    try fixture.send(fixture.event(6));
    const hit = &gui.input.pointer.hover.link.?;
    try std.testing.expectEqualStrings("https://actual.example/docs", hit.match.target.uri());
    try std.testing.expectEqual(@as(?u16, link), hit.match.link_index);
    var regions = Regions.init(hit, pane);
    try std.testing.expectEqualDeep(hit.area, regions.next().?);
    try std.testing.expectEqualDeep(core.Rect{ .x = hit.content.x + 4, .y = hit.content.y + 1, .w = 3, .h = 1 }, regions.next().?);
    try std.testing.expect(regions.next() == null);
    try fixture.send(fixture.event(1));
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 1), fixture.open_count);
    try std.testing.expectEqualStrings("https://actual.example/docs", fixture.opened.?.uri());
}

test "native OSC 8 never treats an unsafe or omitted destination as the visible URL" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const pane = gui.app.model.workspace.findPane(Session.pane_id).?;
    var storage = try core.TextMetadata.init(std.testing.allocator, pane.buffer.h);
    defer storage.deinit(std.testing.allocator);
    var builder = core.TextMetadataBuilder.init(storage.buffer, pane.buffer.h);
    builder.setRow(0, .{ .hyperlinks = true });
    const link = try builder.addLink("javascript:alert(1)");
    try builder.addRun(.{ .start = 0, .len = 11, .link_index = link });
    pane.text_metadata.replace(builder.finish(.complete));
    gui.input.pointer.hover.dirty = true;
    try fixture.send(fixture.event(6));
    try std.testing.expect(gui.input.pointer.hover.link == null);
    try std.testing.expectEqual(.text, gui.input.pointer.hover.shape);
    builder = core.TextMetadataBuilder.init(storage.buffer, pane.buffer.h);
    builder.setRow(0, .{ .hyperlinks = true });
    pane.text_metadata.replace(builder.finish(.omitted));
    gui.input.pointer.hover.dirty = true;
    try fixture.send(fixture.event(6));
    try std.testing.expect(gui.input.pointer.hover.link == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
}

test "native wrapped URLs underline both physical rows and require a VT soft wrap" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const pane = gui.app.model.workspace.findPane(Session.pane_id).?;
    fixture.text("");
    const start = pane.buffer.w - 10;
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = start, .y = 0 }, .text = "https://e/", .style = .{} });
    _ = pane.buffer.writeText(pane.buffer.area(), .{ .point = .{ .x = 0, .y = 1 }, .text = "path", .style = .{} });
    var storage = try core.TextMetadata.init(std.testing.allocator, pane.buffer.h);
    defer storage.deinit(std.testing.allocator);
    var builder = core.TextMetadataBuilder.init(storage.buffer, pane.buffer.h);
    builder.setRow(0, .{ .wrap = true });
    builder.setRow(1, .{ .continuation = true });
    pane.text_metadata.replace(builder.finish(.complete));
    try fixture.present();
    var event = fixture.event(6);
    event.y += gui.app.model.hostSize().cell_height_px;
    try fixture.send(event);
    const hit = &gui.input.pointer.hover.link.?;
    try std.testing.expectEqualStrings("https://e/path", hit.match.target.uri());
    var regions = Regions.init(hit, pane);
    try std.testing.expectEqualDeep(core.Rect{ .x = hit.content.x + start, .y = hit.content.y, .w = 10, .h = 1 }, regions.next().?);
    try std.testing.expectEqualDeep(core.Rect{ .x = hit.content.x, .y = hit.content.y + 1, .w = 4, .h = 1 }, regions.next().?);
    try std.testing.expect(regions.next() == null);
    event.code = 1;
    try fixture.send(event);
    event.code = 2;
    try fixture.send(event);
    try std.testing.expectEqualStrings("https://e/path", fixture.opened.?.uri());
    builder = core.TextMetadataBuilder.init(storage.buffer, pane.buffer.h);
    pane.text_metadata.replace(builder.finish(.complete));
    gui.input.pointer.hover.dirty = true;
    event.code = 6;
    try fixture.send(event);
    try std.testing.expect(gui.input.pointer.hover.link == null);
}

test "native OSC 8 replacement under a held pointer cancels the original destination" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const gui = fixture.session.gui;
    const pane = gui.app.model.workspace.findPane(Session.pane_id).?;
    fixture.text("Docs");
    var storage = try core.TextMetadata.init(std.testing.allocator, pane.buffer.h);
    defer storage.deinit(std.testing.allocator);
    var builder = core.TextMetadataBuilder.init(storage.buffer, pane.buffer.h);
    builder.setRow(0, .{ .hyperlinks = true });
    try builder.addRun(.{ .start = 0, .len = 4, .link_index = try builder.addLink("https://first.example") });
    pane.text_metadata.replace(builder.finish(.complete));
    try fixture.present();
    try fixture.send(fixture.event(1));
    builder = core.TextMetadataBuilder.init(storage.buffer, pane.buffer.h);
    builder.setRow(0, .{ .hyperlinks = true });
    try builder.addRun(.{ .start = 0, .len = 4, .link_index = try builder.addLink("https://second.example") });
    pane.text_metadata.replace(builder.finish(.complete));
    gui.input.pointer.hover.dirty = true;
    try fixture.send(fixture.event(2));
    try std.testing.expectEqual(@as(usize, 0), fixture.open_count);
    try std.testing.expectEqualStrings("https://second.example", gui.input.pointer.hover.link.?.match.target.uri());
}
