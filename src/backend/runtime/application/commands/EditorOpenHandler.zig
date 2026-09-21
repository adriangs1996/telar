const std = @import("std");
const core = @import("telar-core");
const Application = @import("../Application.zig");
const Request = @import("EditorOpenRequest.zig");
const Job = @import("../../../editors/Job.zig");
const Handler = @This();

application: *Application,

/// Captures only live editor candidates in the source pane's tab, then schedules observation work.
/// Example: `try handler.execute(.{ .client = key, .message = request });`
pub fn execute(self: Handler, request: Request) !void {
    const application = self.application;
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
    try application.select.concurrent(.editor_opened, Job.run, .{ job, application.io });
}

/// Retires the worker and refuses results whose source or destination has gone away.
/// Example: `const result = handler.complete(job);`
pub fn complete(self: Handler, job: *Job) core.EditorOpened {
    const application = self.application;
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
