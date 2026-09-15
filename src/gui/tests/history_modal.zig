const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Session = @import("Session.zig");
const Target = @import("../widgets/interaction/Target.zig");
const Event = @import("../input/event.zig").Event;
const Fixture = @import("OverlayFixture.zig");
const Rect = @import("../render/Rect.zig");

const entries = [_]core.HistoryEntry{
    .{ .id = 9, .pane_id = Session.pane_id, .started_at_ms = 1000, .duration_ns = 1000000, .exit_code = 0, .status = .completed, .command = "zig build", .cwd = "/work", .workspace_path = "/work" },
    .{ .id = 8, .pane_id = Session.pane_id, .started_at_ms = 900, .duration_ns = 2000000, .exit_code = 1, .status = .completed, .command = "zig test", .cwd = "/work", .workspace_path = "/work" },
};

fn initSession() !*Session {
    const session = try Session.init();
    errdefer session.deinit();
    try session.bootstrap();
    const size = try session.gui.measure(&session.renderer, .{ .width = 1000, .height = 800, .scale = 1 });
    try session.gui.resize(size, session.renderer.theme);
    session.gui.input.setGeometry(session.renderer.origin, size);
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
    const token = try session.gui.prepare(&session.renderer);
    try session.gui.complete(token, true);
    try session.settle();
}

fn send(session: *Session, event: Event) !void {
    try session.gui.input.acceptEvent(event);
    try session.gui.input.drain(&session.gui.app);
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
    const token = try gui.prepare(&session.renderer);
    try gui.complete(token, false);
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
    try click(session, try targetFor(session, .{ .history = .cycle_scope }));
    try std.testing.expect(editor.id.eql(gui.widgets.dispatcher.focused.?));
    try std.testing.expect(gui.app.model.history_palette.phase == .loading);
    try std.testing.expect(gui.app.model.name_prompt.active());
    try session.settle();
    try std.testing.expectEqual(@as(usize, 0), session.input_len);
}

test "history application selection rejects unrelated prompts and out of range rows" {
    const model = try std.testing.allocator.create(client.Model);
    defer std.testing.allocator.destroy(model);
    model.* = .init(std.testing.allocator, true);
    defer model.deinit();
    const handler: client.HistoryBrowserHandler = .{ .model = model };
    try model.history_palette.prepare(std.testing.allocator);
    try std.testing.expect(handler.requestPage(1, .global));
    try std.testing.expect(handler.apply(.{ .request_id = 1, .entries = &entries, .snapshot_id = 9, .has_more = false, .now_ms = 2000 }));
    const revision = model.history_palette.version();
    try std.testing.expect(!handler.select(1, revision));
    model.name_prompt.begin(.history_palette);
    try std.testing.expect(!handler.select(2, revision));
    try std.testing.expect(!handler.select(1, revision -| 1));
    _ = model.name_prompt.apply(.toggle_inspection);
    _ = model.name_prompt.apply(.page_down);
    const before = model.name_prompt.version();
    try std.testing.expect(handler.select(1, revision));
    try std.testing.expectEqual(before + 1, model.name_prompt.version());
    try std.testing.expectEqual(@as(u16, 1), model.name_prompt.currentConst().?.selection());
    try std.testing.expectEqual(@as(u32, 0), model.name_prompt.currentConst().?.detailScroll());
    model.name_prompt.begin(.goto_picker);
    try std.testing.expect(!handler.select(0, revision));
}

test "native history wheel accumulates precise movement and bounds inspector scrolling" {
    const session = try initSession();
    defer session.deinit();
    const gui = session.gui;
    const editor = try targetFor(session, .{ .text_field = .name });
    const row = try rowTarget(session, 0);
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
    const half_line = @as(f64, @floatFromInt(gui.input.pointer.geometry.size.cell_height_px)) / 2;
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
    const duration = @import("../widgets/overlays/ModalMotion.zig").duration_ns;
    try std.testing.expect(fixture.animation.?.deadline_ns != null);
    fixture.animation.?.begin(duration / 2);
    _ = fixture.model.name_prompt.apply(.{ .insert = "zig" });
    try fixture.prepare();
    const moved = fixture.overlays.prepared().native_modal.?;
    try std.testing.expect(moved.y < initial.y);
    const prepared_editor = fixture.widgets.editors.prepared().find(id).?;
    try std.testing.expectApproxEqAbs(moved.y - initial.y, prepared_editor.bounds.y - editor.bounds.y, 0.001);
    fixture.present(false);
    try std.testing.expectEqual(initial, fixture.overlays.presented().native_modal.?);
    try std.testing.expectEqual(editor.bounds, fixture.widgets.editors.presented().find(id).?.bounds);
    fixture.animation.?.begin(duration);
    try fixture.paint();
    const settled = fixture.overlays.presented().native_modal.?;
    try std.testing.expect(settled.y < moved.y);
    try std.testing.expectEqual(@as(?u64, null), fixture.animation.?.deadline_ns);
    try std.testing.expectApproxEqAbs(settled.y - initial.y, fixture.widgets.editors.presented().find(id).?.bounds.y - editor.bounds.y, 0.001);
    fixture.model.name_prompt.begin(.history_palette);
    fixture.animation.?.begin(duration + 1);
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
    const token = try gui.prepare(&session.renderer);
    try gui.complete(token, false);
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
    const token = try gui.prepare(&session.renderer);
    try gui.complete(token, false);
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
