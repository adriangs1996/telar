//! Slice 6 of the GUI visual language: the native command palette.
const cellgrid = @import("cellgrid");
const core = @import("telar-core");
const Viewport = @import("../native/Viewport.zig");
const data = @import("model");
const input_support = @import("input_support.zig");
const std = @import("std");
const client = @import("telar-client");
const Fixture = @import("OverlayFixture.zig");
const Session = @import("Session.zig");
const CommandPalette = @import("../widgets/overlays/CommandPalette.zig");
const PaletteHits = @import("../widgets/overlays/PaletteHits.zig");
const PaletteRow = @import("../widgets/overlays/PaletteRow.zig");
const PaletteLayout = @import("../widgets/overlays/PaletteLayout.zig");

test "palette row clips long hints in narrow and empty widget bounds" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var canvas = fixture.canvas();
    var row: PaletteRow = .{ .icon = ">", .primary = "A long action", .secondary = "Additional detail", .hint = "Shift+Enter" };
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
    _ = try data.workspace_list_snapshot.reconcile(&fixture.model, .{ .revision = 1, .entries = &.{
        .{ .workspace = @enumFromInt(1), .name = "alpha", .path = "/alpha", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "beta", .path = "/beta", .tab_count = 1 },
        .{ .workspace = @enumFromInt(3), .name = "gamma", .path = "/gamma", .tab_count = 1 },
    } });
}

fn quadsInside(fixture: *Fixture, area: cellgrid.Rect) !void {
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
    const area = presented.native_modal.?;
    try std.testing.expectEqual(@as(u8, 3), presented.palette.count);
    try std.testing.expectEqual(@as(f32, 640), area.width);
    try std.testing.expect(area.y > 0 and area.y + area.height <= 720);
    try quadsInViewport(fixture);

    _ = fixture.model.name_prompt.apply(.{ .home = false });
    _ = fixture.model.name_prompt.apply(.delete);
    _ = fixture.model.name_prompt.apply(.{ .insert = ">" });
    try fixture.paint();
    presented = fixture.overlays.presented();
    try std.testing.expect(presented.palette.count > 0 and presented.palette.count <= CommandPalette.max_rows);
    try std.testing.expectEqual(area.height, presented.native_modal.?.height);
    try quadsInViewport(fixture);

    _ = fixture.model.name_prompt.apply(.{ .insert = "zzzz" });
    try fixture.paint();
    try std.testing.expectEqual(@as(u8, 0), fixture.overlays.presented().palette.count);
    try std.testing.expect(fixture.overlays.presented().native_modal != null);

    _ = fixture.model.name_prompt.apply(.{ .home = false });
    _ = fixture.model.name_prompt.apply(.delete);
    _ = fixture.model.name_prompt.apply(.{ .insert = "?" });
    try fixture.paint();
    try std.testing.expectEqual(@as(u8, 0), fixture.overlays.presented().palette.count);
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
    try std.testing.expect(hits.count > 2 and hits.count <= CommandPalette.max_rows);
    try std.testing.expect(hits.first > 0);
    try std.testing.expectEqual(@as(u16, CommandPalette.max_rows + 2), hits.first + hits.count - 1);
    const row = hits.pixel_rows[2];
    const press = fixture.pointer(.{ .x = row.x + 1, .y = row.y + 1, .kind = .press });
    try std.testing.expect(press.consumed);
    try std.testing.expectEqualDeep(client.Intent{ .prompt_row = hits.first + 2 }, press.intent);
    _ = fixture.pointer(.{ .x = row.x + 1, .y = row.y + 1, .kind = .release });
    const outside = fixture.overlays.pointer(.{ .x = 0, .y = 0, .kind = .press }).?;
    try std.testing.expect(outside.consumed and outside.intent == .none);
    _ = fixture.overlays.pointer(.{ .x = 0, .y = 0, .kind = .release });

    var empty: PaletteHits = .{};
    try std.testing.expect(empty.at(.{ .x = 0, .y = 0, .kind = .move }) == null);
    empty.add(.{});
    try std.testing.expectEqual(@as(u8, 0), empty.count);
}

