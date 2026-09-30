//! Review admission and worker completion.
const agent_status = @import("agent_status.zig");
const client_connection = @import("client_connection.zig");
const std = @import("std");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Context = @import("../change_review/Context.zig");
const Job = @import("../change_review/Job.zig");
const PendingFailure = @import("delivery/PendingFailure.zig");
const PaneKey = @import("../pane/PaneKey.zig");
const Service = @import("../change_review/Service.zig");
const Group = @import("../change_review/Group.zig");
const StorageInput = @import("../change_review/StorageInput.zig");
const storage = @import("../change_review/storage.zig");
const limit_reached = @import("limit_reached.zig");

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

/// Takes one review worker's result and replies to the client that asked.
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
        }
    }
    retire(model, job);
}

fn retire(model: *RuntimeModel, job: *Job) void {
    model.review_jobs.remove(job);
    defer job.deinit();
    if (reachOf(job)) |reach| {
        limit_reached.report(model, reach);
    }

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
    model.review_owner_revision +%= 1;
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
    const inputs = ownerInputs(model);
    if (!model.review_discovery_blocked and std.mem.eql(u64, &inputs, &model.review_owner_inputs)) {
        // Safe builds prove the revisions cover every owner input.
        if (std.debug.runtime_safety) {
            std.debug.assert(ownerStamp(model) == model.review_owner_stamp);
        }

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
    model.review_owner_inputs = ownerInputs(model);
    if (std.debug.runtime_safety) {
        model.review_owner_stamp = ownerStamp(model);
    }
}

/// The revisions that advance whenever an owner input can change: panes
/// added, exited or removed, agents and their session references, and
/// close requests, review bindings and agent session ids.
fn ownerInputs(model: *const RuntimeModel) [4]u64 {
    return .{
        model.panes.revision,
        model.agent_revision,
        model.agent_session_revision,
        model.review_owner_revision,
    };
}

/// Summarizes everything a pane's review owner depends on, in one pass
/// without agent lookups; safe builds check `ownerInputs` against it: pane identity and lifecycle,
/// the agent projection and session references, and each
/// pane's current review binding.
fn ownerStamp(model: *const RuntimeModel) u64 {
    var hasher = std.hash.Wyhash.init(model.agent_revision);
    std.hash.autoHash(&hasher, model.agent_session_revision);
    for (model.panes.items) |entry| {
        const pane = entry orelse continue;
        std.hash.autoHash(&hasher, core.raw(pane.id));
        std.hash.autoHash(&hasher, pane.generation);
        std.hash.autoHash(&hasher, pane.close_requested);
        std.hash.autoHash(&hasher, pane.exit != null);
        std.hash.autoHash(&hasher, pane.review_availability.revision);
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

        // A hook's file evidence and the feedback handed to the agent go
        // only through a connection confirmed inside the pane.
        if (scoped and !confirmedInside(client, context.pane)) {
            return error.ForeignProcess;
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

fn confirmedInside(client: *const Session, pane: PaneKey) bool {
    const verified = client.hook_pane orelse return false;
    return verified.id == pane.id and verified.generation == pane.generation;
}

/// The limit a finished review job reached: the one that failed it, or the
/// one it reached while keeping what fit.
fn reachOf(job: *const Job) ?core.LimitReach {
    if (job.failure) |err| {
        const limit = limitOf(err) orelse return null;
        return .{
            .limit = limit,
        };
    }

    const result = job.result orelse return null;
    return result.limit;
}

/// Which review limit an error of the review worker means.
fn limitOf(err: anyerror) ?core.Limit {
    return switch (err) {
        error.ReviewGroupsFull => Service.groups_limit,
        error.ReviewPendingSamplesFull => Group.samples_limit,
        error.ReviewArchiveFull => Group.archive_limit,
        error.ReviewEditionsFull => Group.editions_limit,
        error.ReviewConversationStorageFull => StorageInput.conversation_storage_limit,
        error.ReviewGlobalStorageFull => StorageInput.global_storage_limit,
        error.ReviewStorageFilesExceeded => storage.files_limit,
        error.ReviewPatchTooLarge => core.change_review.patch_limit,
        error.ReviewCommentCapacity => core.change_review.comments_limit,
        else => null,
    };
}

fn failure(request_id: core.RequestId, err: anyerror) PendingFailure {
    return .{ .request_id = request_id, .code = switch (err) {
        error.PaneNotFound => .pane_not_found,
        error.PaneExited => .pane_exited,
        error.ForeignProcess => .foreign_process,
        error.ReviewBusy, error.OutOfMemory, error.WriteFailed => .resource_limit,
        else => if (limitOf(err) != null) .resource_limit else .invalid_request,
    }, .message = switch (err) {
        error.PaneNotFound => "review pane no longer exists",
        error.ForeignProcess => "only a process inside that pane may send its agent's review evidence",
        error.PaneExited => "review pane is closing",
        error.AgentNotReady, error.InvalidReviewOwner => "review does not belong to the current agent session",
        error.StaleReview => "review changed in another client; refresh before saving",
        error.ReviewAlreadySubmitted => "submitted review comments are immutable",
        error.ReviewBusy => "another review operation is pending; retry shortly",
        error.EditionNotFound => "review edition is unavailable",
        error.EmptyComment => "write a comment before saving it",
        error.NoSavedComments => "save at least one comment before sending the review",
        error.InvalidReviewAnchor => "comment range is outside the immutable edition",
        error.InvalidPatch => "edit has no complete supported text diff; it was not retained",
        error.MissingReviewBaseline => "no matching before snapshot; edit was not attributed",
        error.ReviewGroupsFull => "review holds too many conversations with unmatched edits; retry once their tools finish",
        error.ReviewPendingSamplesFull => "too many edits of this conversation await their after snapshot",
        error.ReviewArchiveFull => "this conversation reached its review edition limit",
        error.ReviewEditionsFull => "too many recent editions hold unsent comments; send or delete some",
        error.ReviewConversationStorageFull, error.ReviewGlobalStorageFull, error.ReviewStorageFilesExceeded => "review storage is full; existing editions were preserved",
        error.ReviewPatchTooLarge => "the edit's first hunk does not fit the review diff limit",
        error.ReviewCommentCapacity => "this edition reached its comment limit",
        error.WriteFailed => "review exceeds its bounded storage or feedback limit",
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
    const provider = agent_status.projectedProvider(model, key);
    const reference = agent_status.sessionReference(model, key) orelse return error.AgentNotReady;
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

    try std.testing.expect(agent_status.observeProcess(model, .{
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

    try std.testing.expect(agent_status.observeSessionReference(model, 
        agent_identity.fromPane(pane),
        try SessionReference.init("0192aaaa-bbbb-cccc-dddd-eeeeffff0000", 1_000),
    ));
    discover(model);
    try std.testing.expect(pane.review_availability.active);
    try std.testing.expect(pane.review_availability.discovery_started);
}

test "a review job that stops at a limit reports it by name and frees its slot" {
    const fixture = try std.testing.allocator.create(RequestFixture);
    defer std.testing.allocator.destroy(fixture);
    try fixture.init();
    defer fixture.deinit();

    const model = &fixture.runtime.model;
    const context = try Context.init(.{ .id = @enumFromInt(9), .generation = 1 }, .claude, "thread");
    const job = &model.review_jobs.storage[0];
    job.* = .{
        .service = model.review_service.?,
        .context = context,
        .client = null,
        .request_id = .none,
        .wire_len = 0,
        .failure = error.ReviewGroupsFull,
    };
    model.review_jobs.items[0] = job;

    finish(model, job);
    try std.testing.expect(model.review_jobs.items[0] == null);
    const slot = model.limit_reaches.find("review.group_capacity").?;
    try std.testing.expectEqual(@as(u64, Service.group_capacity), model.limit_reaches.value[slot]);
}

test "every review worker limit error names its limit and answers resource_limit" {
    const errors = [_]anyerror{
        error.ReviewGroupsFull,
        error.ReviewPendingSamplesFull,
        error.ReviewArchiveFull,
        error.ReviewEditionsFull,
        error.ReviewConversationStorageFull,
        error.ReviewGlobalStorageFull,
        error.ReviewStorageFilesExceeded,
        error.ReviewPatchTooLarge,
        error.ReviewCommentCapacity,
    };
    for (errors) |err| {
        try std.testing.expect(limitOf(err) != null);
        try std.testing.expect(core.limit_reached.isLimitError(err));
        try std.testing.expectEqual(core.FailureCode.resource_limit, failure(@enumFromInt(1), err).code);
    }
}
