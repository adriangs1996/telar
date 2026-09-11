const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_input.zig");
const PaneInputEffects = @import("PaneInputEffects.zig");
const PaneInputEffect = @import("PaneInputEffect.zig");
model: *const client_model.Model,
events: [2]source_namespace.EffectEvent = undefined,
event_count: usize = 0,
viewport_calls: usize = 0,
input_calls: usize = 0,
viewport_observed_commit: bool = false,
input_observed_bottom: bool = false,
pane_id: ?source_namespace.schema.PaneId = null,
input: [64]u8 = undefined,
input_len: usize = 0,
fail_viewport: bool = false,
fail_input: bool = false,

pub fn port(capture: *EffectsCapture) PaneInputEffects {
    return .{
        .context = capture,
        .send = send,
        .viewport = .{
            .context = capture,
            .sync = syncViewport,
        },
    };
}

fn record(capture: *EffectsCapture, event: source_namespace.EffectEvent) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn syncViewport(context: *anyopaque, change: client_model.PaneViewportChange) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const pane = capture.model.workspace.activeConst().?.model.findConst(change.pane_id).?;
    capture.record(.viewport);
    capture.viewport_calls += 1;
    capture.viewport_observed_commit = pane.scroll.offset == change.offset and
        capture.model.version().viewport == change.viewport_revision;

    if (capture.fail_viewport) {
        return error.ViewportSyncFailed;
    }
}

fn send(context: *anyopaque, effect: PaneInputEffect) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const pane = capture.model.workspace.activeConst().?.model.findConst(effect.pane_id).?;
    capture.record(.input);
    capture.input_calls += 1;
    capture.input_observed_bottom = pane.scroll.atBottom(pane.buffer.h);
    capture.pane_id = effect.pane_id;
    capture.input_len = effect.bytes.len;
    @memcpy(capture.input[0..effect.bytes.len], effect.bytes);

    if (capture.fail_input) {
        return error.InputDeliveryFailed;
    }
}