test "the palette forgets every gone worktree through the runtime" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const app = session.gui.app;
    const snapshot = &app.model.workspace_list_snapshot;
    for ([_]core.WorktreeState{ .gone, .active, .gone }, 0..) |state, index| {
        snapshot.worktrees[index] = .{
            .worktree = @enumFromInt(index + 1),
            .source = @enumFromInt(1),
            .workspace = null,
            .state = state,
            .diff_added = 0,
            .diff_removed = 0,
            .diff_files = 0,
            .commits_ahead = 0,
            .command_state = .none,
            .command_exit = 0,
        };
    }

    snapshot.worktree_count = 3;
    const queued = app.model.to_runtime.len;
    const pending = app.model.request_lifecycle.tracker.count;

    _ = client.name_prompt.beginCommandPalette(&app.model, .actions);
    _ = try client.name_prompt.inputPrompt(app, .{ .command = .{ .insert = "Forget gone worktrees" } });
    _ = try client.name_prompt.inputPrompt(app, .{ .key = .{ .code = .enter } });

    try std.testing.expect(app.model.name_prompt.currentConst() == null);
    try std.testing.expectEqual(queued + 2, app.model.to_runtime.len);
    try std.testing.expectEqual(pending + 2, app.model.request_lifecycle.tracker.count);
}

test "native palette prints the bound chord from the native keymap" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.{ .palette = .actions });
    _ = fixture.model.name_prompt.apply(.{ .insert = "toggle sidebar" });
    try fixture.paint();
    const without = fixture.renderer.quads.items().len;

    var router = try client.key_router.build(
        .{
            .prefix = data.keybind.default_prefix,
            .bindings = &.{},
            .sequence_timeout_ns = 1,
        },
    );
    fixture.overlays.router = &router;
    try fixture.paint();
    try std.testing.expect(fixture.renderer.quads.items().len > without);
    try std.testing.expectEqual(@as(u8, 1), fixture.overlays.presented().palette.count);
}

test "native palette repaints warm without shaping rasterizing or allocating" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populate(fixture);
    var router = try client.key_router.build(
        .{
            .prefix = data.keybind.default_prefix,
            .bindings = &.{},
            .sequence_timeout_ns = 1,
        },
    );
    fixture.overlays.router = &router;
    for ([_]data.command_palette.Prefix{
        .goto,
        .actions,
        .suggest,
    }) |prefix| {
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
        const modal = fixture.overlays.presented().native_modal.?;
        try quadsInViewport(fixture);
        var canvas = fixture.canvas();
        const command_bounds = PaletteLayout.measure(&canvas, .{ .suggest = true }).results;
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
                try std.testing.expectEqualStrings("Paste command  ↵", target.label[0..target.label_len]);
                try std.testing.expect(target.bounds.y >= command_bounds.y + command_bounds.height);
                const route = fixture.widgets.dispatcher.route(.{ .pointer = .{ .kind = .press, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
                try std.testing.expect(route.consumed);
                const release = fixture.widgets.dispatcher.route(.{ .pointer = .{ .kind = .release, .x = target.bounds.x + 1, .y = target.bounds.y + 1 } });
                try std.testing.expectEqualDeep(target.action, release.target.?.action);
            }
        }

        try std.testing.expect(found_field and found_submit);
        if (width == 1280) {
            try std.testing.expectEqual(@as(f32, 640), modal.width);
        }
    }
}

test "suggestion states retain bounded controls and repaint without allocations" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.{ .palette = .suggest });
    _ = fixture.model.name_prompt.apply(.{ .insert = "find favicon" });
    for ([_]@FieldType(data.SuggestionState, "phase"){ .idle, .waiting, .ready, .failed }) |phase| {
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
    for ([_]Viewport.Viewport{ .{ .width = 640, .height = 220, .scale = 1 }, .{ .width = 320, .height = 160, .scale = 1 }, .{ .width = 160, .height = 90, .scale = 1 }, .{ .width = 32, .height = 32, .scale = 1 }, .{ .width = 2560, .height = 1440, .scale = 2 } }) |viewport| {
        fixture.size = try fixture.renderer.measure(viewport);
        fixture.overlays.scale = viewport.scale;
        try fixture.paint();
        try quadsInViewport(fixture);
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
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = 'b', .mods = 4 });
    try input_support.acceptNative(session.gui, .{ .kind = 1, .text = text.ptr, .len = text.len });
    try input_support.pump(session.gui);
    try session.settle();
}

fn typeText(session: *Session, text: []const u8) !void {
    try input_support.acceptNative(session.gui, .{ .kind = 1, .text = text.ptr, .len = text.len });
    try input_support.pump(session.gui);
    try session.settle();
}

fn special(session: *Session, code: u32) !void {
    try input_support.acceptNative(session.gui, .{ .kind = 3, .code = code });
    try input_support.pump(session.gui);
    try session.settle();
}

