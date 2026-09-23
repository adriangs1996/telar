//! The one flush that follows every runtime update: reaps finished panes,
//! delivers at most one message per client and settles observed damage.

const pane_closure = @import("pane_closure.zig");
const pane_graphics = @import("pane_graphics.zig");
const client_connection = @import("client_connection.zig");
const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const change_review = @import("change_review.zig");
const agent_snapshot = @import("agent_snapshot.zig");
const Sources = @import("delivery/Sources.zig");
const store_support = @import("client/store_support.zig");

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
        pane_closure.collect(model);
        change_review.discover(model);
        agent_snapshot.refresh(model);

        var sources = deliverySources(model);
        if (agent_snapshot.wanted(model)) {
            sources.agent_entries = agent_snapshot.project(sources, &model.agent_entries, &model.agent_display);
        }

        if (!pumpClients(model, sources)) {
            break;
        }
    }

    scheduleCellPublication(model) catch {
        // The timer reset itself; the next flush retries it.
    };

    for (model.panes.items) |slot| {
        const pane = slot orelse continue;
        try pane_graphics.startMedia(model, pane);
        settleDamage(model, pane);
    }
}

/// Starts runtime shutdown for the requesting client: every active client
/// receives `runtime_stopping` before the runtime stops.
///
/// ```zig
/// client_delivery.stop(model, session);
/// ```
pub fn stop(model: *RuntimeModel, session: *Session) void {
    const requested = model.shutdown.request(session.key) orelse return;
    std.debug.assert(std.meta.eql(model.shutdown.initiator.?, requested.initiator));

    for (&model.clients.items) |*slot| {
        const client = slot.* orelse continue;

        if (client.active()) {
            client.delivery.requestStop();
        }
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

/// The runtime state every client's delivery reads in this flush.
fn deliverySources(model: *RuntimeModel) Sources {
    return .{
        .panes = &model.panes,
        .workspaces = &model.workspaces,
        .agents = &model.agents,
        .manifests = &model.resources.agent_manifests,
        .system_metrics = &model.system_metrics,
        .proxy_active = model.resources.proxy.active(),
        .proxy_scope = model.resources.proxy.interceptionScope(),
        .proxy_system_trusted = model.resources.proxy.systemTrusted(),
        .home = model.home,
        .client_layouts = &model.client_layouts,
        .now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds(),
        .agent_revision = model.agent_snapshot_revision,
    };
}

fn pumpClients(model: *RuntimeModel, sources: Sources) bool {
    var dropped = false;
    for (&model.clients.items) |*slot| {
        const session = slot.* orelse continue;
        const key = session.key;

        pump(model, session, sources) catch {
            client_connection.drop(model, key);
            dropped = true;
        };
    }

    return dropped;
}

fn pump(model: *RuntimeModel, session: *Session, sources: Sources) !void {
    session.cell_deadline_ns = null;
    if (!session.active() or session.send_pending) {
        return;
    }

    const pending = try session.delivery.prepare(.{
        .io = model.io,
        .attachments = &session.attachments,
        .sources = sources,
        .metrics = &model.metrics,
    });
    const prepared = pending orelse {
        session.cell_deadline_ns = session.attachments.cellDeadline();
        return;
    };
    errdefer session.delivery.abort(prepared);

    try client_connection.startSend(model, session, prepared.payload);
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

/// Clears a rendered pane's damage once every attached client observed its
/// current cells. Only this pane's observers are visited.
fn settleDamage(model: *RuntimeModel, pane: *Pane) void {
    if (!pane.dirty or pane.render_pending) {
        return;
    }

    var observers = pane.observers;
    while (model.clients.nextObserver(&observers)) |session| {
        const attachment = session.attachments.find(pane.id) orelse continue;

        if (attachment.observedCellRevision() != pane.cell_revision) {
            return;
        }
    }

    @memset(pane.damaged_rows, false);
    pane.dirty = false;
}
