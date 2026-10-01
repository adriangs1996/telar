const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const client = @import("telar-client");
const gfx = @import("gfx");
const input_support = @import("input_support.zig");
const review = @import("change_review.zig");
const Session = @import("Session.zig");
const ImagePreviews = @import("../ImagePreviews.zig");
const PreviewImage = @import("../image/PreviewImage.zig");
const PremultipliedImage = @import("../image/PremultipliedImage.zig");
const clipboard_image = @import("../clipboard_image.zig");
const Target = @import("../widgets/interaction/Target.zig");

const target: data.AttachmentTarget = .{
    .pane_id = @enumFromInt(7),
    .pane_generation = 3,
};

fn preview(gpa: std.mem.Allocator, sequence: u64, shade: u8) !PreviewImage {
    var thumbnail = try PremultipliedImage.init(gpa, 16, 8);
    errdefer thumbnail.deinit(gpa);
    @memset(thumbnail.pixels, shade);

    var full = try PremultipliedImage.init(gpa, 32, 16);
    errdefer full.deinit(gpa);
    @memset(full.pixels, shade);

    return .{
        .sequence = sequence,
        .thumbnail = thumbnail,
        .full = full,
    };
}

fn capture(gpa: std.mem.Allocator, sequence: u64, owner: data.AttachmentTarget) !*data.Capture {
    const value = try gpa.create(data.Capture);
    errdefer gpa.destroy(value);
    value.* = .{
        .request = .{
            .target = owner,
            .sequence = sequence,
        },
        .png = try gpa.dupe(u8, "png"),
        .width = 32,
        .height = 16,
    };
    return value;
}

test "retired pixels outlive the key press that retired them until the next frame" {
    const gpa = std.testing.allocator;
    var previews = ImagePreviews.init(gpa);
    defer previews.deinit();
    const shelf = previews.port();
    _ = shelf.syncTarget(target);

    previews.landing = try preview(gpa, 1, 0x40);
    try std.testing.expect((try shelf.adopt(try capture(gpa, 1, target))).layout_changed);
    try std.testing.expect(previews.landing == null);

    previews.beginFrame();
    var textures = previews.textures(true);
    try std.testing.expect(textures[0].pixels != null);
    try std.testing.expect(textures[1].pixels == null);
    try std.testing.expect(previews.textures(false)[0].pixels == null);

    previews.openModal(@enumFromInt(1));
    try std.testing.expect(shelf.modalActive());
    textures = previews.textures(true);
    try std.testing.expectEqual(@as(u32, 32), textures[1].width);
    try std.testing.expectEqual(@as(u64, 1), textures[1].version);

    try std.testing.expect(shelf.remove(@enumFromInt(1)).?);
    try std.testing.expect(!shelf.modalActive());
    try std.testing.expectEqual(@as(u8, 1), previews.catalog.delivery.retired_len);

    previews.beginFrame();
    try std.testing.expectEqual(@as(u8, 0), previews.catalog.delivery.retired_len);
    textures = previews.textures(true);
    try std.testing.expect(textures[0].pixels == null);
    try std.testing.expect(textures[1].pixels == null);
}

test "each preview's thumbnail lands in its own cell of the sheet" {
    const gpa = std.testing.allocator;
    var previews = ImagePreviews.init(gpa);
    defer previews.deinit();
    const shelf = previews.port();
    _ = shelf.syncTarget(target);

    previews.landing = try preview(gpa, 1, 0x11);
    _ = try shelf.adopt(try capture(gpa, 1, target));
    previews.landing = try preview(gpa, 2, 0x22);
    _ = try shelf.adopt(try capture(gpa, 2, target));
    try std.testing.expect(previews.thumbnailUv(@enumFromInt(1)) == null);

    previews.beginFrame();
    const first = previews.thumbnailUv(@enumFromInt(1)).?;
    const second = previews.thumbnailUv(@enumFromInt(2)).?;
    try std.testing.expect(first[2] < second[0]);

    const sheet = previews.sheet.?;
    const cell_bytes = 256 * 4;
    try std.testing.expectEqual(@as(u8, 0x11), sheet[0]);
    try std.testing.expectEqual(@as(u8, 0x22), sheet[cell_bytes]);
    try std.testing.expectEqual(@as(u8, 0), sheet[16 * 4]);
}

test "a decoded preview of another capture is not adopted" {
    const gpa = std.testing.allocator;
    var previews = ImagePreviews.init(gpa);
    defer previews.deinit();
    const shelf = previews.port();
    _ = shelf.syncTarget(target);

    previews.landing = try preview(gpa, 9, 0x33);
    _ = try shelf.adopt(try capture(gpa, 1, target));
    try std.testing.expect(previews.landing != null);
    previews.dropLanding();

    previews.beginFrame();
    try std.testing.expect(previews.thumbnailUv(@enumFromInt(1)) == null);
    previews.openModal(@enumFromInt(1));
    try std.testing.expect(!previews.modalReady());
}

