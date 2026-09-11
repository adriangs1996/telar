const view_interaction = @import("view_interaction.zig");
const ViewInteractionEffects = @import("ViewInteractionEffects.zig");
const IntentOutcome = @import("IntentOutcome.zig");
const Capture = @This();

events: [3]view_interaction.Event = undefined,
count: usize = 0,
failure: view_interaction.Failure = .none,

pub fn effects(capture: *Capture) ViewInteractionEffects {
    return .{
        .context = capture,
        .apply_intent = applyIntent,
        .invalidate_graphics_placements = invalidateGraphicsPlacements,
        .offer_pane_geometry = offerPaneGeometry,
    };
}

fn record(capture: *Capture, event: view_interaction.Event) void {
    capture.events[capture.count] = event;
    capture.count += 1;
}

fn applyIntent(context: *anyopaque, intent: view_interaction.Intent) !IntentOutcome {
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
