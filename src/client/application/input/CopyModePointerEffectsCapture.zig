const EffectsCapture = @This();
const source_namespace = @import("copy_mode_pointer.zig");
const copy_mode = @import("../../input/root.zig").copy_mode;
const Effects = @import("CopyModePointerEffects.zig");
events: [2]source_namespace.Event = undefined,
event_count: usize = 0,
delta: i32 = 0,
failure: source_namespace.Failure = .none,
motion: ?copy_mode.PointerMotion = null,

pub fn effects(capture: *EffectsCapture) Effects {
    return .{
        .context = capture,
        .leave = leave,
        .vertical = vertical,
        .pointer = pointer,
        .cancel_pointer = cancelPointer,
    };
}

fn cancelPointer(raw_context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .cancel_pointer;
    capture.event_count += 1;
}

fn pointer(raw_context: *anyopaque, motion: copy_mode.PointerMotion) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .pointer;
    capture.event_count += 1;
    capture.motion = motion;
}

fn leave(raw_context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .leave;
    capture.event_count += 1;

    if (capture.failure == .leave) {
        return error.CopyModeLeaveFailed;
    }
}

fn vertical(raw_context: *anyopaque, delta: i32) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .vertical;
    capture.event_count += 1;
    capture.delta = delta;

    if (capture.failure == .vertical) {
        return error.CopyModeMovementFailed;
    }
}
