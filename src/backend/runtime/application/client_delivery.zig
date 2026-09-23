//! The one flush that follows every runtime update: reaps finished panes,
//! delivers at most one message per client and settles observed damage.

const core = @import("telar-core");
const std = @import("std");
const Application = @import("Application.zig");
const Session = @import("../client/Session.zig");
const PaneType = @import("../../pane/Pane.zig");
const change_review = @import("change_review.zig");
const events = @import("events.zig");
const store_support = @import("../client/store_support.zig");

/// Delivers pending output to every affected client in a single pass. A
/// client dropped during the pass may leave resync notices for clients the
/// pass already visited, so the pass repeats; every drop marks its session
/// closing and closing sessions are never pumped, which bounds the repeats.
///
/// ```zig
/// try client_delivery.flush(application);
/// ```
pub fn flush(application: *Application) !void {
    var passes: usize = 0;
    while (passes <= store_support.max_clients) : (passes += 1) {
        application.collect();
        change_review.discover(application);

        if (!pumpClients(application)) {
            break;
        }
    }

    scheduleCellPublication(application) catch {
        // The timer reset itself; the next flush retries it.
    };

    for (application.model.panes.items) |slot| {
        const pane = slot orelse continue;
        try events.panes.Projection.scheduleMedia(application, pane);
        settlePaneDamage(application, pane);
    }
}

/// Reports whether every live client has consumed the shutdown delivery.
///
/// ```zig
/// if (client_delivery.shutdownDelivered(application)) return true;
/// ```
pub fn shutdownDelivered(application: *const Application) bool {
    if (!application.shutdown.isRequested()) {
        return false;
    }

    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;
        if (!session.closing and (session.delivery.stopping() or session.send_pending)) {
            return false;
        }
    }

    return true;
}

fn pumpClients(application: *Application) bool {
    var dropped = false;
    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;
        const key = session.key;

        pump(application, session) catch {
            application.dropClient(key);
            dropped = true;
        };
    }

    return dropped;
}

fn pump(application: *Application, session: *Session) !void {
    session.cell_deadline_ns = null;
    if (!session.active() or session.send_pending) {
        return;
    }

    const pending = try session.delivery.prepare(.{
        .io = application.io,
        .attachments = &session.attachments,
        .sources = .{
            .panes = &application.model.panes,
            .workspaces = application.workspaceReader(),
            .agents = &application.model.agents,
            .manifests = application.agent_manifests,
            .system_metrics = &application.system_metrics,
            .proxy_active = application.proxy_runtime.active(),
            .proxy_scope = application.proxy_runtime.interceptionScope(),
            .proxy_system_trusted = application.proxy_runtime.systemTrusted(),
            .home = application.home,
            .client_layouts = &application.model.client_layouts,
            .now_ms = std.Io.Timestamp.now(application.io, .real).toMilliseconds(),
        },
        .metrics = &application.metrics,
    });
    const prepared = pending orelse {
        session.cell_deadline_ns = session.attachments.cellDeadline();
        return;
    };
    errdefer session.delivery.abort(prepared);

    try events.clients.startSend(application, session, prepared.payload);
    session.delivery.commit(.{
        .prepared = prepared,
        .attachments = &session.attachments,
        .metrics = &application.metrics,
    });
}

// Scheduling exception: std.Io.Threaded allocates task records outside Telar
// Heap accounting. One logical timer and at most two child waits bound the
// concurrent work; retaining armed deadlines avoids rebuilding transient waits.
// There is no task per output update. Reusing the cancellable scheduler keeps
// shutdown under the runtime's actor lifetime, before the model is released.
fn scheduleCellPublication(application: *Application) !void {
    var earliest: ?u64 = null;
    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;
        if (!session.active() or session.send_pending) {
            continue;
        }

        const deadline = session.cell_deadline_ns orelse continue;
        earliest = @min(earliest orelse deadline, deadline);
    }

    if (application.cell_timer.updateEarlier(application.io, earliest) != .schedule) {
        return;
    }

    application.select.concurrent(.cell_publication_due, core.deadline_timer.wait, .{ application.io, &application.cell_timer }) catch |err| {
        application.cell_timer.schedulingFailed();
        return err;
    };
}

fn settlePaneDamage(application: *Application, pane: *PaneType) void {
    if (pane.render_pending) {
        return;
    }

    for (&application.clients.items) |*slot| {
        const session = slot.* orelse continue;
        const attachment = session.attachments.find(pane.id) orelse continue;

        if (attachment.observedCellRevision() != pane.cell_revision) {
            return;
        }
    }

    @memset(pane.damaged_rows, false);
    pane.dirty = false;
}
