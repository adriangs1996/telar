const std = @import("std");
const core = @import("telar-core");
const client = @import("../root.zig");
const presentation = @import("root.zig");
pub const app = client.application;
pub const schema = core.schema;
pub const gpa = std.testing.allocator;
pub const pane_id: schema.PaneId = @enumFromInt(1);
pub const location: schema.TabLocation = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(1) };
pub const retained = client.graphics.retained;
pub const Outcome = enum { applied, ignored, exit };

const Fixture = @import("Fixture.zig");

const Frames = @import("Frames.zig");

// Unwired test capabilities fail explicitly instead of pretending to implement a client.
const Unsupported = @import("Unsupported.zig");
const UnsupportedVoid = @import("UnsupportedVoid.zig");
const Adapters = @import("Adapters.zig");

const FrameInput = @import("FrameInput.zig");

fn sendFrame(fixture: *Fixture, input: FrameInput) !void {
    var wire: [1024]u8 = undefined;
    var cells: [4]core.ui.Cell = @splat(.{});
    cells[0].bytes[0] = input.text;
    const bytes = try schema.encodePaneFrame(&wire, .{
        .pane_id = pane_id,
        .frame_id = input.frame_id,
        .base_frame_id = input.base,
        .cols = 4,
        .rows = 1,
        .scroll = .{ .total_rows = 1, .offset = 0 },
        .input_modes = .{ .cursor_keys = input.cursor_keys },
        .spans = &.{.{ .start = 0, .cells = if (input.base == 0) &cells else cells[0..1] }},
    });
    try fixture.receive(try schema.decodeServer(bytes));
    @memset(&wire, 0xff);
}

test "shared entrypoint and handlers continue input while headless delivery owns an older frame" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try sendFrame(fixture, .{});
    const first = try fixture.prepare();
    try std.testing.expectEqual(@as(usize, 1), fixture.activations);
    try std.testing.expect(fixture.outbox.peek() == null);
    try std.testing.expectEqual(@as(u64, 0), fixture.adapter.state.delivered.model.frame);
    try sendFrame(fixture, .{ .frame_id = 2, .base = 1, .text = 'B', .cursor_keys = false });
    try std.testing.expectError(error.PresentationBusy, fixture.prepare());
    try std.testing.expectEqualStrings("A", fixture.adapter.frame.cells[0].text());
    try std.testing.expect(fixture.adapter.frame.panes[0].input_modes.cursor_keys);
    try fixture.key(.{ .code = .up });
    var wire: [1024]u8 = undefined;
    const sent = (try fixture.outbox.beginSend(&wire)).?;
    try std.testing.expectEqualStrings("\x1b[A", (try schema.decodeClient(sent)).pane_input.bytes);
    try fixture.outbox.finishSend({});
    try fixture.complete(first, .delivered);
    try fixture.expectAck(1);
    try std.testing.expectEqual(@as(u64, 2), fixture.model.workspace.findPane(pane_id).?.pending_frame_id);
    const second = try fixture.prepare();
    try std.testing.expectEqualStrings("B", fixture.adapter.frame.cells[0].text());
    try fixture.complete(second, .delivered);
    try fixture.expectAck(2);
    try std.testing.expectEqual(@as(u64, 0), fixture.model.workspace.findPane(pane_id).?.pending_frame_id);
    try std.testing.expect((try fixture.adapter.prepare(fixture.projection())) == null);
}

test "busy preparation failure delivery failure cancellation and stale completion never acknowledge early" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try sendFrame(fixture, .{});
    fixture.adapter.busy = true;
    try std.testing.expectError(error.PresentationBusy, fixture.prepare());
    fixture.adapter.busy = false;
    fixture.adapter.fail_preparation = true;
    try std.testing.expectError(error.HeadlessPreparationFailed, fixture.prepare());
    fixture.adapter.fail_preparation = false;
    const failed = try fixture.prepare();
    try fixture.complete(failed, .failed);
    const cancelled = try fixture.prepare();
    try fixture.complete(cancelled, .cancelled);
    const current = try fixture.prepare();
    try fixture.complete(failed, .delivered);
    try fixture.complete(cancelled, .delivered);
    try std.testing.expectEqual(current, fixture.adapter.state.active.?.token);
    try std.testing.expect(fixture.outbox.peek() == null);
    try std.testing.expectEqual(@as(u64, 1), fixture.model.workspace.findPane(pane_id).?.pending_frame_id);
    try fixture.complete(current, .delivered);
    try fixture.expectAck(1);
    try fixture.complete(current, .delivered);
    try std.testing.expect(fixture.outbox.peek() == null);
}

test "broken bases request recovery and geometry ABA does not authorize a new gesture" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try sendFrame(fixture, .{});
    const token = try fixture.prepare();
    try sendFrame(fixture, .{ .frame_id = 3, .base = 2 });
    try std.testing.expectEqual(@as(u64, 1), fixture.outbox.peek().?.request_snapshot.known_frame_id);
    try fixture.sendOne();
    const old_area = fixture.geometry.current.area;
    fixture.geometry.update(.{ .w = 20, .h = 10 });
    fixture.geometry.update(old_area);
    try fixture.complete(token, .delivered);
    try fixture.expectAck(1);
    const current_geometry = presentation.Geometry.capture(fixture.projection());
    try std.testing.expect(!fixture.adapter.state.delivered_geometry.?.matches(&current_geometry));
    const replacement = try fixture.prepare();
    try fixture.complete(replacement, .delivered);
    try std.testing.expect(fixture.adapter.state.delivered_geometry.?.matches(&current_geometry));
}

