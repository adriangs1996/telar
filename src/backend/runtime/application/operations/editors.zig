//! Runtime editor admission and completion, reached from requests.dispatch and Runtime.update.
const Application = @import("../Application.zig");

const core = @import("telar-core");
const Request = @import("../commands/EditorOpenRequest.zig");
const EditorOpenJob = @import("../../../editors/Job.zig");
const OpenEditor = @import("telar-core").OpenEditor;
const std = @import("std");
const RequestContext = @import("../RequestContext.zig");

/// Example: `try editors.routeOpenEditor(request, message);`.
pub fn routeOpenEditor(request: *RequestContext, message: OpenEditor) !void {
    admitEditorOpen(request, .{ .client = request.session.key, .message = message }) catch |err| {
        try request.session.delivery.responses.push(.{ .request_failed = .{
            .request_id = message.request_id,
            .code = switch (err) {
                error.PaneNotFound => .pane_not_found,
                error.PaneExited => .pane_exited,
                error.EditorOpenBusy => .resource_limit,
                else => .internal,
            },
            .message = "Could not request editor reuse",
        } });
    };
}

fn admitEditorOpen(context: *RequestContext, request: Request) !void {
    const application = context.application;
    const source = application.model.panes.resolve(.{ .id = request.message.pane_id, .generation = request.message.pane_generation }) orelse return error.PaneNotFound;
    if (source.close_requested or source.exit != null) {
        return error.PaneExited;
    }

    if (application.editor_open.busy) {
        return error.EditorOpenBusy;
    }

    const job = &application.editor_open.job;
    job.* = .{
        .client = request.client,
        .request = try core.OwnedEditorOpen.init(request.message),
        .environment = application.inherited_environment,
        .result = .{ .request_id = request.message.request_id, .outcome = .unavailable },
    };
    const kind = core.editor.identify(request.message.editor);
    if (kind != .unsupported) {
        for (application.model.panes.items) |slot| {
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

    application.editor_open.busy = true;
    errdefer application.editor_open.busy = false;
    try application.select.concurrent(.editor_opened, EditorOpenJob.run, .{ job, application.io });
}

fn retireEditorOpen(application: *Application, job: *EditorOpenJob) core.EditorOpened {
    std.debug.assert(application.editor_open.busy and job == &application.editor_open.job);
    application.editor_open.busy = false;
    var result = job.result;
    const source = application.model.panes.resolve(.{ .id = job.request.pane_id, .generation = job.request.pane_generation });
    if (source == null or source.?.close_requested or source.?.exit != null) {
        result.outcome = .failed;
        return result;
    }

    if (result.outcome == .opened) {
        const target = application.model.panes.resolve(.{ .id = result.pane_id, .generation = result.pane_generation });
        if (target == null or target.?.close_requested or target.?.exit != null or !std.meta.eql(target.?.location, source.?.location)) {
            result.outcome = .failed;
        }
    }

    return result;
}

/// Example: `editors.complete(application, job);`.
pub fn complete(application: *Application, job: *EditorOpenJob) void {
    const result = retireEditorOpen(application, job);
    const client = application.clients.resolve(job.client) orelse return;
    if (!client.active()) {
        return;
    }

    client.delivery.responses.push(.{ .editor_opened = result }) catch {
        application.dropClient(job.client);
        return;
    };
    application.pumpAll();
}
