//! Presentation event adaptation for one disposable client. The presenter
//! decides when and what to paint. This adapter releases async tokens and
//! supplies concrete effects to the application delivery policy.

const core = @import("telar-core");
const diagnostics = core.diagnostics;

const Client = @import("../client.zig");
const presentation_application = @import("../application/presentation/root.zig");
const presentation_projection = @import("presentation_projection.zig");
const runtime_transport = @import("../connection/runtime_transport.zig");

const presentation_delivery = presentation_application.presentation_delivery;

/// Publishes every revision the presenter uses after one client event commits.
///
/// ```zig
/// try presentation_lifecycle.observe(client);
/// ```
pub fn observe(client: *Client) !void {
    try client.presenter.observe(presentation_projection.observation(client));
}

/// Completes one paced draw, then delivers credits and frame acknowledgements
/// only after the host terminal flush succeeds.
///
/// ```zig
/// try presentation_lifecycle.handleDraw(client, result);
/// ```
pub fn handleDraw(client: *Client, result: anyerror!void) !void {
    try client.presenter.completeDraw(result);
    try presentNow(client);
}

/// Presents whatever is pending on the caller's thread without touching the
/// paced draw token, so both the `.draw` completion and an immediate
/// presentation share one delivery path.
///
/// ```zig
/// try presentation_lifecycle.presentNow(client);
/// ```
pub fn presentNow(client: *Client) !void {
    const delivery = try client.presenter.presentDue(
        presentation_projection.projection(client),
        presentation_projection.resources(client),
    ) orelse return;

    var use_case: presentation_delivery.DeliverPresentationHandler = .{
        .model = &client.model,
        .effects = deliveryEffects(client),
    };
    try use_case.execute(.{
        .commit = delivery.commit,
        .frame_acks = delivery.frame_acks.slice(),
        .media_pending = delivery.media_pending,
    });
}

/// Completes one lower-priority, byte-bounded host graphics pass.
///
/// ```zig
/// try presentation_lifecycle.handleMediaTick(client, result);
/// ```
pub fn handleMediaTick(client: *Client, result: anyerror!void) !void {
    try client.presenter.completeMediaTick(result);
    try client.presenter.presentMedia(
        presentation_projection.projection(client),
        presentation_projection.resources(client),
    );
}

fn deliveryEffects(client: *Client) presentation_delivery.Effects {
    return .{
        .context = client,
        .flush_graphics_credits = flushGraphicsCredits,
        .acknowledge_frame = acknowledgeFrame,
        .request_media = requestMedia,
    };
}

fn flushGraphicsCredits(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try runtime_transport.flushGraphicsCredits(client);
}

fn acknowledgeFrame(context: *anyopaque, ack: core.schema.FrameAck) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const ack_started = diagnostics.now(client.io);
    try runtime_transport.enqueue(client, .{ .frame_ack = ack });

    if (comptime diagnostics.enabled) {
        client.telemetry.metrics.ack_enqueue.observe(
            diagnostics.elapsed(ack_started, diagnostics.now(client.io)),
        );
    }
}

fn requestMedia(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try client.presenter.requestMedia();
}
