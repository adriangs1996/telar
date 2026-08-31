//! Presentation event orchestration for one disposable client. The presenter
//! decides when and what to paint. This adapter releases async tokens and
//! delivers effects that cross into runtime transport.

const core = @import("telar-core");
const diagnostics = core.diagnostics;

const Client = @import("client.zig");
const runtime_transport = @import("runtime_transport.zig");

/// Publishes every revision the presenter uses after one client event commits.
///
/// ```zig
/// try presentation_lifecycle.observe(client);
/// ```
pub fn observe(client: *Client) !void {
    try client.presenter.observe(.{
        .model = client.model.version(),
        .graphics_ingress = client.graphics_store.ingressVersion(),
        .attachment_ingress = client.view.kittyAttachments().ingressVersion(),
    });
}

/// Completes one paced draw, then delivers credits and frame acknowledgements
/// only after the host terminal flush succeeds.
///
/// ```zig
/// try presentation_lifecycle.handleDraw(client, result);
/// ```
pub fn handleDraw(client: *Client, result: anyerror!void) !void {
    try client.presenter.completeDraw(result);
    const delivery = try client.presenter.presentDue(client) orelse return;

    try runtime_transport.flushGraphicsCredits(client);
    for (delivery.frame_acks.slice()) |ack| {
        const ack_started = diagnostics.now(client.io);
        try runtime_transport.enqueue(client, .{ .frame_ack = ack });
        if (comptime diagnostics.enabled) {
            client.telemetry.metrics.ack_enqueue.observe(
                diagnostics.elapsed(ack_started, diagnostics.now(client.io)),
            );
        }
    }

    if (delivery.media_pending) {
        try client.presenter.requestMedia();
    }
}

/// Completes one lower-priority, byte-bounded host graphics pass.
///
/// ```zig
/// try presentation_lifecycle.handleMediaTick(client, result);
/// ```
pub fn handleMediaTick(client: *Client, result: anyerror!void) !void {
    try client.presenter.completeMediaTick(result);
    try client.presenter.presentMedia(client);
}
