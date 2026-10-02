const data = @import("model");
const ModalMotion = @import("../widgets/overlays/ModalMotion.zig");
const SelectionMotion = @import("../widgets/overlays/SelectionMotion.zig");
const HistoryModalLayout = @import("../widgets/overlays/HistoryModalLayout.zig");
const HistoryModalMetrics = @import("../widgets/overlays/HistoryModalMetrics.zig");
const event_module = @import("../input/event.zig");
const input_support = @import("input_support.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Target = @import("../widgets/interaction/Target.zig");
const Fixture = @import("OverlayFixture.zig");
const gfx = @import("gfx");
const Rect = gfx.Rect;

const entries = [_]core.HistoryEntry{
    .{ .id = 9, .pane_id = Session.pane_id, .started_at_ms = 1000, .duration_ns = 1000000, .exit_code = 0, .status = .completed, .command = "zig build", .cwd = "/work", .workspace_path = "/work" },
    .{ .id = 8, .pane_id = Session.pane_id, .started_at_ms = 900, .duration_ns = 2000000, .exit_code = 1, .status = .completed, .command = "zig test", .cwd = "/work", .workspace_path = "/work" },
};

fn initSession() !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    const size = try session.gui.resizeViewport(
        .{
            .width = 1000,
            .height = 800,
            .scale = 1,
        },
    );
    try session.gui.resize(size, session.gui.renderer.theme);
    session.gui.pointer.configure(session.gui.renderer.origin, size);
    try session.settle();
    session.gui.app.model.name_prompt.begin(.history_palette);
    try session.gui.app.model.history_palette.prepare(std.testing.allocator);
    try replacePage(session, 1);
    try publish(session);
    return session;
}

fn replacePage(session: *Session, request_id: u64) !void {
    const history = &session.gui.app.model.history_palette;
    try std.testing.expect(history.beginPageRequest(request_id, .global));
    try std.testing.expect(history.acceptPageResult(.{ .request_id = request_id, .entries = &entries, .snapshot_id = 9, .has_more = false, .now_ms = 2000 }));
}

fn publish(session: *Session) !void {
    const token = try session.draw();
    try input_support.presented(
        session.gui,
        token,
        true,
    );
    try session.settle();
}

fn send(session: *Session, event: event_module.Event) !void {
    try input_support.accept(session.gui, event);
    try input_support.pump(session.gui);
}

fn targetFor(session: *Session, action: Target.Action) !Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (std.meta.eql(target.action, action)) {
            return target;
        }
    }

    return error.MissingHistoryControl;
}

fn rowTarget(session: *Session, index: u16) !Target {
    return targetFor(session, .{ .history = .{ .select = .{ .index = index, .revision = session.gui.app.model.history_palette.version() } } });
}

fn submitTarget(session: *Session) !Target {
    return targetFor(session, .{ .history = .{ .submit = .{ .index = session.gui.app.model.name_prompt.currentConst().?.selection(), .revision = session.gui.app.model.history_palette.version() } } });
}

fn click(session: *Session, target: Target) !void {
    const x = target.bounds.x + target.bounds.width / 2;
    const y = target.bounds.y + target.bounds.height / 2;
    try send(session, .{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = x, .y = y } });
}

