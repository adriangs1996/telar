//! Child graphics reach clients on the media path: a media actor decodes
//! queued KGP work, the runtime synchronizes each attachment's graphics
//! projection, and clients steer it with snapshots, credit and transport.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const AttachmentStore = @import("attachment/AttachmentStore.zig");
const MediaCompletion = @import("entrypoints/events/pane/MediaCompletion.zig");
const MediaStats = @import("../media/Stats.zig");
const MediaWork = @import("entrypoints/events/pane/MediaWork.zig");
const attachment_namespace = @import("attachment/attachment_namespace.zig");
const media_projection = @import("entrypoints/events/pane/media_projection.zig");
const pane_input = @import("pane_input.zig");
const store_support = @import("client/store_support.zig");

/// Replaces the client's graphics baseline for one pane.
///
/// ```zig
/// pane_graphics.snapshot(model, session, request);
/// ```
pub fn snapshot(model: *RuntimeModel, session: *Session, request: core.RequestGraphicsSnapshot) void {
    if (!session.attachments.requestGraphicsSnapshot(request.pane_id)) {
        model.metrics.stale_client_messages += 1;
    }
}

/// Returns graphics bytes the client consumed from one attachment.
///
/// ```zig
/// pane_graphics.returnCredit(model, session, credit);
/// ```
pub fn returnCredit(model: *RuntimeModel, session: *Session, credit: core.GraphicsCredit) void {
    if (session.attachments.returnGraphicsCredit(credit) != .returned) {
        model.metrics.stale_client_messages += 1;
    }
}

/// Selects shared-memory or inline graphics transport for the client.
///
/// ```zig
/// pane_graphics.configure(session, request);
/// ```
pub fn configure(session: *Session, request: core.ConfigureGraphics) void {
    _ = session.attachments.configureGraphics(request.shared);
}

/// Starts the pane's media actor when media work is pending and none runs.
///
/// ```zig
/// try pane_graphics.startMedia(model, pane);
/// ```
pub fn startMedia(model: *RuntimeModel, pane: *Pane) !void {
    const borrow = pane.beginMediaProcessing() orelse return;
    const work: MediaWork = .{ .pane = pane, .current_size = borrow.current_size };

    model.select.concurrent(.pane_media, processMedia, .{work}) catch |err| {
        pane.cancelMediaProcessing();
        return err;
    };
}

/// Commits one media turn, enforces quotas, synchronizes every client's
/// graphics projection and starts any generated terminal response. The
/// update's flush delivers before it starts the next media turn.
///
/// ```zig
/// try pane_graphics.finishMedia(model, completion);
/// ```
pub fn finishMedia(model: *RuntimeModel, completion: MediaCompletion) !void {
    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    pane.completeMediaProcessing();
    recordMediaMetrics(model, completion.stats);
    attachment_namespace.enforceGraphicsQuotas(model.io, pane);
    pane.refreshGraphicsProjection();

    var stores: [store_support.max_clients]*AttachmentStore = undefined;
    var count: usize = 0;
    var observers = pane.observers;
    while (model.clients.nextObserver(&observers)) |client| {
        stores[count] = &client.attachments;
        count += 1;
    }

    const projection = media_projection.synchronize(pane, stores[0..count], completion.stats.reset);
    if (comptime core.enabled) {
        model.metrics.graphics_transfers_staged +|= projection.staged;
    }

    try pane_input.startResponseWrite(model, pane);
}

fn processMedia(work: MediaWork) MediaCompletion {
    const path = core.enter(.media);
    defer path.restore();

    var stats: MediaStats = .{};
    const started = core.now(work.pane.io);
    work.pane.processMedia(work.current_size, &stats);
    stats.elapsed_ns = core.elapsed(started, core.now(work.pane.io));
    return .{ .pane = work.pane.key(), .stats = stats };
}

fn recordMediaMetrics(model: *RuntimeModel, stats: MediaStats) void {
    if (comptime !core.enabled) {
        return;
    }

    model.metrics.media_bytes +|= stats.output_bytes;
    model.metrics.media_discarded_frames +|= stats.discarded_frames;
    model.metrics.media_unavailable_frames +|= stats.unavailable_frames;
    model.metrics.media_forwarded_frames +|= stats.forwarded_frames;
    model.metrics.graphics_transfers_prepared +|= stats.prepared_frames;
    model.metrics.media_direct_frames +|= stats.direct_frames;
    model.metrics.media_file_frames +|= stats.file_frames;
    model.metrics.media_ingest.observe(stats.elapsed_ns);

    if (stats.failed) {
        model.metrics.media_failures +|= 1;
    }

    if (stats.reset) {
        model.metrics.media_resets +|= 1;
    }
}
