//! Presentation event adaptation for one disposable client. The presenter
//! decides when and what to paint. This adapter releases async tokens and
//! supplies concrete effects to the application delivery policy.
const core = @import("telar-core");
const common = @import("telar-client");

const TerminalClient = @import("../TerminalClient.zig");
const presentation_projection = @import("presentation_projection.zig");
const OutputType = @import("../resources/Output.zig");

/// Publishes every revision the presenter uses after one client event commits.
///
/// ```zig
/// try presentation_lifecycle.observe(client);
/// ```
pub fn observe(client: *common.AttachedClient) !void {
    try TerminalClient.of(client).presenter.observe(presentation_projection.observation(client));
}

/// Completes one paced draw. Damage is retired only after the host terminal
/// flush succeeds; cell acknowledgements already followed frame application.
///
/// ```zig
/// try presentation_lifecycle.handleDraw(client, result);
/// ```
pub fn handleDraw(client: *common.AttachedClient, result: anyerror!void) !void {
    try TerminalClient.of(client).presenter.completeDraw(result);
    try presentNow(client);
}

/// Presents whatever is pending on the caller's thread without touching the
/// paced draw token, so both the `.draw` completion and an immediate
/// presentation share one delivery path.
///
/// ```zig
/// try presentation_lifecycle.presentNow(client);
/// ```
pub fn presentNow(client: *common.AttachedClient) !void {
    core.mark(client.io, .compose_start);
    if (TerminalClient.of(client).output) |*output| {
        if (output.pending) {
            output.draw_deferred = true;
            return;
        }

        try output.prepareFrame(@as(usize, TerminalClient.of(client).presenter.screen.back.w) * TerminalClient.of(client).presenter.screen.back.h);
    }

    const delivery = try TerminalClient.of(client).presenter.presentDue(
        presentation_projection.projection(client),
        presentation_projection.resources(client),
    ) orelse return;
    errdefer _ = TerminalClient.of(client).presenter.presentation_state.complete(delivery, .failed);

    if (TerminalClient.of(client).output) |*output| {
        if (output.writer.end != 0) {
            output.delivery = delivery;
            try pumpOutput(client);
            return;
        }
    }

    try deliver(client, delivery);
}

fn deliver(client: *common.AttachedClient, token: common.Token) !void {
    const delivery = TerminalClient.of(client).presenter.presentation_state.complete(token, .delivered) orelse return;
    const geometry = client.presentation.deliveredGeometry();
    TerminalClient.of(client).view.tab_drag.present(&TerminalClient.of(client).view.hits, if (geometry) |value| if (value.location) |location| location.workspace else null else null);
    try common.presentation_delivery.apply(client, delivery.commit);
    if (delivery.media_pending) {
        try TerminalClient.of(client).presenter.requestMedia();
    }
}

/// Completes one lower-priority, byte-bounded host graphics pass.
///
/// ```zig
/// try presentation_lifecycle.handleMediaTick(client, result);
/// ```
pub fn handleMediaTick(client: *common.AttachedClient, result: anyerror!void) !void {
    try TerminalClient.of(client).presenter.completeMediaTick(result);
    if (TerminalClient.of(client).output) |*output| {
        if (output.pending) {
            output.media_deferred = true;
            return;
        }

        try output.prepareFrame(@as(usize, TerminalClient.of(client).presenter.screen.back.w) * TerminalClient.of(client).presenter.screen.back.h);
    }

    try TerminalClient.of(client).presenter.presentMedia(
        presentation_projection.projection(client),
        presentation_projection.resources(client),
    );
}

/// Starts one host write without lending model or presentation state.
/// Example: `try pumpOutput(client);`.
pub fn pumpOutput(client: *common.AttachedClient) anyerror!void {
    const output = if (TerminalClient.of(client).output) |*output| output else return;
    const pending = output.begin() orelse return;
    core.mark(client.io, .host_flush_start);
    const work = try output.tryWrite(pending);
    if (work.bytes.len == 0) {
        try handleWritten(client, {});
        return;
    }

    try TerminalClient.of(client).inbox.start(.host_written, .{ OutputType.write, .{work} });
}

/// Commits only the presentation whose bytes reached the host, then folds work.
/// Example: `try handleWritten(client, result);`.
pub fn handleWritten(client: *common.AttachedClient, result: anyerror!void) !void {
    core.mark(client.io, .host_flush_done);
    const output = if (TerminalClient.of(client).output) |*output| output else unreachable;
    const token = output.delivery;
    const completed = output.complete(result) catch |err| {
        if (token) |value| {
            _ = TerminalClient.of(client).presenter.presentation_state.complete(value, .failed);
        }
        return err;
    };
    if (completed) |delivery| {
        try deliver(client, delivery);
    }

    if (output.draw_deferred) {
        output.draw_deferred = false;
        try TerminalClient.of(client).presenter.requestDraw();
    }
    if (output.media_deferred) {
        output.media_deferred = false;
        try TerminalClient.of(client).presenter.requestMedia();
    }

    try pumpOutput(client);
}