test "native history row clicks select without submitting and keep the search editor focused" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const editor = try targetFor(session, .{ .text_field = .name });
    const row = try rowTarget(session, 1);
    try std.testing.expect(editor.id.eql(gui.widgets.dispatcher.focused.?));
    try std.testing.expect(!row.focusable and row.enabled);
    const x = row.bounds.x + row.bounds.width / 2;
    const y = row.bounds.y + row.bounds.height / 2;
    try send(session, .{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try std.testing.expectEqual(@as(u16, 0), gui.app.model.name_prompt.currentConst().?.selection());
    try send(session, .{ .pointer = .{ .kind = .release, .x = x, .y = y } });
    try session.settle();
    try std.testing.expectEqual(@as(u16, 1), gui.app.model.name_prompt.currentConst().?.selection());
    try std.testing.expect(editor.id.eql(gui.widgets.dispatcher.focused.?));
    try std.testing.expectEqualStrings("", gui.app.model.name_prompt.currentConst().?.field.text());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    try click(session, try rowTarget(session, 0));
    try send(session, .{ .pointer = .{ .kind = .press, .button = .right, .x = x, .y = y } });
    try send(session, .{ .pointer = .{ .kind = .release, .button = .right, .x = x, .y = y } });
    try std.testing.expectEqual(@as(u16, 0), gui.app.model.name_prompt.currentConst().?.selection());
    try send(session, .{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try send(session, .{ .pointer = .{ .kind = .release, .x = 0, .y = 0 } });
    try std.testing.expectEqual(@as(u16, 0), gui.app.model.name_prompt.currentConst().?.selection());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native history rejects a delivered row after its page changed across a failed frame" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const original = try rowTarget(session, 1);
    const x = original.bounds.x + original.bounds.width / 2;
    const y = original.bounds.y + original.bounds.height / 2;
    try send(session, .{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try replacePage(session, 2);
    const token = try session.draw();
    try input_support.presented(
        gui,
        token,
        false,
    );
    try std.testing.expect(gui.widgets.dispatcher.maps.presented().find(original.id) != null);
    try send(session, .{ .pointer = .{ .kind = .release, .x = x, .y = y } });
    try std.testing.expectEqual(@as(u16, 0), gui.app.model.name_prompt.currentConst().?.selection());
    try send(session, .{ .accessibility = .{ .target_id = original.id.target_id, .generation = original.id.generation, .action = .press } });
    try std.testing.expectEqual(@as(u16, 0), gui.app.model.name_prompt.currentConst().?.selection());

    try publish(session);
    const replacement = try rowTarget(session, 1);
    try std.testing.expect(!replacement.id.eql(original.id));
    try click(session, replacement);
    try std.testing.expectEqual(@as(u16, 1), gui.app.model.name_prompt.currentConst().?.selection());
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native history pending pages disable rows and retire captured releases" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const original = try rowTarget(session, 1);
    const x = original.bounds.x + original.bounds.width / 2;
    const y = original.bounds.y + original.bounds.height / 2;
    try send(session, .{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try std.testing.expect(gui.app.model.history_palette.beginPageRequest(2, .global));
    try publish(session);
    const pending = try rowTarget(session, 1);
    try std.testing.expect(!pending.enabled);
    try send(session, .{ .pointer = .{ .kind = .release, .x = x, .y = y } });
    try click(session, pending);
    try send(session, .{ .accessibility = .{ .target_id = pending.id.target_id, .generation = pending.id.generation, .action = .press } });
    try std.testing.expectEqual(@as(u16, 0), gui.app.model.name_prompt.currentConst().?.selection());
    try std.testing.expect(gui.app.model.name_prompt.active());
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "native history inspection and scope controls keep query ownership" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const editor = try targetFor(session, .{ .text_field = .name });
    const inspect = try targetFor(session, .{ .history = .toggle_inspection });
    try click(session, inspect);
    try std.testing.expect(gui.app.model.name_prompt.currentConst().?.inspecting());
    try std.testing.expect(editor.id.eql(gui.widgets.dispatcher.focused.?));
    try publish(session);
    try send(session, .{ .key = .{ .code = .escape } });
    try std.testing.expect(!gui.app.model.name_prompt.currentConst().?.inspecting());
    try publish(session);
    try click(session, try targetFor(session, .{ .history = .{ .select_scope = .workspace } }));
    try std.testing.expect(editor.id.eql(gui.widgets.dispatcher.focused.?));
    try std.testing.expect(gui.app.model.history_palette.phase == .loading);
    try std.testing.expect(gui.app.model.name_prompt.active());
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "history application selection rejects unrelated prompts and out of range rows" {
    const model = try std.testing.allocator.create(data.ClientModel);
    defer std.testing.allocator.destroy(model);
    model.* = .init(std.testing.allocator, true);
    defer model.deinit();
    try model.history_palette.prepare(std.testing.allocator);
    try std.testing.expect(model.history_palette.beginPageRequest(1, .global));
    try std.testing.expect(client.history_browser.apply(model, .{ .request_id = 1, .entries = &entries, .snapshot_id = 9, .has_more = false, .now_ms = 2000 }));
    const revision = model.history_palette.version();
    try std.testing.expect(!client.history_browser.select(model, 1, revision));
    model.name_prompt.begin(.history_palette);
    try std.testing.expect(!client.history_browser.select(model, 2, revision));
    try std.testing.expect(!client.history_browser.select(model, 1, revision -| 1));
    _ = model.name_prompt.apply(.toggle_inspection);
    _ = model.name_prompt.apply(.page_down);
    const before = model.name_prompt.version();
    try std.testing.expect(client.history_browser.select(model, 1, revision));
    try std.testing.expectEqual(before + 1, model.name_prompt.version());
    try std.testing.expectEqual(@as(u16, 1), model.name_prompt.currentConst().?.selection());
    try std.testing.expectEqual(@as(u32, 0), model.name_prompt.currentConst().?.detailScroll());
    model.name_prompt.begin(.goto_picker);
    try std.testing.expect(!client.history_browser.select(model, 0, revision));
}

test "native history wheel accumulates precise movement and bounds inspector scrolling" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const editor = try targetFor(session, .{ .text_field = .name });
    // One wheel step is a closed row, not the taller selected card.
    const row = try rowTarget(session, 1);
    try std.testing.expect(row.bounds.height < (try rowTarget(session, 0)).bounds.height);
    const x = row.bounds.x + row.bounds.width / 2;
    const y = row.bounds.y + row.bounds.height / 2;
    try send(session, .{ .scroll = .{ .x = x, .y = y, .delta_y = -row.bounds.height / 2, .precise = true, .phase = .begin } });
    try std.testing.expectEqual(@as(u16, 0), gui.app.model.name_prompt.currentConst().?.selection());
    try send(session, .{ .scroll = .{ .x = x, .y = y, .delta_y = -row.bounds.height / 2, .precise = true, .phase = .update } });
    try std.testing.expectEqual(@as(u16, 1), gui.app.model.name_prompt.currentConst().?.selection());
    try publish(session);
    try click(session, try targetFor(session, .{ .history = .toggle_inspection }));
    const history = &gui.app.model.history_palette;
    history.expectOutput(.{ .request_id = 900, .id = 8 });
    try std.testing.expect(history.applyOutput(.{ .request_id = @enumFromInt(900), .id = 8, .content = "output line\n" ** 128, .truncated = false, .observed_bytes = 1536 }));
    try publish(session);
    const bounds = gui.overlays.presented().native_modal.?;
    const sx = bounds.x + bounds.width / 2;
    const sy = bounds.y + bounds.height / 2;
    const half_line = @as(f64, @floatFromInt(gui.pointer.geometry.size.cell_height_px)) / 2;
    try send(session, .{ .scroll = .{ .x = sx, .y = sy, .delta_y = half_line, .precise = true, .phase = .begin } });
    try std.testing.expectEqual(@as(u32, 0), gui.app.model.name_prompt.currentConst().?.detailScroll());
    try send(session, .{ .scroll = .{ .x = sx, .y = sy, .delta_y = half_line, .precise = true, .phase = .update } });
    try std.testing.expectEqual(@as(u32, 1), gui.app.model.name_prompt.currentConst().?.detailScroll());
    const limit = gui.app.chrome.inspectionScrollLimit().?;
    try std.testing.expect(limit > 32);
    try send(session, .{ .scroll = .{ .x = sx, .y = sy, .delta_y = 1e100 } });
    try std.testing.expectEqual(@as(u32, 33), gui.app.model.name_prompt.currentConst().?.detailScroll());
    for (0..10) |_| {
        try send(session, .{ .scroll = .{ .x = sx, .y = sy, .delta_y = 1e100 } });
    }

    try std.testing.expectEqual(limit, gui.app.model.name_prompt.currentConst().?.detailScroll());
    for (0..10) |_| {
        try send(session, .{ .scroll = .{ .x = sx, .y = sy, .delta_y = -1e100 } });
    }

    try std.testing.expectEqual(@as(u32, 0), gui.app.model.name_prompt.currentConst().?.detailScroll());
    try std.testing.expectEqual(@as(u16, 1), gui.app.model.name_prompt.currentConst().?.selection());
    try std.testing.expect(editor.id.eql(gui.widgets.dispatcher.focused.?));
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

fn populateFixture(fixture: *Fixture) !void {
    fixture.model.name_prompt.begin(.history_palette);
    const history = &fixture.model.history_palette;
    try history.prepare(std.testing.allocator);
    try std.testing.expect(history.beginPageRequest(1, .global));
    try std.testing.expect(history.acceptPageResult(.{ .request_id = 1, .entries = &entries, .snapshot_id = 9, .has_more = false, .now_ms = 2000 }));
}

fn expectInside(inner: Rect, outer: Rect) !void {
    try std.testing.expect(inner.x >= outer.x - 0.001 and inner.y >= outer.y - 0.001);
    try std.testing.expect(inner.x + inner.width <= outer.x + outer.width + 0.001);
    try std.testing.expect(inner.y + inner.height <= outer.y + outer.height + 0.001);
}

test "native history controls and glyphs stay inside narrow and high density windows" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populateFixture(fixture);
    for ([_]f32{ 1, 2 }) |scale| {
        for ([_][2]u32{ .{ 24, 24 }, .{ 90, 60 }, .{ 240, 120 }, .{ 360, 300 }, .{ 1600, 1200 } }) |size| {
            const width: u32 = @intFromFloat(@as(f32, @floatFromInt(size[0])) * scale);
            const height: u32 = @intFromFloat(@as(f32, @floatFromInt(size[1])) * scale);
            fixture.size = try fixture.renderer.measure(.{ .width = width, .height = height, .scale = scale });
            for ([_]bool{ false, true }) |inspecting| {
                if (fixture.model.name_prompt.currentConst().?.inspecting() != inspecting) {
                    _ = fixture.model.name_prompt.apply(.toggle_inspection);
                }

                const original = fixture.model.name_prompt.currentConst().?.*;
                try fixture.paint();
                const viewport: Rect = .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height) };
                const bounds = fixture.overlays.presented().native_modal.?;
                try expectInside(bounds, viewport);
                for (fixture.renderer.quads.items()) |quad| {
                    try expectInside(.{ .x = quad.x, .y = quad.y, .width = quad.width, .height = quad.height }, viewport);
                }

                const registry = fixture.widgets.dispatcher.maps.presented();
                for (registry.targets[0..registry.len]) |target| {
                    try expectInside(target.bounds, bounds);
                }

                try std.testing.expectEqualDeep(original, fixture.model.name_prompt.currentConst().?.*);
            }
        }
    }
}

test "native history entrance publishes animated hit and editor geometry only after delivery" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populateFixture(fixture);
    fixture.animation = .{};
    fixture.animation.?.begin(0);
    try fixture.paint();
    const initial = fixture.overlays.presented().native_modal.?;
    const editor = fixture.widgets.editors.presented().items[0];
    const id = editor.id;
    try std.testing.expect(fixture.animation.?.deadline_ns != null);
    fixture.animation.?.begin(ModalMotion.duration_ns / 2);
    _ = fixture.model.name_prompt.apply(.{ .insert = "zig" });
    try fixture.prepare();
    const moved = fixture.overlays.prepared().native_modal.?;
    try std.testing.expect(moved.y < initial.y);
    const prepared_editor = fixture.widgets.editors.prepared().find(id).?;
    try std.testing.expectApproxEqAbs(moved.y - initial.y, prepared_editor.bounds.y - editor.bounds.y, 0.001);
    fixture.present(false);
    try std.testing.expectEqual(initial, fixture.overlays.presented().native_modal.?);
    try std.testing.expectEqual(editor.bounds, fixture.widgets.editors.presented().find(id).?.bounds);
    fixture.animation.?.begin(ModalMotion.duration_ns);
    try fixture.paint();
    const settled = fixture.overlays.presented().native_modal.?;
    try std.testing.expect(settled.y < moved.y);
    try std.testing.expectEqual(@as(?u64, null), fixture.animation.?.deadline_ns);
    try std.testing.expectApproxEqAbs(settled.y - initial.y, fixture.widgets.editors.presented().find(id).?.bounds.y - editor.bounds.y, 0.001);
    fixture.model.name_prompt.begin(.history_palette);
    fixture.animation.?.begin(ModalMotion.duration_ns + 1);
    try fixture.paint();
    try std.testing.expect(fixture.overlays.presented().native_modal.?.y > settled.y);
    try std.testing.expect(fixture.widgets.editors.presented().find(id) == null);
}

test "native history cannot submit an unseen replacement page from a failed frame" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const submit = try submitTarget(session);
    const x = submit.bounds.x + submit.bounds.width / 2;
    const y = submit.bounds.y + submit.bounds.height / 2;
    try send(session, .{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try replacePage(session, 2);
    const token = try session.draw();
    try input_support.presented(
        gui,
        token,
        false,
    );
    try send(session, .{ .pointer = .{ .kind = .release, .x = x, .y = y } });
    try send(session, .{ .accessibility = .{ .target_id = submit.id.target_id, .generation = submit.id.generation, .action = .press } });
    try session.settle();
    try std.testing.expect(gui.app.model.name_prompt.active());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    try publish(session);
    try click(session, try submitTarget(session));
    try session.settle();
    try std.testing.expect(!gui.app.model.name_prompt.active());
    try std.testing.expectEqualStrings("zig build", session.input[0..session.input_len]);
}

test "native history submit waits until a changed selection is delivered" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const submit = try submitTarget(session);
    try send(session, .{ .key = .{ .code = .up } });
    try std.testing.expectEqual(@as(u16, 1), gui.app.model.name_prompt.currentConst().?.selection());
    const token = try session.draw();
    try input_support.presented(
        gui,
        token,
        false,
    );
    try click(session, submit);
    try send(session, .{ .accessibility = .{ .target_id = submit.id.target_id, .generation = submit.id.generation, .action = .press } });
    try session.settle();
    try std.testing.expect(gui.app.model.name_prompt.active());
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
    try publish(session);
    try click(session, try submitTarget(session));
    try session.settle();
    try std.testing.expect(!gui.app.model.name_prompt.active());
    try std.testing.expectEqualStrings("zig test", session.input[0..session.input_len]);
}

test "native history retains delivered inspector wrapping across a failed resize" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populateFixture(fixture);
    _ = fixture.model.name_prompt.apply(.toggle_inspection);
    _ = fixture.model.name_prompt.apply(.page_down);
    const history = &fixture.model.history_palette;
    history.expectOutput(.{ .request_id = 2, .id = 9 });
    const output = ("a" ** 160 ++ "\n") ** 128;
    try std.testing.expect(history.applyOutput(.{ .request_id = @enumFromInt(2), .id = 9, .content = output, .truncated = false, .observed_bytes = output.len }));
    try fixture.paint();
    const before = fixture.overlays.inspectionScrollLimit(fixture.projection()).?;
    fixture.size = try fixture.renderer.measure(.{ .width = 480, .height = 500, .scale = 2 });
    try fixture.prepare();
    try std.testing.expectEqual(before, fixture.overlays.inspectionScrollLimit(fixture.projection()).?);
    fixture.present(false);
    try std.testing.expectEqual(before, fixture.overlays.inspectionScrollLimit(fixture.projection()).?);
    try fixture.paint();
    try std.testing.expect(fixture.overlays.inspectionScrollLimit(fixture.projection()).? > before);
}

test "native history warm frames reuse shaping for long paths and every result state" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populateFixture(fixture);
    const history = &fixture.model.history_palette;
    var long_entries = entries;
    long_entries[0].cwd = "/Users/adriangonzalez/sandbox/telar/worktrees/a-very-long-workspace-directory/packages/another-directory/src";
    try std.testing.expect(history.beginPageRequest(2, .global));
    try std.testing.expect(history.acceptPageResult(.{ .request_id = 2, .entries = &long_entries, .snapshot_id = 9, .has_more = false, .now_ms = 2000 }));
    _ = fixture.model.name_prompt.apply(.{ .insert = "zig" });
    for (0..5) |phase| {
        switch (phase) {
            1 => _ = fixture.model.name_prompt.apply(.toggle_inspection),
            2 => {
                _ = fixture.model.name_prompt.apply(.cancel);
                try std.testing.expect(history.beginPageRequest(3, .global));
                try std.testing.expect(history.acceptPageResult(.{ .request_id = 3, .entries = &.{}, .snapshot_id = 9, .has_more = false, .now_ms = 2000 }));
            },
            3 => {
                history.begin();
                try std.testing.expect(history.beginPageRequest(4, .global));
            },
            4 => history.setError("Could not load the command history because its observation worker is temporarily unavailable. Try searching again after the current request completes."),
            else => {},
        }

        try fixture.paint();
        try fixture.paint();
        const calls = fixture.renderer.atlas.?.shape_calls;
        const version = fixture.renderer.atlas.?.version;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        fixture.renderer.atlas.?.allocator = failing.allocator();
        fixture.renderer.quads.allocator = failing.allocator();
        defer fixture.renderer.atlas.?.allocator = std.testing.allocator;
        defer fixture.renderer.quads.allocator = std.testing.allocator;
        for (0..8) |_| {
            try fixture.paint();
        }

        try std.testing.expectEqual(calls, fixture.renderer.atlas.?.shape_calls);
        try std.testing.expectEqual(version, fixture.renderer.atlas.?.version);
        try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes);
    }
}

fn rowBounds(fixture: *Fixture, index: u16) !Rect {
    const registry = fixture.widgets.dispatcher.maps.presented();
    const action: Target.Action = .{ .history = .{ .select = .{ .index = index, .revision = fixture.model.history_palette.version() } } };
    for (registry.targets[0..registry.len]) |target| {
        if (std.meta.eql(target.action, action)) {
            return target.bounds;
        }
    }

    return error.MissingHistoryControl;
}

test "native history panel follows the window and keeps the field where it was" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populateFixture(fixture);
    var previous: ?Rect = null;
    for ([_][2]u32{ .{ 1000, 600 }, .{ 1280, 800 }, .{ 2560, 1440 } }) |size| {
        fixture.size = try fixture.renderer.measure(.{ .width = size[0], .height = size[1], .scale = 1 });
        const canvas = fixture.canvas();
        const metrics = HistoryModalMetrics.fromCanvas(&canvas);
        const browsing = HistoryModalLayout.measure(metrics, false);
        const inspecting = HistoryModalLayout.measure(metrics, true);
        const px = metrics.chrome;

        // The panel uses the window: most of its height, and its width up
        // to the measure a command stays readable at.
        try std.testing.expect(browsing.bounds.width >= @min(px.px(HistoryModalLayout.max_width), metrics.viewport.width * 0.9));
        try std.testing.expect(browsing.bounds.width <= px.px(HistoryModalLayout.max_width));
        try std.testing.expect(browsing.bounds.height >= metrics.viewport.height * 0.75);
        if (previous) |smaller| {
            try std.testing.expect(browsing.results.height > smaller.height);
        }

        previous = browsing.results;

        // Opening the inspector splits the list; nothing else moves.
        try std.testing.expectEqual(browsing.bounds, inspecting.bounds);
        try std.testing.expectEqual(browsing.search, inspecting.search);
        try std.testing.expectEqual(browsing.header, inspecting.header);
        try std.testing.expectEqual(browsing.footer, inspecting.footer);
        try std.testing.expect(inspecting.results.width > 0 and inspecting.inspection.width > inspecting.results.width);
        try std.testing.expectEqual(browsing.results.width, inspecting.results.width + inspecting.inspection.width);
    }

    // A window too narrow to split lets the inspector replace the list.
    fixture.size = try fixture.renderer.measure(.{ .width = 700, .height = 600, .scale = 1 });
    const canvas = fixture.canvas();
    const narrow = HistoryModalLayout.measure(HistoryModalMetrics.fromCanvas(&canvas), true);
    try std.testing.expectEqual(@as(f32, 0), narrow.results.width);
    try std.testing.expectEqual(narrow.bounds.width, narrow.inspection.width);
}