test "a capture waiting behind one whose completion fails still starts" {
    const session = try review.base();
    defer session.deinit();
    const gui = session.gui;
    const app = gui.app;
    try agentSnapshot(session);

    app.model.host.clipboard_capture = true;
    const running = (try client.clipboard_capture.startClipboardCapture(&app.model)).started;
    _ = app.model.to_host.pop().?.capture;
    gui.previews.capturing = true;

    // An invalid target fails in the worker before it reads the pasteboard.
    const waiting: data.CaptureRequest = .{
        .target = .{ .pane_id = .invalid, .pane_generation = 0 },
        .sequence = @intFromEnum(running.id) + 1,
    };
    try clipboard_image.start(gui, waiting);
    try std.testing.expect(gui.previews.queued != null);

    // A full job queue makes publishing the failure notice fail.
    while (true) {
        app.to_workers.push(.telemetry_tick) catch break;
    }

    try std.testing.expectError(
        error.RingFull,
        clipboard_image.finish(gui, .{ .execution_id = running.id, .result = error.ClipboardReadFailed }),
    );
    while (app.to_workers.pop()) |_| {}

    try std.testing.expect(app.model.clipboard.capture == null);
    try std.testing.expect(gui.previews.queued == null);
    try std.testing.expect(gui.previews.capturing);
}

fn agentSnapshot(session: *Session) !void {
    var bytes: [4096]u8 = undefined;
    const snapshot = try core.encodeAgentSnapshot(&bytes, .{ .revision = 1, .entries = &.{.{
        .pane_id = Session.pane_id,
        .pane_generation = 77,
        .location = Session.location,
        .pane_index = 1,
        .process_id = 1,
        .session_id = @splat(0),
        .provider = .codex,
        .status = .ready,
        .source = .lifecycle_report,
        .authority = .active,
        .confidence = 100,
        .sequence = 1,
        .observed_at_ms = 0,
        .expires_at_ms = 1000,
        .attachments = .ordered,
    }} });
    _ = try client.runtime_messages.handleServerMessage(session.gui.app, try core.decodeServer(snapshot));
    try session.settle();
}

fn findTarget(session: *Session, action: Target.Action) ?Target {
    const registry = session.gui.widgets.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |value| {
        if (std.meta.eql(value.action, action)) {
            return value;
        }
    }

    return null;
}

fn click(session: *Session, bounds: gfx.Rect) !void {
    const x = bounds.x + bounds.width / 2;
    const y = bounds.y + bounds.height / 2;
    try review.send(session, .{ .pointer = .{ .kind = .press, .x = x, .y = y } });
    try review.send(session, .{ .pointer = .{ .kind = .release, .x = x, .y = y } });
}

test "a pasted clipboard image shows below the agent's pane and opens in a modal Esc closes" {
    const session = try review.base();
    defer session.deinit();
    const gui = session.gui;
    const app = gui.app;
    const gpa = app.gpa;
    try agentSnapshot(session);
    try input_support.presented(gui, try session.draw(), true);

    app.model.host.clipboard_capture = true;
    const started = (try client.clipboard_capture.startClipboardCapture(&app.model)).started;
    const request = app.model.to_host.pop().?.capture;
    try std.testing.expectEqual(@intFromEnum(started.id), request.sequence);

    // What the capture worker publishes: the owned capture and its preview.
    const captured = try capture(gpa, request.sequence, request.target);
    app.model.clipboard.orphan = captured;
    gui.previews.landing = try preview(gpa, request.sequence, 0x55);
    try clipboard_image.finish(gui, .{ .execution_id = started.id, .result = captured });
    try session.settle();

    const tab = app.model.tabs.active;
    const layout = data.tab_layout.snapshot(&app.model, tab, data.workbench.region(&app.model).area);
    try std.testing.expect(!layout.reserved.isEmpty());

    try input_support.presented(gui, try session.draw(), true);
    const sheet = gui.renderer.diagrams[ImagePreviews.sheet_slot];
    try std.testing.expect(sheet.pixels != null);
    var sampled = false;
    for (gui.renderer.quads.items()) |quad| {
        sampled = sampled or quad.texture == gfx.Quad.diagram_texture + @as(f32, @floatFromInt(ImagePreviews.sheet_slot));
    }
    try std.testing.expect(sampled);

    const id: data.AttachmentId = @enumFromInt(request.sequence);
    const card = findTarget(session, .{ .preview = .{ .open = id } }) orelse return error.MissingPreviewCard;
    try std.testing.expect(findTarget(session, .{ .intent = .{ .attachment_dismiss = id } }) != null);
    try click(session, card.bounds);
    try std.testing.expect(gui.previews.catalog.hasModal());

    try input_support.presented(gui, try session.draw(), true);
    try std.testing.expectEqual(@as(u32, 32), gui.renderer.diagrams[ImagePreviews.modal_slot].width);

    try review.send(session, .{ .key = .{ .code = .escape } });
    try review.send(session, .{ .key = .{ .code = .escape, .phase = .release } });
    try std.testing.expect(!gui.previews.catalog.hasModal());
    try std.testing.expect(gui.previews.catalog.hasVisibleItems());
}
