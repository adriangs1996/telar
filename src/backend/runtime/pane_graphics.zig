//! Child graphics reach clients on the media path: a media actor decodes
//! queued KGP work, the runtime synchronizes each attachment's graphics
//! projection, and clients steer it with snapshots, credit and transport.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Pane = @import("../pane/Pane.zig");
const Attachments = @import("attachment/Attachments.zig");
const MediaCompletion = @import("events/MediaCompletion.zig");
const MediaStats = @import("../media/Stats.zig");
const attachment_namespace = @import("attachment/attachment_namespace.zig");
const pane_input = @import("pane_input.zig");
const pane_output = @import("pane_output.zig");
const limit_reached = @import("limit_reached.zig");
const GraphicsTrim = @import("attachment/GraphicsTrim.zig");
const std = @import("std");

/// Replaces the client's graphics baseline for one pane.
///
/// ```zig
/// pane_graphics.snapshot(model, session, request);
/// ```
pub fn snapshot(model: *RuntimeModel, session: *Session, request: core.RequestGraphicsSnapshot) void {
    const attachment = model.attachments.find(session.slot, request.pane_id) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    attachment.requestGraphicsSnapshot();
}

/// Returns graphics bytes the client consumed from one attachment. An
/// amount the attachment never spent leaves all credit unchanged.
///
/// ```zig
/// pane_graphics.returnCredit(model, session, credit);
/// ```
pub fn returnCredit(model: *RuntimeModel, session: *Session, credit: core.GraphicsCredit) void {
    const attachment = model.attachments.find(session.slot, credit.pane_id) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    const bytes = std.math.cast(usize, credit.bytes) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    if (!attachment.returnGraphicsCredit(bytes)) {
        model.metrics.stale_client_messages += 1;
    }
}

/// Selects shared-memory or inline graphics transport for the client's
/// existing and future attachments. Repeating the active transport leaves
/// every attachment intact.
///
/// ```zig
/// pane_graphics.configure(model, session, request);
/// ```
pub fn configure(model: *RuntimeModel, session: *Session, request: core.ConfigureGraphics) void {
    if (session.shared_graphics == request.shared) {
        return;
    }

    session.shared_graphics = request.shared;
    for (&model.attachments.record[session.slot]) |slot| {
        const attachment = slot orelse continue;
        attachment.configureGraphics(request.shared);
    }
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
    // A read held for a graphics command resumes first, while the actor is
    // idle and cannot hold it again: nothing that fails below can leave the
    // pane without a read. The flush that ends this update starts the next
    // turn, after `synchronize` read the idle storage; if it cannot, that
    // read falls back to the queue's drop-and-reset policy.
    const resumed = pane_output.resumeRead(model, pane);
    recordMediaMetrics(model, completion.stats);
    const trim = attachment_namespace.enforceGraphicsQuotas(model.io, pane);
    reportLimits(model, pane, trim, completion.stats);
    pane.refreshGraphicsProjection();

    const projection = synchronize(&model.attachments, pane, completion.stats.reset);
    if (comptime core.enabled) {
        model.metrics.graphics_transfers_staged +|= projection.staged;
    }

    const response = pane_input.startResponseWrite(model, pane);
    try resumed;
    try response;
}

/// Reports every graphics bound this batch reached: images and placements
/// the count pass dropped, and uploads the media actor dropped whole.
fn reportLimits(model: *RuntimeModel, pane: *const Pane, trim: GraphicsTrim, stats: MediaStats) void {
    const limits = pane.graphics_limits;
    if (trim.images_dropped != 0) {
        limit_reached.report(model, .{
            .limit = core.Limit.declare("graphics.images_per_screen", "images", limits.images_per_pane / 2),
            .requested = trim.images_found,
        });
    }

    if (trim.placements_dropped != 0) {
        limit_reached.report(model, .{
            .limit = core.Limit.declare("graphics.placements_per_screen", "placements", limits.placements_per_pane / 2),
            .requested = trim.placements_found,
        });
    }

    if (stats.chunk_limited_uploads != 0) {
        limit_reached.report(model, .{
            .limit = core.Limit.declare("graphics.max_chunks_per_image", "chunks", limits.chunks_per_image),
        });
    }

    if (stats.byte_limited_uploads != 0) {
        limit_reached.report(model, .{
            .limit = core.Limit.declare("graphics.max_image_bytes_per_screen", "bytes", pane.graphics_storage_limit),
        });
    }
}

/// Invalidates reset projections first, then freezes at most one transfer per
/// client while the pane's media storage is idle. A failed freeze abandons
/// only that disposable client projection.
///
/// ```zig
/// const stats = pane_graphics.synchronize(&model.attachments, pane, media_reset);
/// ```
pub fn synchronize(attachments: *Attachments, pane: *Pane, media_reset: bool) ProjectionStats {
    if (media_reset) {
        var observers = pane.observers;
        while (attachments.nextObserver(pane.id, &observers)) |attachment| {
            attachment.requestGraphicsSnapshot();
        }
    }

    var stats: ProjectionStats = .{};
    var observers = pane.observers;
    while (observers != 0) {
        const client = @ctz(observers);
        observers &= observers - 1;
        const attachment = attachments.find(client, pane.id) orelse continue;

        if (attachment.hasFrozenGraphics() or attachment.graphicsCaughtUp()) {
            continue;
        }

        const staged = attachment.stageGraphics(attachments.availableGraphicsCredit(client)) catch {
            attachment.abandonGraphics();
            continue;
        };
        if (staged == .staged) {
            stats.staged +|= 1;
        }
    }
    const consumers: Consumers = .{
        .attachments = attachments,
        .pane = pane,
    };
    discardUnwanted(pane, consumers);
    pane.media_ingestion.transfer_preparation.retain(consumers, &pane.media_allocator);

    return stats;
}

/// Releases generations the media actor parked that no shared-transport
/// client can still adopt: each such client either knows the image already
/// or holds that very generation frozen. Keeping them would pin pane quota
/// until the next generation replaced them.
fn discardUnwanted(pane: *Pane, consumers: Consumers) void {
    for (pane.media_ingestion.prepared_transfers.items) |slot| {
        const parked = slot orelse continue;
        if (consumers.wants(parked.metadata.key, true)) {
            continue;
        }
        pane.media_ingestion.prepared_transfers.discard(parked.metadata.key, &pane.media_allocator);
    }
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

const MediaWork = struct {
    pane: *Pane,
    current_size: core.TerminalSize,
};

const ProjectionStats = struct {
    staged: u64 = 0,
};

const Consumers = struct {
    attachments: *Attachments,
    pane: *const Pane,

    /// Example: `const needed = consumers.wants(key, true);`.
    pub fn wants(self: Consumers, key: core.ImageKey, shared: bool) bool {
        var observers = self.pane.observers;
        while (self.attachments.nextObserver(self.pane.id, &observers)) |attachment| {
            if (attachment.graphics.shared_transport != shared or attachment_namespace.knowsImage(attachment, key)) {
                continue;
            }
            if (attachment.graphics.transfer) |transfer| {
                if (std.meta.eql(transfer.metadata.key, key)) {
                    continue;
                }
            }

            return true;
        }

        return false;
    }
};
