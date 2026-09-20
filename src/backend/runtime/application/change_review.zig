//! Review admission, worker completion and cooperative provider handoff.
const std = @import("std");
const core = @import("telar-core");
const Application = @import("Application.zig");
const Session = @import("../client/Session.zig");
const Context = @import("../../change_review/Context.zig");
const Job = @import("../../change_review/Job.zig");
const Controller = @import("../entrypoints/requests/ChangeReviewController.zig");
const review_owner = @import("change_review_owner.zig");

pub fn complete(application: *Application, job: *Job) void {
    if (job.failure == null) {
        const current = review_owner.resolve(application, job.context.pane) catch |err| {
            job.failure = err;
            finish(application, job);
            return;
        };
        if (current.provider != job.context.provider or !std.mem.eql(u8, current.sessionSlice(), job.context.sessionSlice())) {
            job.failure = error.InvalidReviewOwner;
        } else {
            const message = core.decodeClient(job.wire[0..job.wire_len]) catch unreachable;
            if (message == .change_review_command and message.change_review_command.action == .submit) {
                if (handoff(application, job)) |queued| {
                    if (queued) {
                        return;
                    }
                } else |err| {
                    job.failure = err;
                }
            }
        }
    }
    finish(application, job);
}

fn handoff(application: *Application, job: *Job) !bool {
    const pane = application.model.panes.resolve(job.context.pane) orelse return error.PaneNotFound;
    if (pane.kind != .agent) {
        return false;
    }
    const snapshot = try job.result.?.snapshot();
    if (snapshot.delivery != .pending or snapshot.feedback.len == 0) {
        return false;
    }
    var admitted = false;
    var available: ?usize = null;
    for (application.review_admitted, 0..) |entry, index| {
        if (entry) |value| {
            if (value.context.provider == job.context.provider and std.mem.eql(u8, value.context.sessionSlice(), job.context.sessionSlice())) {
                available = index;
                admitted = value.editions.isSet(@intCast(snapshot.edition_id - 1));
                break;
            }
            const previous = application.model.panes.resolve(value.context.pane);
            const retired = if (previous) |owner_pane| owner_pane.kind != .agent or owner_pane.exit != null or owner_pane.agent_thread == null or !std.mem.eql(u8, owner_pane.agent_thread.?.threadId(), value.context.sessionSlice()) else true;
            if (retired and available == null) {
                available = index;
                application.review_admitted[index] = null;
            }
        } else if (available == null) {
            available = index;
        }
    }
    if (!admitted) {
        const slot = available orelse return error.ReviewCapacity;
        const thread = pane.agent_thread orelse return error.AgentNotReady;
        if (!pane.session.agent.session.submit(application.io, .{ .text = snapshot.feedback, .options = thread.options })) {
            return error.AgentBusy;
        }
        if (application.review_admitted[slot] == null) {
            application.review_admitted[slot] = .{ .context = job.context };
        }
        application.review_admitted[slot].?.editions.set(@intCast(snapshot.edition_id - 1));
    }
    const acknowledgment: core.ChangeReviewCommand = .{ .request_id = job.request_id, .pane_id = job.context.pane.id, .pane_generation = job.context.pane.generation, .edition_id = snapshot.edition_id, .action = .ack_feedback, .feedback_id = snapshot.feedback_id, .provider = job.context.provider, .session = job.context.sessionSlice() };
    job.wire_len = @intCast((try core.encodeChangeReviewCommand(&job.wire, acknowledgment)).len);
    job.result.?.deinit();
    job.result = null;
    try application.select.concurrent(.change_review_completed, Job.run, .{ job, application.io });
    return true;
}

fn finish(application: *Application, job: *Job) void {
    application.review_jobs.remove(job);
    defer job.deinit();
    if (job.failure == null and job.result != null and job.result.?.changed_edition != 0) {
        publish(application, .{ .pane_id = job.context.pane.id, .pane_generation = job.context.pane.generation, .session = job.context.sessionSlice(), .latest_edition_id = job.result.?.changed_edition });
    }
    const client = application.clients.resolve(job.client) orelse return;
    if (!client.active()) {
        return;
    }
    if (job.failure) |err| {
        client.delivery.responses.push(.{ .request_failed = Controller.failure(job.request_id, err) }) catch {
            application.dropClient(job.client);
            return;
        };
    } else if (job.result) |result| {
        client.delivery.responses.push(.{ .change_review = result }) catch {
            application.dropClient(job.client);
            return;
        };
        job.result = null;
    }
    application.pumpAll();
}

/// Invalidates discovery while clients keep their currently opened immutable edition.
/// Example: `change_review.publish(application, change);`.
pub fn publish(application: *Application, change: core.ChangeReviewChanged) void {
    for (application.clients.items) |slot| {
        const client = slot orelse continue;
        if (client.active() and client.delivery.runtime_state_requested) {
            client.delivery.reviewChanged(change);
        }
    }
}