fn controlKey(session: *Session, code: u32, phase: u32) !void {
    try input_support.acceptNative(session.gui, .{ .kind = 4, .code = code, .mods = 4, .phase = phase });
    try input_support.pump(session.gui);
    try session.settle();
}

test "native control hjkl navigates focused pickers and returns from nested palettes" {
    const session = try input_support.createSession();
    defer session.deinit();
    const app = session.gui.app;
    const picks = &app.model.pick_list;
    app.model.name_prompt.begin(.pick);
    picks.begin(.{ .index = 0, .generation = 1, .prompt_generation = app.model.name_prompt.currentConst().?.generation, .title = "Theme" });
    for ([_][]const u8{ "Dragon", "Wave", "Lotus" }) |label| {
        try picks.items.append(.{ .label = label });
    }

    picks.show();
    try input_support.presented(session.gui, try session.draw(), true);
    try controlKey(session, 'j', 1);
    try std.testing.expectEqual(@as(u16, 1), app.model.name_prompt.currentConst().?.selection());
    try controlKey(session, 'j', 2);
    try controlKey(session, 'j', 2);
    try std.testing.expectEqual(@as(u16, 2), app.model.name_prompt.currentConst().?.selection());
    try controlKey(session, 'k', 1);
    try controlKey(session, 'k', 2);
    try controlKey(session, 'k', 2);
    try std.testing.expectEqual(@as(u16, 0), app.model.name_prompt.currentConst().?.selection());
    try std.testing.expectEqualStrings("", app.model.name_prompt.currentConst().?.field.text());
    try controlKey(session, 'h', 1);
    try std.testing.expect(!app.model.name_prompt.active());

    _ = client.name_prompt.beginCommandPalette(&app.model, .actions);
    _ = try client.name_prompt.inputPrompt(app, .{ .command = .{ .insert = "Suggest a command" } });
    try input_support.presented(session.gui, try session.draw(), true);
    try controlKey(session, 'l', 1);
    try std.testing.expectEqual(data.CommandPalettePrefix.suggest, app.model.name_prompt.currentConst().?.paletteMode());
    try input_support.presented(session.gui, try session.draw(), true);
    try controlKey(session, 'l', 2);
    try std.testing.expectEqual(data.CommandPalettePrefix.suggest, app.model.name_prompt.currentConst().?.paletteMode());
    try controlKey(session, 'h', 1);
    try std.testing.expectEqualStrings(">Suggest a command", app.model.name_prompt.currentConst().?.field.text());
    try input_support.presented(session.gui, try session.draw(), true);
    try controlKey(session, 'h', 2);
    try std.testing.expect(app.model.name_prompt.active());
    try controlKey(session, 'h', 1);
    try std.testing.expect(!app.model.name_prompt.active());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
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
    try std.testing.expectEqual(data.command_palette.Prefix.suggest, model.name_prompt.currentConst().?.paletteMode());
    try special(session, 3);
    try typeText(session, ">toggle sidebar");
    try std.testing.expectEqual(data.command_palette.Prefix.actions, model.name_prompt.currentConst().?.paletteMode());
    const visible = model.sidebar_visible;
    try special(session, 1);
    try std.testing.expect(!model.name_prompt.active());
    try std.testing.expectEqual(!visible, model.sidebar_visible);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    try chord(session, "/");
    try std.testing.expect(model.name_prompt.currentConst().?.target() == .history);
    try special(session, 4);
    try std.testing.expect(!model.name_prompt.active());
}

