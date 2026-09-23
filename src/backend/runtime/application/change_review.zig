//! Review admission, worker completion and cooperative provider handoff.
const std = @import("std");
const core = @import("telar-core");
const RuntimeModel = @import("../RuntimeModel.zig");
const Session = @import("../client/Session.zig");
const Context = @import("../../change_review/Context.zig");
const Job = @import("../../change_review/Job.zig");
const reviews = @import("operations/reviews.zig");
const PaneKey = @import("../../pane/PaneKey.zig");
const review_owner = @import("change_review_owner.zig");

pub fn complete(model: *RuntimeModel, job: *Job) void {
    if (job.failure == null) {
        const current = review_owner.resolve(model, job.context.pane) catch |err| {
            job.failure = err;
            finish(model, job);
            return;
        };
        if (current.provider != job.context.provider or !std.mem.eql(u8, current.sessionSlice(), job.context.sessionSlice())) {
            job.failure = error.InvalidReviewOwner;
        } else if (job.client != null) {
            const message = core.decodeClient(job.wire[0..job.wire_len]) catch unreachable;
            if (message == .change_review_command and message.change_review_command.action == .submit) {
                if (handoff(model, job)) |queued| {
                    if (queued) {
                        return;
                    }
                } else |err| {
                    job.failure = err;
                }
            }
        }
    }
    finish(model, job);
}

fn handoff(model: *RuntimeModel, job: *Job) !bool {
    const pane = model.panes.resolve(job.context.pane) orelse return error.PaneNotFound;
    if (pane.kind != .agent) {
        return false;
    }
    const snapshot = try job.result.?.snapshot();
    if (snapshot.delivery != .pending or snapshot.feedback.len == 0) {
        return false;
    }
    var admitted = false;
    var available: ?usize = null;
    for (model.review_admitted, 0..) |entry, index| {
        if (entry) |value| {
            if (value.context.provider == job.context.provider and std.mem.eql(u8, value.context.sessionSlice(), job.context.sessionSlice())) {
                available = index;
                admitted = value.editions.isSet(@intCast(snapshot.edition_id - 1));
                break;
            }
            const previous = model.panes.resolve(value.context.pane);
            const retired = if (previous) |owner_pane| owner_pane.kind != .agent or owner_pane.exit != null or owner_pane.agent_thread == null or !std.mem.eql(u8, owner_pane.agent_thread.?.threadId(), value.context.sessionSlice()) else true;
            if (retired and available == null) {
                available = index;
                model.review_admitted[index] = null;
            }
        } else if (available == null) {
            available = index;
        }
    }
    if (!admitted) {
        const slot = available orelse return error.ReviewCapacity;
        const thread = pane.agent_thread orelse return error.AgentNotReady;
        if (!pane.session.agent.session.submit(model.io, .{ .text = snapshot.feedback, .options = thread.options })) {
            return error.AgentBusy;
        }
        if (model.review_admitted[slot] == null) {
            model.review_admitted[slot] = .{ .context = job.context };
        }
        model.review_admitted[slot].?.editions.set(@intCast(snapshot.edition_id - 1));
    }
    const acknowledgment: core.ChangeReviewCommand = .{ .request_id = job.request_id, .pane_id = job.context.pane.id, .pane_generation = job.context.pane.generation, .edition_id = snapshot.edition_id, .action = .ack_feedback, .feedback_id = snapshot.feedback_id, .provider = job.context.provider, .session = job.context.sessionSlice() };
    job.wire_len = @intCast((try core.encodeChangeReviewCommand(&job.wire, acknowledgment)).len);
    job.result.?.deinit();
    job.result = null;
    try model.select.concurrent(.change_review_completed, Job.run, .{ job, model.io });
    return true;
}

fn finish(model: *RuntimeModel, job: *Job) void {
    model.review_jobs.remove(job);
    defer job.deinit();
    if (job.failure == null) {
        publish(model, .{ .pane_id = job.context.pane.id, .pane_generation = job.context.pane.generation, .session = job.context.sessionSlice(), .latest_edition_id = job.latest_edition_id });
    }
    const client_key = job.client orelse return;
    const client = model.clients.resolve(client_key) orelse return;
    if (!client.active()) {
        return;
    }
    if (job.failure) |err| {
        client.delivery.responses.push(.{ .request_failed = reviews.reviewFailure(job.request_id, err) }) catch {
            model.dropClient(client_key);
            return;
        };
    } else if (job.result) |result| {
        client.delivery.responses.push(.{ .change_review = result }) catch {
            model.dropClient(client_key);
            return;
        };
        job.result = null;
    }
}

/// Invalidates discovery while clients keep their currently opened immutable edition.
/// Example: `change_review.publish(model, change);`.
pub fn publish(model: *RuntimeModel, change: core.ChangeReviewChanged) void {
    const key: PaneKey = .{ .id = change.pane_id, .generation = change.pane_generation };
    const context = review_owner.resolve(model, key) catch return;
    if (!std.mem.eql(u8, context.sessionSlice(), change.session)) {
        return;
    }

    const pane = model.panes.resolve(key) orelse return;
    pane.review_availability.record(context, change.latest_edition_id);
}

/// Rebinds cheap runtime metadata and starts bounded, one-shot durable discovery.
/// Example: `change_review.discover(model);`.
pub fn discover(model: *RuntimeModel) void {
    if (model.shutdown.isRequested()) {
        return;
    }

    const service = model.review_service orelse return;
    for (model.panes.items) |entry| {
        const pane = entry orelse continue;
        const context = review_owner.resolve(model, pane.key()) catch {
            pane.review_availability.invalidate();
            continue;
        };
        pane.review_availability.bind(context);
        if (pane.review_availability.discovery_started) {
            continue;
        }

        const slot = model.review_jobs.discoverySlot() orelse continue;
        const job = &model.review_jobs.storage[slot];
        job.* = .{ .service = service, .context = context, .client = null, .request_id = .none, .wire_len = 0 };
        model.review_jobs.items[slot] = job;
        pane.review_availability.discovery_started = true;
        model.select.concurrent(.change_review_completed, Job.run, .{ job, model.io }) catch {
            model.review_jobs.items[slot] = null;
            _ = service.dropped.fetchAdd(1, .monotonic);
        };
    }
}
