//! Review admission, worker completion and cooperative provider handoff.
const client_connection = @import("client_connection.zig");
const std = @import("std");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Context = @import("../change_review/Context.zig");
const Job = @import("../change_review/Job.zig");
const PendingFailure = @import("delivery/PendingFailure.zig");
const PaneKey = @import("../pane/PaneKey.zig");

/// Admits one review query, command or sample and starts its worker.
///
/// ```zig
/// try change_review.start(model, session, request);
/// ```
pub fn start(model: *RuntimeModel, session: *Session, request: anytype) !void {
    admit(model, session, request) catch |err| {
        try session.delivery.responses.push(.{ .request_failed = failure(request.request_id, err) });
    };
}

/// Takes one review worker's result, hands submitted feedback to the agent
/// and replies to the client that asked.
///
/// ```zig
/// change_review.finish(model, job);
/// ```
pub fn finish(model: *RuntimeModel, job: *Job) void {
    if (job.failure == null) {
        const current = owner(model, job.context.pane) catch |err| {
            job.failure = err;
            retire(model, job);
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
    retire(model, job);
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

fn retire(model: *RuntimeModel, job: *Job) void {
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
        client.delivery.responses.push(.{ .request_failed = failure(job.request_id, err) }) catch {
            client_connection.drop(model, client_key);
            return;
        };
    } else if (job.result) |result| {
        client.delivery.responses.push(.{ .change_review = result }) catch {
            client_connection.drop(model, client_key);
            return;
        };
        job.result = null;
    }
}

/// Invalidates discovery while clients keep their currently opened immutable edition.
/// Example: `change_review.publish(model, change);`.
pub fn publish(model: *RuntimeModel, change: core.ChangeReviewChanged) void {
    const key: PaneKey = .{ .id = change.pane_id, .generation = change.pane_generation };
    const context = owner(model, key) catch return;
    if (!std.mem.eql(u8, context.sessionSlice(), change.session)) {
        return;
    }

    const pane = model.panes.resolve(key) orelse return;
    pane.review_availability.record(context, change.latest_edition_id);
}

/// Rebinds each pane's review owner and starts bounded, one-shot durable
/// discovery. Runs only when panes, agent sessions or review bindings
/// changed since the last run, or when a busy job table skipped a pane.
/// Example: `change_review.discover(model);`.
pub fn discover(model: *RuntimeModel) void {
    if (model.shutdown.isRequested()) {
        return;
    }

    const service = model.review_service orelse return;
    if (!model.review_discovery_blocked and ownerStamp(model) == model.review_owner_stamp) {
        return;
    }

    var blocked = false;
    for (model.panes.items) |entry| {
        const pane = entry orelse continue;
        const context = owner(model, pane.key()) catch {
            pane.review_availability.invalidate();
            continue;
        };
        pane.review_availability.bind(context);
        if (pane.review_availability.discovery_started) {
            continue;
        }

        const slot = model.review_jobs.discoverySlot() orelse {
            blocked = true;
            continue;
        };
        const job = &model.review_jobs.storage[slot];
        job.* = .{ .service = service, .context = context, .client = null, .request_id = .none, .wire_len = 0 };
        model.review_jobs.items[slot] = job;
        pane.review_availability.discovery_started = true;
        model.select.concurrent(.change_review_completed, Job.run, .{ job, model.io }) catch {
            model.review_jobs.items[slot] = null;
            _ = service.dropped.fetchAdd(1, .monotonic);
        };
    }

    model.review_discovery_blocked = blocked;
    model.review_owner_stamp = ownerStamp(model);
}

/// Summarizes everything a pane's review owner depends on, in one pass
/// without agent lookups: pane identity and lifecycle, the managed
/// conversation, the agent projection and session references, and each
/// pane's current review binding.
fn ownerStamp(model: *const RuntimeModel) u64 {
    var hasher = std.hash.Wyhash.init(model.agents.revision);
    std.hash.autoHash(&hasher, model.agents.session_revision);
    for (model.panes.items) |entry| {
        const pane = entry orelse continue;
        std.hash.autoHash(&hasher, core.raw(pane.id));
        std.hash.autoHash(&hasher, pane.generation);
        std.hash.autoHash(&hasher, pane.close_requested);
        std.hash.autoHash(&hasher, pane.exit != null);
        std.hash.autoHash(&hasher, pane.review_availability.revision);
        if (pane.agent_thread) |snapshot| {
            hasher.update(snapshot.threadId());
        }
    }

    return hasher.final();
}

fn admit(model: *RuntimeModel, client: *Session, value: anytype) !void {
    const context = try owner(model, .{ .id = value.pane_id, .generation = value.pane_generation });
    const T = @TypeOf(value);
    if ((T != core.QueryChangeReview or value.session.len != 0) and !std.mem.eql(u8, value.session, context.sessionSlice())) {
        return error.InvalidReviewOwner;
    }
    if (T == core.ReportChangeReviewSample or T == core.ChangeReviewCommand) {
        const scoped = if (T == core.ReportChangeReviewSample) true else value.action == .feedback or value.action == .ack_feedback;
        if (scoped and value.provider != context.provider) {
            return error.InvalidReviewOwner;
        }
    }
    const service = model.review_service orelse return error.ReviewUnavailable;
    if (client.delivery.responses.hasChangeReview()) {
        return error.ReviewBusy;
    }
    const slot = try model.review_jobs.available(client.key);
    const job = &model.review_jobs.storage[slot];
    job.* = .{ .service = service, .context = context, .client = client.key, .request_id = value.request_id, .wire_len = 0 };
    const wire = if (T == core.QueryChangeReview) try core.encodeQueryChangeReview(&job.wire, value) else if (T == core.ChangeReviewCommand) try core.encodeChangeReviewCommand(&job.wire, value) else try core.encodeReportChangeReviewSample(&job.wire, value);
    job.wire_len = @intCast(wire.len);
    model.review_jobs.items[slot] = job;
    errdefer model.review_jobs.items[slot] = null;
    try model.select.concurrent(.change_review_completed, Job.run, .{ job, model.io });
}

fn failure(request_id: core.RequestId, err: anyerror) PendingFailure {
    return .{ .request_id = request_id, .code = switch (err) {
        error.PaneNotFound => .pane_not_found,
        error.PaneExited => .pane_exited,
        error.AgentBusy => .agent_blocked,
        error.ReviewBusy, error.ReviewCapacity, error.OutOfMemory, error.WriteFailed => .resource_limit,
        else => .invalid_request,
    }, .message = switch (err) {
        error.PaneNotFound => "review pane no longer exists",
        error.PaneExited => "review pane is closing",
        error.AgentNotReady, error.InvalidReviewOwner => "review does not belong to the current agent session",
        error.StaleReview => "review changed in another client; refresh before saving",
        error.ReviewAlreadySubmitted => "submitted review comments are immutable",
        error.ReviewBusy => "another review operation is pending; retry shortly",
        error.AgentBusy => "review retained; agent is busy, retry Send review when ready",
        error.EditionNotFound => "review edition is unavailable",
        error.EmptyComment => "write a comment before saving it",
        error.NoSavedComments => "save at least one comment before sending the review",
        error.InvalidReviewAnchor => "comment range is outside the immutable edition",
        error.InvalidPatch => "edit has no complete supported text diff; it was not retained",
        error.MissingReviewBaseline => "no matching before snapshot; edit was not attributed",
        error.ReviewCapacity, error.WriteFailed => "review exceeds its bounded storage or feedback limit",
        error.InvalidReviewStorage => "review storage failed validation; existing file was preserved",
        error.ReviewUnavailable => "review service is unavailable",
        else => "review operation failed; retry without discarding local comments",
    } };
}

fn owner(model: *RuntimeModel, key: PaneKey) !Context {
    const pane = model.panes.resolve(key) orelse return error.PaneNotFound;
    if (pane.close_requested or pane.exit != null) {
        return error.PaneExited;
    }
    if (pane.kind == .agent) {
        const snapshot = pane.agent_thread orelse return error.AgentNotReady;
        return Context.init(key, .codex, snapshot.threadId());
    }
    const provider = model.agents.projectedProvider(key);
    const reference = model.agents.sessionReference(key) orelse return error.AgentNotReady;
    return Context.init(key, provider, reference.slice());
}

const RequestFixture = @import("tests/RequestFixture.zig");
const agent_identity = @import("agent_identity.zig");
const SessionReference = @import("../agent/SessionReference.zig");

test "discovery binds a review owner when only its session reference changes" {
    const fixture = try std.testing.allocator.create(RequestFixture);
    defer std.testing.allocator.destroy(fixture);
    try fixture.init();
    defer fixture.deinit();
    const model = &fixture.runtime.model;
    const pane = try fixture.openPane();

    try std.testing.expect(model.agents.observeProcess(.{
        .identity = agent_identity.fromPane(pane),
        .provider = .claude,
        .process_id = 99,
        .observed_at_ms = 1_000,
    }));
    discover(model);
    try std.testing.expect(!pane.review_availability.active);
    const stamp = model.review_owner_stamp;
    discover(model);
    try std.testing.expectEqual(stamp, model.review_owner_stamp);

    try std.testing.expect(model.agents.observeSessionReference(
        agent_identity.fromPane(pane),
        try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 1_000),
    ));
    discover(model);
    try std.testing.expect(pane.review_availability.active);
    try std.testing.expect(pane.review_availability.discovery_started);
}
