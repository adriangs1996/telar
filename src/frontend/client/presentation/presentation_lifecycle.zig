//! Presentation event adaptation for one disposable client. The presenter
//! decides when and what to paint. This adapter releases async tokens and
//! supplies concrete effects to the application delivery policy.

const Client = @import("../Client.zig");
const presentation_projection = @import("presentation_projection.zig");
const mark_module = @import("telar-core").mark;
const TokenType = @import("telar-client").Token;
const DeliverPresentationHandlerType = @import("telar-client").DeliverPresentationHandler;
const OutputType = @import("../resources/Output.zig");
const EffectsType = @import("telar-client").PresentationEffects;
const runtime_transport = @import("../entrypoints/runtime_io.zig");
const FrameAckType = @import("telar-core").FrameAck;
const now_module = @import("telar-core").now;
const enabled_module = @import("telar-core").enabled;
const elapsed_module = @import("telar-core").elapsed;

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
    mark_module(client.io, .compose_start);
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
    errdefer _ = client.presenter.presentation_state.complete(delivery, .failed);

    if (client.output) |*output| {
        if (output.writer.end != 0) {
            output.delivery = delivery;
            try pumpOutput(client);
            return;
        }
    }

    try deliver(client, delivery);
}

fn deliver(client: *Client, token: TokenType) !void {
    const delivery = client.presenter.presentation_state.complete(token, .delivered) orelse return;
    var use_case: DeliverPresentationHandlerType = .{
        .model = &client.model,
        .effects = deliveryEffects(client),
    };
    try use_case.execute(.{
        .commit = delivery.commit,
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
    mark_module(client.io, .host_flush_start);
    const work = try output.tryWrite(pending);
    if (work.bytes.len == 0) {
        try handleWritten(client, {});
        return;
    }

    try client.select.concurrent(.host_written, OutputType.write, .{work});
}

/// Commits only the presentation whose bytes reached the host, then folds work.
/// Example: `try handleWritten(client, result);`.
pub fn handleWritten(client: *Client, result: anyerror!void) !void {
    mark_module(client.io, .host_flush_done);
    const output = if (client.output) |*output| output else unreachable;
    const token = output.delivery;
    const completed = output.complete(result) catch |err| {
        if (token) |value| {
            _ = client.presenter.presentation_state.complete(value, .failed);
        }
        return err;
    };
    if (completed) |delivery| {
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

fn deliveryEffects(client: *Client) EffectsType {
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

fn acknowledgeFrame(context: *anyopaque, ack: FrameAckType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const ack_started = now_module(client.io);
    try runtime_transport.enqueue(client, .{ .frame_ack = ack });

    if (comptime enabled_module) {
        client.telemetry.metrics.ack_enqueue.observe(
            elapsed_module(ack_started, now_module(client.io)),
        );
    }
}

fn requestMedia(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try client.presenter.requestMedia();
}
