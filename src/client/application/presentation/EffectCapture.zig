const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;
const presentation_delivery = @import("presentation_delivery.zig");
const Effects = @import("PresentationEffects.zig");
const EffectCapture = @This();

model: *ModelType,
pane_id: PaneIdType,
events: [max_panes_per_tab + 2]presentation_delivery.Event = undefined,
event_count: usize = 0,
commit_observed: bool = true,
failure: presentation_delivery.Failure = .none,

pub fn effects(capture: *EffectCapture) Effects {
    return .{
        .context = capture,
        .flush_graphics_credits = flushGraphicsCredits,
        .request_media = requestMedia,
    };
}

fn flushGraphicsCredits(context: *anyopaque) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(context));
    capture.observeCommit();
    capture.append(.credits);

    if (capture.failure == .credits) {
        return error.CreditFailure;
    }
}

fn requestMedia(context: *anyopaque) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(context));
    capture.observeCommit();
    capture.append(.media);

    if (capture.failure == .media) {
        return error.MediaFailure;
    }
}

fn observeCommit(capture: *EffectCapture) void {
    const pane = capture.model.workspace.findPane(capture.pane_id) orelse {
        capture.commit_observed = false;
        return;
    };

    capture.commit_observed = capture.commit_observed and pane.pending_frame_id == 0;
}

fn append(capture: *EffectCapture, event: presentation_delivery.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const EffectCapture) []const presentation_delivery.Event {
    return capture.events[0..capture.event_count];
}