test "a pick list fills the palette from the model, filters by label or detail and shows why it failed" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const picks = &fixture.model.pick_list;
    fixture.model.name_prompt.begin(.pick);
    picks.begin(.{
        .index = 0,
        .generation = 1,
        .prompt_generation = fixture.model.name_prompt.currentConst().?.generation,
        .title = "Pi model",
    });
    try fixture.paint();
    try std.testing.expectEqual(@as(u8, 0), fixture.overlays.presented().palette.count);
    try std.testing.expect(fixture.overlays.presented().native_modal != null);

    for ([_][2][]const u8{ .{ "claude-opus-5-5", "anthropic" }, .{ "gpt-6-sol", "openai-codex" }, .{ "claude-sonnet-5-5", "anthropic" } }) |option| {
        try picks.items.append(.{
            .label = option[0],
            .detail = option[1],
        });
    }

    picks.show();
    try fixture.paint();
    var presented = fixture.overlays.presented();
    try std.testing.expectEqual(@as(u8, 3), presented.palette.count);
    try quadsInViewport(fixture);

    // A prefix byte is ordinary query text in a pick list.
    _ = fixture.model.name_prompt.apply(.{ .insert = ">anthropic" });
    try fixture.paint();
    try std.testing.expectEqual(@as(u8, 0), fixture.overlays.presented().palette.count);
    _ = fixture.model.name_prompt.apply(.{ .home = false });
    _ = fixture.model.name_prompt.apply(.delete);
    try fixture.paint();
    presented = fixture.overlays.presented();
    try std.testing.expectEqual(@as(u8, 2), presented.palette.count);

    const quads = fixture.renderer.quads.items().len;
    picks.fail("the list command timed out");
    try fixture.paint();
    try std.testing.expectEqual(@as(u8, 0), fixture.overlays.presented().palette.count);
    try std.testing.expect(fixture.renderer.quads.items().len != quads);
}

fn quadsInViewport(fixture: *Fixture) !void {
    const width: f32 = @floatFromInt(fixture.renderer.viewport[0]);
    const height: f32 = @floatFromInt(fixture.renderer.viewport[1]);
    for (fixture.renderer.quads.items()) |quad| {
        try std.testing.expect(quad.x >= -0.001 and quad.y >= -0.001);
        try std.testing.expect(quad.x + quad.width <= width + 0.001);
        try std.testing.expect(quad.y + quad.height <= height + 0.001);
    }
}

test "native palette mode controls preserve query and invalidate a suggestion" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const app = session.gui.app;
    _ = client.name_prompt.beginCommandPalette(&app.model, .goto);
    _ = try client.name_prompt.inputPrompt(app, .{ .command = .{ .insert = "split" } });
    try client.name_prompt.selectPaletteMode(app, .actions);
    try std.testing.expectEqualStrings(">split", app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(u16, 0), app.model.name_prompt.currentConst().?.selection());
    app.model.suggestion.expect(99);
    try client.name_prompt.selectPaletteMode(app, .suggest);
    try std.testing.expectEqualStrings("?split", app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expect(!app.model.suggestion.apply(.{ .request_id = @enumFromInt(99), .status = .ready, .text = "stale" }));
    _ = try client.name_prompt.inputPrompt(app, .{ .command = .{ .insert = " pane" } });
    try std.testing.expectEqualStrings("?split pane", app.model.name_prompt.currentConst().?.field.text());
}

test "a nested suggestion restores the palette query and discards its late reply" {
    const session = try Session.init();
    defer session.deinit();
    try session.bootstrap();
    const app = session.gui.app;
    _ = client.name_prompt.beginCommandPalette(&app.model, .actions);
    _ = try client.name_prompt.inputPrompt(app, .{ .command = .{ .insert = "Suggest a command" } });
    _ = try client.name_prompt.inputPrompt(app, .{ .command = .submit });
    const generation = app.model.name_prompt.currentConst().?.generation;
    try std.testing.expectEqual(data.CommandPalettePrefix.suggest, app.model.name_prompt.currentConst().?.paletteMode());
    try std.testing.expect(app.model.palette_parent != null);
    app.model.suggestion.expect(99);
    _ = try client.name_prompt.inputPrompt(app, .{ .command = .cancel });
    try std.testing.expectEqualStrings(">Suggest a command", app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expect(app.model.name_prompt.currentConst().?.generation != generation);
    try std.testing.expect(!app.model.suggestion.apply(.{ .request_id = @enumFromInt(99), .status = .ready, .text = "stale" }));
    _ = try client.name_prompt.inputPrompt(app, .{ .command = .cancel });
    try std.testing.expect(!app.model.name_prompt.active());
}

test "native palette mode buttons publish their exact mode without stealing the query" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.model.name_prompt.begin(.{ .palette = .goto });
    try fixture.paint();
    const registry = fixture.widgets.dispatcher.maps.presented();
    var count: usize = 0;
    for (registry.targets[0..registry.len]) |target| {
        if (target.action != .intent or target.action.intent != .palette_mode) {
            continue;
        }

        const press = fixture.pointer(.{ .x = target.bounds.x + 1, .y = target.bounds.y + 1, .kind = .press });
        try std.testing.expectEqualDeep(target.action.intent, press.intent);
        _ = fixture.pointer(.{ .x = target.bounds.x + 1, .y = target.bounds.y + 1, .kind = .release });
        count += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), count);
}