test "native history selection moves at once while its card opens over a few frames" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populateFixture(fixture);
    fixture.animation = .{};
    fixture.animation.?.begin(0);
    try fixture.paint();
    fixture.animation.?.begin(std.time.ns_per_s);
    try fixture.paint();
    try std.testing.expectEqual(@as(?u64, null), fixture.animation.?.deadline_ns);
    const card = (try rowBounds(fixture, 0)).height;
    const closed = (try rowBounds(fixture, 1)).height;
    try std.testing.expect(card > closed);

    // The key lands in the model before any frame; only the geometry follows.
    _ = fixture.model.name_prompt.apply(.move_up);
    try std.testing.expectEqual(@as(u16, 1), fixture.model.name_prompt.currentConst().?.selection());
    fixture.animation.?.begin(std.time.ns_per_s + 1);
    try fixture.paint();
    try std.testing.expect(fixture.animation.?.deadline_ns != null);
    try std.testing.expectEqual(card, (try rowBounds(fixture, 0)).height);
    try std.testing.expectEqual(closed, (try rowBounds(fixture, 1)).height);

    fixture.animation.?.begin(std.time.ns_per_s + 1 + SelectionMotion.duration_ns / 2);
    try fixture.paint();
    const leaving = (try rowBounds(fixture, 0)).height;
    const opening = (try rowBounds(fixture, 1)).height;
    try std.testing.expect(leaving < card and leaving > closed);
    try std.testing.expect(opening < card and opening > closed);

    fixture.animation.?.begin(std.time.ns_per_s + 1 + SelectionMotion.duration_ns);
    try fixture.paint();
    try std.testing.expectEqual(@as(?u64, null), fixture.animation.?.deadline_ns);
    try std.testing.expectEqual(closed, (try rowBounds(fixture, 0)).height);
    try std.testing.expectEqual(card, (try rowBounds(fixture, 1)).height);

    // A page replaced under the same position does not replay the motion.
    const history = &fixture.model.history_palette;
    var replaced = entries;
    replaced[0].id = 40;
    replaced[1].id = 39;
    try std.testing.expect(history.beginPageRequest(2, .global));
    try std.testing.expect(history.acceptPageResult(.{ .request_id = 2, .entries = &replaced, .snapshot_id = 40, .has_more = false, .now_ms = 2000 }));
    fixture.animation.?.begin(2 * std.time.ns_per_s);
    try fixture.paint();
    try std.testing.expectEqual(@as(?u64, null), fixture.animation.?.deadline_ns);
    try std.testing.expectEqual(card, (try rowBounds(fixture, 1)).height);
}

