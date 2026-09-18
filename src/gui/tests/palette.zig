//! Slice 6 of the GUI visual language: the native command palette.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Fixture = @import("OverlayFixture.zig");
const Session = @import("Session.zig");
const CommandPalette = @import("../widgets/overlays/CommandPalette.zig");
const PaletteHits = @import("../widgets/overlays/PaletteHits.zig");
const routing = @import("../input/router.zig");

test "palette row clips long hints in narrow and empty widget bounds" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    var row: @import("../widgets/overlays/PaletteRow.zig") = .{ .icon = ">", .primary = "A long action", .secondary = "Additional detail", .hint = "Shift+Enter" };
    try row.draw(&canvas);
    try std.testing.expectEqual(@as(usize, 0), fixture.renderer.quads.items().len);

    for (1..16) |width| {
        fixture.renderer.quads.clear();
        row.area = .{ .x = 2, .y = 1, .w = @intCast(width), .h = 1 };
        try row.draw(&canvas);
        try std.testing.expect(fixture.renderer.quads.items().len > 0);
        try quadsInside(fixture, row.area);
    }
}

fn populate(fixture: *Fixture) !void {
    _ = try fixture.model.reconcileWorkspaceList(.{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "alpha", .path = "/alpha", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "beta", .path = "/beta", .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "gamma", .path = "/gamma", .tab_count = 1 },
    } });
}

fn quadsInside(fixture: *Fixture, area: core.Rect) !void {
    var canvas = fixture.canvas();
    const bounds = canvas.rect(area);
    for (fixture.renderer.quads.items()) |quad| {
        try std.testing.expect(quad.x >= bounds.x - 0.001 and quad.y >= bounds.y - 0.001);
        try std.testing.expect(quad.x + quad.width <= bounds.x + bounds.width + 0.001);
        try std.testing.expect(quad.y + quad.height <= bounds.y + bounds.height + 0.001);
    }
}

test "native palette switches its list by the first byte and paints inside one rounded surface" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populate(fixture);
    fixture.model.name_prompt.begin(.{ .palette = .goto });
    try fixture.paint();
    var presented = fixture.overlays.presented();
    const area = presented.modal.?;
    try std.testing.expectEqual(@as(u8, 3), presented.palette.count);
    try std.testing.expectEqual(@as(u16, 3 + 4), area.h);
    try std.testing.expectEqual(@as(u16, fixture.size.rows * CommandPalette.top_percent / 100), area.y);
    try std.testing.expect(area.w >= 24 and area.w <= fixture.size.cols - 4);
    try quadsInside(fixture, area);
    const surface = fixture.renderer.quads.items()[0];
    try std.testing.expectEqual(@as(f32, CommandPalette.radius_px), surface.radius);
    try std.testing.expectEqual(@as(f32, 1), fixture.renderer.quads.items()[1].border);

    _ = fixture.model.name_prompt.apply(.{ .home = false });
    _ = fixture.model.name_prompt.apply(.delete);
    _ = fixture.model.name_prompt.apply(.{ .insert = ">" });
    try fixture.paint();
    presented = fixture.overlays.presented();
    try std.testing.expectEqual(@as(u8, CommandPalette.max_rows), presented.palette.count);
    try std.testing.expectEqual(@as(u16, CommandPalette.max_rows + 4), presented.modal.?.h);
    try quadsInside(fixture, presented.modal.?);

    _ = fixture.model.name_prompt.apply(.{ .insert = "zzzz" });
    try fixture.paint();
    try std.testing.expectEqual(@as(u8, 0), fixture.overlays.presented().palette.count);
    try std.testing.expectEqual(@as(u16, 1 + 4), fixture.overlays.presented().modal.?.h);

    _ = fixture.model.name_prompt.apply(.{ .home = false });
    _ = fixture.model.name_prompt.apply(.delete);
    _ = fixture.model.name_prompt.apply(.{ .insert = "?" });
    try fixture.paint();
    try std.testing.expectEqual(@as(u8, 1), fixture.overlays.presented().palette.count);
    try std.testing.expectEqualStrings("?zzzz", fixture.model.name_prompt.currentConst().?.field.text());
}

