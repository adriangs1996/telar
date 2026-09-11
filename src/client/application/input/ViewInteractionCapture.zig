const Capture = @This();
const source_namespace = @import("view_interaction.zig");
const Effects = @import("ViewInteractionEffects.zig");
const IntentOutcome = @import("IntentOutcome.zig");
events: [3]source_namespace.Event = undefined,
count: usize = 0,
failure: source_namespace.Failure = .none,

pub fn effects(capture: *Capture) Effects {
    return .{
        .context = capture,
        .apply_intent = applyIntent,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .offer_pane_geometry = offerPaneGeometry,
    };
}

fn record(capture: *Capture, event: source_namespace.Event) void {
    capture.events[capture.count] = event;
    capture.count += 1;
}

fn applyIntent(context: *anyopaque, intent: source_namespace.Intent) !IntentOutcome {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.{ .intent = intent });

    if (capture.failure == .intent) {
        return error.ViewIntentFailed;
    }

    return .{ .layout_changed = switch (intent) {
        .attachment_dismiss => true,
        else => false,
    } };
}

fn invalidateGraphicsPlacements(context: *anyopaque) void {
    const capture: *Capture = @ptrCast(@alignCast(context));

    capture.record(.invalidate_graphics_placements);
}

fn offerPaneGeometry(context: *anyopaque) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.record(.offer_pane_geometry);

    if (capture.failure == .pane_geometry) {
        return error.PaneGeometryFailed;
    }
}
