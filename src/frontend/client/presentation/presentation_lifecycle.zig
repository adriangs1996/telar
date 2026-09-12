//! Presentation event adaptation for one disposable client. The presenter
//! decides when and what to paint. This adapter releases async tokens and
//! supplies concrete effects to the application delivery policy.

const TerminalClient = @import("../TerminalClient.zig");
const host = TerminalClient.of;
const Client = @import("telar-client").AttachedClient;
const presentation_projection = @import("presentation_projection.zig");
const mark_module = @import("telar-core").mark;
const TokenType = @import("telar-client").Token;
const DeliverPresentationHandlerType = @import("telar-client").DeliverPresentationHandler;
const OutputType = @import("../resources/Output.zig");
const EffectsType = @import("telar-client").PresentationEffects;
const runtime_transport = @import("telar-client").runtime_io;

/// Publishes every revision the presenter uses after one client event commits.
///
/// ```zig
/// try presentation_lifecycle.observe(client);
/// ```
pub fn observe(client: *Client) !void {
    try host(client).presenter.observe(presentation_projection.observation(client));
}

/// Completes one paced draw. Damage is retired only after the host terminal
/// flush succeeds; cell acknowledgements already followed frame application.
///
/// ```zig
/// try presentation_lifecycle.handleDraw(client, result);
/// ```
pub fn handleDraw(client: *Client, result: anyerror!void) !void {
    try host(client).presenter.completeDraw(result);
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
    if (host(client).output) |*output| {
        if (output.pending) {
            output.draw_deferred = true;
            return;
        }

        try output.prepareFrame(@as(usize, host(client).presenter.screen.back.w) * host(client).presenter.screen.back.h);
    }

    const delivery = try host(client).presenter.presentDue(
        presentation_projection.projection(client),
        presentation_projection.resources(client),
    ) orelse return;
    errdefer _ = host(client).presenter.presentation_state.complete(delivery, .failed);

    if (host(client).output) |*output| {
        if (output.writer.end != 0) {
            output.delivery = delivery;
            try pumpOutput(client);
            return;
        }
    }

    try deliver(client, delivery);
}

fn deliver(client: *Client, token: TokenType) !void {
    const delivery = host(client).presenter.presentation_state.complete(token, .delivered) orelse return;
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
    try host(client).presenter.completeMediaTick(result);
    if (host(client).output) |*output| {
        if (output.pending) {
            output.media_deferred = true;
            return;
        }

        try output.prepareFrame(@as(usize, host(client).presenter.screen.back.w) * host(client).presenter.screen.back.h);
    }

    try host(client).presenter.presentMedia(
        presentation_projection.projection(client),
        presentation_projection.resources(client),
    );
}

/// Starts one host write without lending model or presentation state.
/// Example: `try pumpOutput(client);`.
pub fn pumpOutput(client: *Client) anyerror!void {
    const output = if (host(client).output) |*output| output else return;
    const pending = output.begin() orelse return;
    mark_module(client.io, .host_flush_start);
    const work = try output.tryWrite(pending);
    if (work.bytes.len == 0) {
        try handleWritten(client, {});
        return;
    }

    try host(client).select.concurrent(.host_written, OutputType.write, .{work});
}

/// Commits only the presentation whose bytes reached the host, then folds work.
/// Example: `try handleWritten(client, result);`.
pub fn handleWritten(client: *Client, result: anyerror!void) !void {
    mark_module(client.io, .host_flush_done);
    const output = if (host(client).output) |*output| output else unreachable;
    const token = output.delivery;
    const completed = output.complete(result) catch |err| {
        if (token) |value| {
            _ = host(client).presenter.presentation_state.complete(value, .failed);
        }
        return err;
    };
    if (completed) |delivery| {
        try deliver(client, delivery);
    }

    if (output.draw_deferred) {
        output.draw_deferred = false;
        try host(client).presenter.requestDraw();
    }
    if (output.media_deferred) {
        output.media_deferred = false;
        try host(client).presenter.requestMedia();
    }

    try pumpOutput(client);
}

fn deliveryEffects(client: *Client) EffectsType {
    return .{
        .context = client,
        .flush_graphics_credits = flushGraphicsCredits,
        .request_media = requestMedia,
    };
}

fn flushGraphicsCredits(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try runtime_transport.flushGraphicsCredits(client);
}

fn requestMedia(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    try host(client).presenter.requestMedia();
}