test "native palette rows are hits that choose their result and scroll with the selection" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.{ .palette = .actions });
    for (0..CommandPalette.max_rows + 2) |_| {
        _ = fixture.model.name_prompt.apply(.move_down);
    }

    try fixture.paint();
    const hits = &fixture.overlays.presented().palette;
    try std.testing.expectEqual(@as(u8, CommandPalette.max_rows), hits.count);
    try std.testing.expectEqual(@as(u16, 3), hits.first);
    const row = hits.rows[2];
    const press = fixture.overlays.pointer(.{ .x = row.x + 1, .y = row.y, .kind = .press }).?;
    try std.testing.expect(press.consumed);
    try std.testing.expectEqualDeep(client.Intent{ .prompt_row = 5 }, press.intent);
    try std.testing.expect(fixture.overlays.pointer(.{ .x = row.x + 1, .y = row.y, .kind = .release }).?.consumed);
    const outside = fixture.overlays.pointer(.{ .x = 0, .y = 0, .kind = .press }).?;
    try std.testing.expect(outside.consumed and outside.intent == .none);
    _ = fixture.overlays.pointer(.{ .x = 0, .y = 0, .kind = .release });
    const secondary = fixture.overlays.pointer(.{ .x = row.x + 1, .y = row.y, .kind = .press, .button = 1 }).?;
    try std.testing.expect(secondary.consumed and secondary.intent == .none);
    _ = fixture.overlays.pointer(.{ .x = row.x + 1, .y = row.y, .kind = .release, .button = 1 });

    var empty: PaletteHits = .{};
    try std.testing.expect(empty.at(.{ .x = row.x, .y = row.y, .kind = .move }) == null);
    empty.add(.{});
    try std.testing.expectEqual(@as(u8, 0), empty.count);
}

test "native palette prints the bound chord from the native keymap" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.{ .palette = .actions });
    _ = fixture.model.name_prompt.apply(.{ .insert = "toggle sidebar" });
    try fixture.paint();
    const without = fixture.renderer.quads.items().len;

    var router = try routing.build(.{ .prefix = client.default_prefix, .bindings = &.{}, .escape_timeout_ns = 1, .sequence_timeout_ns = 1 });
    fixture.overlays.router = &router;
    try fixture.paint();
    try std.testing.expect(fixture.renderer.quads.items().len > without);
    try std.testing.expectEqual(@as(u8, 1), fixture.overlays.presented().palette.count);
}

test "native palette repaints warm without shaping rasterizing or allocating" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populate(fixture);
    var router = try routing.build(.{ .prefix = client.default_prefix, .bindings = &.{}, .escape_timeout_ns = 1, .sequence_timeout_ns = 1 });
    fixture.overlays.router = &router;
    for ([_]client.command_palette.Prefix{ .goto, .actions, .suggest }) |prefix| {
        fixture.model.name_prompt.begin(.{ .palette = prefix });
        _ = fixture.model.name_prompt.apply(.move_down);
        try fixture.paint();
        const count = fixture.renderer.quads.items().len;
        const version = fixture.renderer.atlas.?.version;
        const calls = fixture.renderer.atlas.?.shape_calls;
        const prompt = fixture.model.name_prompt.currentConst().?.*;

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        fixture.renderer.atlas.?.allocator = failing.allocator();
        fixture.renderer.quads.allocator = failing.allocator();
        defer fixture.renderer.atlas.?.allocator = std.testing.allocator;
        defer fixture.renderer.quads.allocator = std.testing.allocator;
        for (0..8) |_| {
            try fixture.paint();
        }

        try std.testing.expectEqual(count, fixture.renderer.quads.items().len);
        try std.testing.expectEqual(version, fixture.renderer.atlas.?.version);
        try std.testing.expectEqual(calls, fixture.renderer.atlas.?.shape_calls);
        try std.testing.expectEqualDeep(prompt, fixture.model.name_prompt.currentConst().?.*);
        try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
        _ = fixture.model.name_prompt.apply(.cancel);
    }
}