test "a reconstructed attachment cannot inherit a completed old frame with the same wire id" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try sendFrame(fixture, .{});
    const old = try fixture.prepare();
    const generation = fixture.model.workspace.findPane(pane_id).?.attachment_generation;
    _ = fixture.model.departWorkspace();
    try std.testing.expectEqualStrings("A", fixture.adapter.frame.cells[0].text());
    try fixture.arrive();
    try sendFrame(fixture, .{ .text = 'B' });
    try std.testing.expect(fixture.model.workspace.findPane(pane_id).?.attachment_generation != generation);
    try fixture.complete(old, .delivered);
    try std.testing.expect(fixture.outbox.peek() == null);
    try std.testing.expectEqual(@as(u64, 1), fixture.model.workspace.findPane(pane_id).?.pending_frame_id);
    const current = try fixture.prepare();
    try fixture.complete(current, .delivered);
    try fixture.expectAck(1);
}

test "retained graphics return credit on release before the delivered cell acknowledgement" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try sendFrame(fixture, .{});
    const image: core.graphics.Image = .{ .key = .{ .image_id = 1, .generation = 1 }, .format = .rgb, .width = 1, .height = 1, .byte_len = 3 };
    try fixture.graphics.applyImage(.{ .pane_id = pane_id, .revision = 1, .image = image });
    try fixture.graphics.applyChunk(.{ .pane_id = pane_id, .revision = 1, .key = image.key, .offset = 0, .bytes = "rgb" });
    const lease = try retained.retain(&fixture.graphics, client.graphics.identity(pane_id, image.key));
    const token = try fixture.prepare();
    try fixture.graphics.applySnapshot(.{ .pane_id = pane_id, .revision = 2, .phase = .begin });
    try std.testing.expect(fixture.graphics.peekCredit() == null);
    try std.testing.expectEqualStrings("rgb", lease.pixels);
    retained.release(&fixture.graphics, lease);
    try fixture.complete(token, .delivered);
    try std.testing.expectEqual(@as(u64, 3), fixture.outbox.peek().?.graphics_credit.bytes);
    try fixture.sendOne();
    try fixture.expectAck(1);
    try std.testing.expectEqual(@as(usize, 0), fixture.graphics.total_bytes);
}

test "reattachment invalidates old acknowledgements without replacing the pane buffer" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try sendFrame(fixture, .{});
    const old = try fixture.prepare();
    try fixture.model.commitTabDetachment(try fixture.model.planTabDetachment(location));
    var attach: app.panes.attach_pane.ConfirmPaneAttachmentHandler = .{ .model = &fixture.model };
    const attachment: client.model.PaneAttachment = .{ .pane_id = pane_id, .location = location };
    try std.testing.expectEqual(client.model.PaneAttachmentConfirmation.confirmed, try attach.execute(.{
        .requested = attachment,
        .confirmed = attachment,
        .created = false,
    }));
    try sendFrame(fixture, .{ .text = 'B' });
    try fixture.complete(old, .delivered);
    try std.testing.expect(fixture.outbox.peek() == null);
    try std.testing.expectEqual(@as(u64, 1), fixture.model.workspace.findPane(pane_id).?.pending_frame_id);
    const current = try fixture.prepare();
    try fixture.complete(current, .delivered);
    try fixture.expectAck(1);
}

test "headless preparation delivery input and steady-state patches allocate nothing" {
    var allocator = std.testing.FailingAllocator.init(gpa, .{});
    const fixture = try Fixture.initWithAllocator(allocator.allocator());
    defer fixture.deinit();
    try sendFrame(fixture, .{});
    allocator.fail_index = allocator.alloc_index;
    const first = try fixture.prepare();
    try fixture.complete(first, .delivered);
    try fixture.expectAck(1);
    try sendFrame(fixture, .{ .frame_id = 2, .base = 1 });
    try fixture.key(.{ .code = .up });
    try fixture.sendOne();
    const second = try fixture.prepare();
    try fixture.complete(second, .delivered);
    try fixture.expectAck(2);
    try std.testing.expect(!allocator.has_induced_failure);
}

test "the headless cell budget rejects a whole preparation instead of truncating coverage" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    _ = fixture.model.departWorkspace();
    _ = try fixture.model.arriveWorkspace(.{ .pane_id = pane_id, .location = location, .size = .{ .cols = 129, .rows = 129 } });
    try std.testing.expectError(error.HeadlessCellBudgetExceeded, fixture.prepare());
    try std.testing.expect(fixture.adapter.state.active == null);
    try std.testing.expect(fixture.outbox.peek() == null);
    try std.testing.expect(fixture.adapter.state.needsPreparation());
}

test "independent client assemblies produce identical semantic state and requests" {
    const first = try Fixture.init();
    defer first.deinit();
    const second = try Fixture.init();
    defer second.deinit();
    try sendFrame(first, .{});
    try sendFrame(second, .{});
    try first.key(.{ .code = .up });
    try second.key(.{ .code = .up });
    var first_wire: [1024]u8 = undefined;
    var second_wire: [1024]u8 = undefined;
    try std.testing.expectEqualSlices(u8, (try first.outbox.beginSend(&first_wire)).?, (try second.outbox.beginSend(&second_wire)).?);
    try first.outbox.finishSend({});
    try second.outbox.finishSend({});
    try first.complete(try first.prepare(), .delivered);
    try second.complete(try second.prepare(), .delivered);
    try std.testing.expectEqualDeep(first.model.version(), second.model.version());
    try std.testing.expectEqualDeep(first.outbox.peek().?.*, second.outbox.peek().?.*);
    _ = first.model.departWorkspace();
    try std.testing.expect(second.model.activeTabModelConst() != null);
    try std.testing.expectEqualStrings("A", second.model.workspace.findPane(pane_id).?.buffer.cells[0].text());
}
