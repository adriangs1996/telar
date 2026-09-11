const Resolved = @import("Resolved.zig");
const pane_mouse = @import("pane_mouse.zig");
const Plans = @import("Plans.zig");
const PaneMouseEffects = @import("PaneMouseEffects.zig");
const Capture = @This();

resolved: ?Resolved = null,
received: ?pane_mouse.Command = null,
effect: ?pane_mouse.Effect = null,
effect_count: usize = 0,
fail: bool = false,

pub fn plans(capture: *Capture) Plans {
    return .{ .context = capture, .resolve = resolve };
}

pub fn effects(capture: *Capture) PaneMouseEffects {
    return .{ .context = capture, .apply = apply };
}

fn resolve(raw_context: *anyopaque, command: pane_mouse.Command) ?Resolved {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.received = command;

    return capture.resolved;
}

fn apply(raw_context: *anyopaque, effect: pane_mouse.Effect) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.effect = effect;
    capture.effect_count += 1;

    if (capture.fail) {
        return error.PaneMouseEffectFailed;
    }
}
