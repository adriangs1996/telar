const Capture = @This();
const Resolved = @import("Resolved.zig");
const source_namespace = @import("pane_mouse.zig");
const Plans = @import("Plans.zig");
const Effects = @import("PaneMouseEffects.zig");
resolved: ?Resolved = null,
received: ?source_namespace.Command = null,
effect: ?source_namespace.Effect = null,
effect_count: usize = 0,
fail: bool = false,

pub fn plans(capture: *Capture) Plans {
    return .{ .context = capture, .resolve = resolve };
}

pub fn effects(capture: *Capture) Effects {
    return .{ .context = capture, .apply = apply };
}

fn resolve(raw_context: *anyopaque, command: source_namespace.Command) ?Resolved {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.received = command;

    return capture.resolved;
}

fn apply(raw_context: *anyopaque, effect: source_namespace.Effect) !void {
    const capture: *Capture = @ptrCast(@alignCast(raw_context));
    capture.effect = effect;
    capture.effect_count += 1;

    if (capture.fail) {
        return error.PaneMouseEffectFailed;
    }
}