test "native history shows a long selected command complete and marks the rows it cuts" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try populateFixture(fixture);
    const history = &fixture.model.history_palette;
    var long_entries = entries;
    long_entries[0].command = "printf '%s ' " ++ "alpha-beta-gamma-delta " ** 20 ++ "| wc -c";
    long_entries[1].command = "for word in uno dos tres; do\n  echo \"$word añadir café 日本語\"\ndone";
    try std.testing.expect(history.beginPageRequest(2, .global));
    try std.testing.expect(history.acceptPageResult(.{ .request_id = 2, .entries = &long_entries, .snapshot_id = 9, .has_more = false, .now_ms = 2000 }));
    try fixture.paint();
    const cell: f32 = @floatFromInt(fixture.renderer.metrics.cell_height);
    const closed = (try rowBounds(fixture, 1)).height;
    const card = try rowBounds(fixture, 0);
    const columns = @floor(card.width / @as(f32, @floatFromInt(fixture.renderer.metrics.cell_width)));
    const lines = @ceil(@as(f32, @floatFromInt(long_entries[0].command.len)) / columns);
    try std.testing.expect(lines > 1);
    try std.testing.expect(card.height >= closed + lines * cell);

    // The multi-line command opens to its three lines when selected.
    _ = fixture.model.name_prompt.apply(.move_up);
    try fixture.paint();
    try std.testing.expectEqual(closed, (try rowBounds(fixture, 0)).height);
    try std.testing.expect((try rowBounds(fixture, 1)).height >= closed + 3 * cell);
}

test "native history card reaches copy and delete with the pointer and keeps the browser open" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const card = try rowTarget(session, 0);
    const copy = try targetFor(session, .{ .history = .copy });
    const remove = try targetFor(session, .{ .history = .remove });
    try expectInside(copy.bounds, card.bounds);
    try expectInside(remove.bounds, card.bounds);
    try std.testing.expect(copy.bounds.x + copy.bounds.width <= remove.bounds.x);

    try click(session, copy);
    try std.testing.expectEqualStrings("zig build", gui.app.model.to_host.clipboard.items);
    try std.testing.expectEqual(@as(u16, 0), gui.app.model.name_prompt.currentConst().?.selection());
    try std.testing.expectEqual(@as(u64, 0), gui.app.model.history_palette.delete_request);

    try click(session, remove);
    try std.testing.expect(gui.app.model.history_palette.delete_request != 0);
    try std.testing.expect(gui.app.model.name_prompt.active());
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}
