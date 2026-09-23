//! The one flush that follows every runtime update: reaps finished panes,
//! delivers at most one message per client and settles observed damage.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("../RuntimeModel.zig");
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
/// try client_delivery.flush(model);
/// ```
pub fn flush(model: *RuntimeModel) !void {
    var passes: usize = 0;
    while (passes <= store_support.max_clients) : (passes += 1) {
        model.collect();
        change_review.discover(model);

        if (!pumpClients(model)) {
            break;
        }
    }

    scheduleCellPublication(model) catch {
        // The timer reset itself; the next flush retries it.
    };

    for (model.panes.items) |slot| {
        const pane = slot orelse continue;
        try events.panes.Projection.scheduleMedia(model, pane);
        settlePaneDamage(model, pane);
    }
}

/// Reports whether every live client has consumed the shutdown delivery.
///
/// ```zig
/// if (client_delivery.shutdownDelivered(model)) return true;
/// ```
pub fn shutdownDelivered(model: *const RuntimeModel) bool {
    if (!model.shutdown.isRequested()) {
        return false;
    }

    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;
        if (!session.closing and (session.delivery.stopping() or session.send_pending)) {
            return false;
        }
    }

    return true;
}

fn pumpClients(model: *RuntimeModel) bool {
    var dropped = false;
    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;
        const key = session.key;

        pump(model, session) catch {
            model.dropClient(key);
            dropped = true;
        };
    }

    return dropped;
}

fn pump(model: *RuntimeModel, session: *Session) !void {
    session.cell_deadline_ns = null;
    if (!session.active() or session.send_pending) {
        return;
    }

    const pending = try session.delivery.prepare(.{
        .io = model.io,
        .attachments = &session.attachments,
        .sources = .{
            .panes = &model.panes,
            .workspaces = model.workspaceReader(),
            .agents = &model.agents,
            .manifests = &model.resources.agent_manifests,
            .system_metrics = &model.system_metrics,
            .proxy_active = model.resources.proxy.active(),
            .proxy_scope = model.resources.proxy.interceptionScope(),
            .proxy_system_trusted = model.resources.proxy.systemTrusted(),
            .home = model.home,
            .client_layouts = &model.client_layouts,
            .now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
        },
        .metrics = &model.metrics,
    });
    const prepared = pending orelse {
        session.cell_deadline_ns = session.attachments.cellDeadline();
        return;
    };
    errdefer session.delivery.abort(prepared);

    try events.clients.startSend(model, session, prepared.payload);
    session.delivery.commit(.{
        .prepared = prepared,
        .attachments = &session.attachments,
        .metrics = &model.metrics,
    });
}

// Scheduling exception: std.Io.Threaded allocates task records outside Telar
// Heap accounting. One logical timer and at most two child waits bound the
// concurrent work; retaining armed deadlines avoids rebuilding transient waits.
// There is no task per output update. Reusing the cancellable scheduler keeps
// shutdown under the runtime's actor lifetime, before the model is released.
fn scheduleCellPublication(model: *RuntimeModel) !void {
    var earliest: ?u64 = null;
    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;
        if (!session.active() or session.send_pending) {
            continue;
        }

        const deadline = session.cell_deadline_ns orelse continue;
        earliest = @min(earliest orelse deadline, deadline);
    }

    if (model.cell_timer.updateEarlier(model.io, earliest) != .schedule) {
        return;
    }

    model.select.concurrent(.cell_publication_due, core.deadline_timer.wait, .{ model.io, &model.cell_timer }) catch |err| {
        model.cell_timer.schedulingFailed();
        return err;
    };
}

fn settlePaneDamage(model: *RuntimeModel, pane: *PaneType) void {
    if (pane.render_pending) {
        return;
    }

    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;
        const attachment = session.attachments.find(pane.id) orelse continue;

        if (attachment.observedCellRevision() != pane.cell_revision) {
            return;
        }
    }

    @memset(pane.damaged_rows, false);
    pane.dirty = false;
}
