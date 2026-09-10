//! Presentation event adaptation for one disposable client. The presenter
//! decides when and what to paint. This adapter releases async tokens and
//! supplies concrete effects to the application delivery policy.

const core = @import("telar-core");
const diagnostics = core.diagnostics;

const Client = @import("../client.zig");
const presentation_application = @import("telar-client").application.presentation;
const presentation_projection = @import("presentation_projection.zig");
const runtime_transport = @import("../entrypoints/runtime_io.zig");

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
    core.echo_trace.mark(client.io, .compose_start);
    if (client.output) |*output| {
        if (output.pending) {
            output.draw_deferred = true;
            return;
        }

        try output.prepareFrame(@as(usize, client.presenter.screen.back.w) * client.presenter.screen.back.h);
    }

    const delivery = try client.presenter.presentDue(
        presentation_projection.projection(client),
        presentation_projection.resources(client),
    ) orelse return;

    if (client.output) |*output| {
        if (output.writer.end != 0) {
            output.delivery = delivery;
            try pumpOutput(client);
            return;
        }
    }

    try deliver(client, delivery);
}

fn deliver(client: *Client, delivery: @import("presenter.zig").Delivery) !void {
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
    if (client.output) |*output| {
        if (output.pending) {
            output.media_deferred = true;
            return;
        }

        try output.prepareFrame(@as(usize, client.presenter.screen.back.w) * client.presenter.screen.back.h);
    }

    try client.presenter.presentMedia(
        presentation_projection.projection(client),
        presentation_projection.resources(client),
    );
}

/// Starts one host write without lending model or presentation state.
/// Example: `try pumpOutput(client);`.
pub fn pumpOutput(client: *Client) anyerror!void {
    const output = if (client.output) |*output| output else return;
    const pending = output.begin() orelse return;
    core.echo_trace.mark(client.io, .host_flush_start);
    const work = try output.tryWrite(pending);
    if (work.bytes.len == 0) {
        try handleWritten(client, {});
        return;
    }

    try client.select.concurrent(.host_written, @import("../resources/host_output.zig").Output.write, .{work});
}

/// Commits only the presentation whose bytes reached the host, then folds work.
/// Example: `try handleWritten(client, result);`.
pub fn handleWritten(client: *Client, result: anyerror!void) !void {
    core.echo_trace.mark(client.io, .host_flush_done);
    const output = if (client.output) |*output| output else unreachable;
    if (try output.complete(result)) |delivery| {
        try deliver(client, delivery);
    }

    if (output.draw_deferred) {
        output.draw_deferred = false;
        try client.presenter.requestDraw();
    }
    if (output.media_deferred) {
        output.media_deferred = false;
        try client.presenter.requestMedia();
    }

    try pumpOutput(client);
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
