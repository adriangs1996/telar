//! The one clipboard image capture this client may have in flight: its
//! identity and target, and a finished result whose worker outlived the
//! request that started it.
const model_data = @import("../model.zig");
const std = @import("std");
const Capture = @import("../attachments/Capture.zig");
const State = @This();

capture: ?model_data.ClipboardCapture = null,
next_id: u64 = 1,
/// A published result nobody has taken yet; freed on teardown.
orphan: ?*Capture = null,

/// Reserves one capture for `target`, or returns null while another runs.
/// Example: `const capture = try model.clipboard.reserve(target) orelse return;`
pub fn reserve(self: *State, target: model_data.AttachmentTarget) !?model_data.ClipboardCapture {
    if (self.capture != null) {
        return null;
    }

    if (self.next_id == 0) {
        return error.ClipboardCaptureIdExhausted;
    }

    try target.validate();
    const capture: model_data.ClipboardCapture = .{
        .id = @enumFromInt(self.next_id),
        .target = target,
    };
    self.next_id +%= 1;
    self.capture = capture;
    return capture;
}

/// Finishes only the matching capture and keeps a newer reservation.
/// Example: `const capture = model.clipboard.finish(id) orelse return;`
pub fn finish(self: *State, id: model_data.ClipboardCaptureId) ?model_data.ClipboardCapture {
    const capture = self.capture orelse return null;
    if (capture.id != id) {
        return null;
    }

    self.capture = null;
    return capture;
}

/// Cancels a capture owned by a prompt that was just sent. Its worker may
/// still complete; exact completion matching discards that result.
/// Example: `_ = model.clipboard.cancel(target);`
pub fn cancel(self: *State, target: model_data.AttachmentTarget) bool {
    const capture = self.capture orelse return false;
    if (!std.meta.eql(capture.target, target)) {
        return false;
    }

    self.capture = null;
    return true;
}

/// Transfers one completed worker result to the client event handler.
/// Example: `const owned = model.clipboard.take(completed);`
pub fn take(self: *State, capture: *Capture) *Capture {
    std.debug.assert(self.orphan == capture);
    self.orphan = null;
    return capture;
}

/// Frees a result published before its worker was cancelled.
/// Example: `model.clipboard.deinit(gpa);`
pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
    if (self.orphan) |capture| {
        capture.deinit(gpa);
    }

    self.orphan = null;
}

test "a completed worker result is taken exactly once" {
    var resources: State = .{};
    const request: model_data.CaptureRequest = .{
        .target = .{
            .pane_id = @enumFromInt(7),
            .pane_generation = 3,
        },
        .sequence = 1,
    };
    const capture = try std.testing.allocator.create(Capture);
    capture.* = .{
        .request = request,
        .png = try std.testing.allocator.dupe(u8, "png"),
        .width = 1,
        .height = 1,
    };
    resources.orphan = capture;

    try std.testing.expect(resources.take(capture) == capture);
    capture.deinit(std.testing.allocator);
    try std.testing.expect(resources.orphan == null);
}

test "teardown frees a result whose request was cancelled" {
    var resources: State = .{};
    const request: model_data.CaptureRequest = .{
        .target = .{
            .pane_id = @enumFromInt(9),
            .pane_generation = 4,
        },
        .sequence = 1,
    };
    const capture = try std.testing.allocator.create(Capture);
    capture.* = .{
        .request = request,
        .png = try std.testing.allocator.dupe(u8, "private image"),
        .width = 2,
        .height = 2,
    };
    resources.orphan = capture;
    resources.deinit(std.testing.allocator);

    try std.testing.expect(resources.orphan == null);
}
