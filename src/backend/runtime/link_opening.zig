//! A client opens a local file link in an editor: a worker reuses an
//! editor already running in a pane of the same tab when it can.

const client_connection = @import("client_connection.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const EditorOpenJob = @import("../editors/Job.zig");
const client_request = @import("client_request.zig");

/// Starts the single editor-reuse worker for one request.
///
/// ```zig
/// try link_opening.start(model, session, request);
/// ```
pub fn start(model: *RuntimeModel, session: *Session, request: core.OpenEditor) !void {
    admit(model, session, request) catch |err| {
        const code: core.FailureCode = switch (err) {
            error.PaneNotFound => .pane_not_found,
            error.PaneExited => .pane_exited,
            error.EditorOpenBusy => .resource_limit,
            else => .internal,
        };
        try client_request.fail(session, request.request_id, code, "Could not request editor reuse");
    };
}

/// Takes the worker's result and replies to the client that asked.
///
/// ```zig
/// link_opening.finish(model, job);
/// ```
pub fn finish(model: *RuntimeModel, job: *EditorOpenJob) void {
    const result = retire(model, job);
    const client = model.clients.resolve(job.client) orelse return;
    if (!client.active()) {
        return;
    }

    client.delivery.responses.push(.{ .editor_opened = result }) catch {
        client_connection.drop(model, job.client);
    };
}

fn admit(model: *RuntimeModel, session: *Session, request: core.OpenEditor) !void {
    const source = model.panes.resolve(.{ .id = request.pane_id, .generation = request.pane_generation }) orelse return error.PaneNotFound;
    if (source.close_requested or source.exit != null) {
        return error.PaneExited;
    }

    if (model.editor_open.busy) {
        return error.EditorOpenBusy;
    }

    const job = &model.editor_open.job;
    job.* = .{
        .client = session.key,
        .request = try core.OwnedEditorOpen.init(request),
        .environment = model.inherited_environment,
        .result = .{ .request_id = request.request_id, .outcome = .unavailable },
    };

    const kind = core.editor.identify(request.editor);
    if (kind != .unsupported) {
        for (model.panes.items) |slot| {
            const pane = slot orelse continue;
            if (pane.kind != .terminal or pane.close_requested or pane.exit != null or !std.meta.eql(pane.location, source.location)) {
                continue;
            }

            if (core.editor.identify(pane.agent_process_cache.name()) != kind) {
                continue;
            }

            const group = pane.session.foregroundProcessGroup() orelse continue;
            const pid = std.math.cast(u32, group) orelse continue;
            job.candidates[job.candidate_count] = .{ .pane = pane.key(), .process_group = pid };
            job.candidate_count += 1;
        }
    }

    model.editor_open.busy = true;
    errdefer model.editor_open.busy = false;
    try model.select.concurrent(.editor_opened, EditorOpenJob.run, .{ job, model.io });
}

fn retire(model: *RuntimeModel, job: *EditorOpenJob) core.EditorOpened {
    std.debug.assert(model.editor_open.busy and job == &model.editor_open.job);
    model.editor_open.busy = false;
    var result = job.result;
    const source = model.panes.resolve(.{ .id = job.request.pane_id, .generation = job.request.pane_generation });
    if (source == null or source.?.close_requested or source.?.exit != null) {
        result.outcome = .failed;
        return result;
    }

    if (result.outcome == .opened) {
        const target = model.panes.resolve(.{ .id = result.pane_id, .generation = result.pane_generation });
        if (target == null or target.?.close_requested or target.?.exit != null or !std.meta.eql(target.?.location, source.?.location)) {
            result.outcome = .failed;
        }
    }

    return result;
}