test "suggestion separates the request command and paste control across window sizes" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.{ .palette = .suggest });
    _ = fixture.model.name_prompt.apply(.{ .insert = "buscar favicon recursivamente en este directorio" });
    fixture.model.suggestion.expect(7);
    const command = "find . -type f \\( -iname '*favicon*' -o -iname 'apple-touch-icon*' \\) -not -path './node_modules/*' -print";
    try std.testing.expect(fixture.model.suggestion.apply(.{ .request_id = @enumFromInt(7), .status = .ready, .text = command }));

    for ([_]u32{ 1280, 640, 320 }) |width| {
        fixture.size = try fixture.renderer.measure(.{ .width = width, .height = 720, .scale = 1 });
        try fixture.paint();
        const modal = fixture.overlays.presented().modal.?;
        try quadsInside(fixture, modal);
        const preview = fixture.overlays.presented().palette.rows[0];
        var canvas = fixture.canvas();
        const command_bounds = canvas.rect(preview);
        const targets = fixture.widgets.dispatcher.maps.presented();
        var found_field = false;
        var found_submit = false;
        for (targets.targets[0..targets.len]) |target| {
            if (target.action == .text_field) {
                found_field = true;
                try std.testing.expect(target.bounds.y + target.bounds.height <= command_bounds.y);
            }

            if (target.action == .prompt and target.action.prompt == .submit) {
                found_submit = true;
                try std.testing.expect(target.enabled);
                try std.testing.expectEqualStrings("Paste command  Enter", target.label[0..target.label_len]);
                try std.testing.expect(target.bounds.y >= command_bounds.y + command_bounds.height);
                const route = fixture.widgets.dispatcher.route(.{ .pointer = .{ .kind = .press, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
                try std.testing.expect(route.consumed);
                const release = fixture.widgets.dispatcher.route(.{ .pointer = .{ .kind = .release, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
                try std.testing.expectEqualDeep(target.action, release.target.?.action);
            }
        }

        try std.testing.expect(found_field and found_submit);
        const lines: @import("../widgets/overlays/WrappedLines.zig") = .{ .text = command, .width = preview.w - 2 };
        try std.testing.expect(lines.count() <= preview.h - 2);
        if (width == 1280) {
            try std.testing.expect(canvas.rect(modal).width >= 900);
        }
    }
}

test "suggestion states retain bounded controls and repaint without allocations" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.{ .palette = .suggest });
    _ = fixture.model.name_prompt.apply(.{ .insert = "find favicon" });
    for ([_]@FieldType(client.SuggestionState, "phase"){ .idle, .waiting, .ready, .failed }) |phase| {
        fixture.model.suggestion.begin();
        if (phase != .idle) {
            fixture.model.suggestion.expect(8);
        }

        if (phase == .ready or phase == .failed) {
            _ = fixture.model.suggestion.apply(.{ .request_id = @enumFromInt(8), .status = if (phase == .ready) .ready else .timeout, .text = if (phase == .ready) "find . -iname '*favicon*'" else "" });
        }

        try fixture.paint();
        const targets = fixture.widgets.dispatcher.maps.presented();
        for (targets.targets[0..targets.len]) |target| {
            if (target.action == .prompt and target.action.prompt == .submit) {
                try std.testing.expectEqual(phase != .waiting, target.enabled);
            }
        }

        const calls = fixture.renderer.atlas.?.shape_calls;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        fixture.renderer.atlas.?.allocator = failing.allocator();
        fixture.renderer.quads.allocator = failing.allocator();
        defer fixture.renderer.atlas.?.allocator = std.testing.allocator;
        defer fixture.renderer.quads.allocator = std.testing.allocator;
        try fixture.paint();
        try std.testing.expectEqual(calls, fixture.renderer.atlas.?.shape_calls);
        try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    }
}

test "suggestion clips long unicode commands on short and scaled hosts" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.{ .palette = .suggest });
    fixture.model.suggestion.expect(9);
    try std.testing.expect(fixture.model.suggestion.apply(.{ .request_id = @enumFromInt(9), .status = .ready, .text = "find . -name '界é favicon*' -print " ** 20 }));
    for ([_]@import("../native/Viewport.zig").Viewport{ .{ .width = 640, .height = 220, .scale = 1 }, .{ .width = 320, .height = 160, .scale = 1 }, .{ .width = 160, .height = 90, .scale = 1 }, .{ .width = 32, .height = 32, .scale = 1 }, .{ .width = 2560, .height = 1440, .scale = 2 } }) |viewport| {
        fixture.size = try fixture.renderer.measure(viewport);
        fixture.overlays.scale = viewport.scale;
        try fixture.paint();
        try quadsInside(fixture, fixture.overlays.presented().modal.?);
    }
}

test "native history keeps its own modal and records no palette rows" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populate(fixture);
    fixture.model.name_prompt.begin(.{ .palette = .goto });
    try fixture.paint();
    try std.testing.expect(fixture.overlays.presented().palette.count != 0);
    _ = fixture.model.name_prompt.apply(.cancel);
    fixture.model.name_prompt.begin(.history_palette);
    try fixture.paint();
    const presented = fixture.overlays.presented();
    try std.testing.expect(presented.modal != null);
    try std.testing.expectEqual(@as(u8, 0), presented.palette.count);
    try std.testing.expect(fixture.model.name_prompt.currentConst().?.target() == .history);
    const press = fixture.overlays.pointer(.{ .x = presented.modal.?.x + 2, .y = presented.modal.?.y + 2, .kind = .press }).?;
    try std.testing.expect(press.consumed and press.intent == .none);
}

