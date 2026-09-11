const ModelType = @import("../../model/Model.zig");
const pane_input = @import("pane_input.zig");
const PaneIdType = @import("telar-core").PaneId;
const PaneInputEffects = @import("PaneInputEffects.zig");
const PaneViewportChangeType = @import("../../model/PaneViewportChange.zig");
const PaneInputEffect = @import("PaneInputEffect.zig");
const EffectsCapture = @This();

model: *const ModelType,
events: [2]pane_input.EffectEvent = undefined,
event_count: usize = 0,
viewport_calls: usize = 0,
input_calls: usize = 0,
viewport_observed_commit: bool = false,
input_observed_bottom: bool = false,
pane_id: ?PaneIdType = null,
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

fn record(capture: *EffectsCapture, event: pane_input.EffectEvent) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn syncViewport(context: *anyopaque, change: PaneViewportChangeType) !void {
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
