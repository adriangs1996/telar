const EffectCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("presentation_delivery.zig");
const Effects = @import("Effects.zig");
model: *client_model.Model,
pane_id: source_namespace.schema.PaneId,
events: [source_namespace.multiplexer.max_panes + 2]source_namespace.Event = undefined,
event_count: usize = 0,
acknowledgements: [source_namespace.multiplexer.max_panes]source_namespace.schema.FrameAck = undefined,
acknowledgement_count: usize = 0,
commit_observed: bool = true,
failure: source_namespace.Failure = .none,

pub fn effects(capture: *EffectCapture) Effects {
    return .{
        .context = capture,
        .flush_graphics_credits = flushGraphicsCredits,
        .acknowledge_frame = acknowledgeFrame,
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

fn acknowledgeFrame(context: *anyopaque, ack: source_namespace.schema.FrameAck) !void {
    const capture: *EffectCapture = @ptrCast(@alignCast(context));
    capture.observeCommit();
    capture.append(.acknowledgement);
    capture.acknowledgements[capture.acknowledgement_count] = ack;
    capture.acknowledgement_count += 1;

    if (capture.failure == .second_acknowledgement and capture.acknowledgement_count == 2) {
        return error.AcknowledgementFailure;
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

fn append(capture: *EffectCapture, event: source_namespace.Event) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

pub fn eventSlice(capture: *const EffectCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}

pub fn acknowledgementSlice(capture: *const EffectCapture) []const source_namespace.schema.FrameAck {
    return capture.acknowledgements[0..capture.acknowledgement_count];
}