fn chord(session: *Session, text: []const u8) !void {
    try session.gui.input.accept(.{ .kind = 4, .code = 'b', .mods = 4 });
    try session.gui.input.accept(.{ .kind = 1, .text = text.ptr, .len = text.len });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
}

fn typeText(session: *Session, text: []const u8) !void {
    try session.gui.input.accept(.{ .kind = 1, .text = text.ptr, .len = text.len });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
}

fn special(session: *Session, code: u32) !void {
    try session.gui.input.accept(.{ .kind = 3, .code = code });
    try session.gui.input.drain(&session.gui.app);
    try session.settle();
}

test "native prefix keys open the palette prefixed and enter runs the chosen action" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    try session.receiveFrame(1);
    const model = &session.gui.app.model;

    try chord(session, "g");
    try std.testing.expect(model.name_prompt.currentConst().?.target() == .palette);
    try std.testing.expectEqualStrings("@", model.name_prompt.currentConst().?.field.text());
    try special(session, 4);
    try std.testing.expect(!model.name_prompt.active());

    try chord(session, "?");
    try std.testing.expect(model.name_prompt.currentConst().?.target() == .palette);
    try std.testing.expectEqualStrings("?", model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(client.command_palette.Prefix.suggest, model.name_prompt.currentConst().?.paletteMode());
    try special(session, 3);
    try typeText(session, ">toggle sidebar");
    try std.testing.expectEqual(client.command_palette.Prefix.actions, model.name_prompt.currentConst().?.paletteMode());
    const visible = model.sidebarVisible();
    try special(session, 1);
    try std.testing.expect(!model.name_prompt.active());
    try std.testing.expectEqual(!visible, model.sidebarVisible());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    try chord(session, "/");
    try std.testing.expect(model.name_prompt.currentConst().?.target() == .history);
    try special(session, 4);
    try std.testing.expect(!model.name_prompt.active());
}
