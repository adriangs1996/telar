//! Presentation event adaptation for one disposable client. The presenter
//! decides when and what to paint. This adapter releases async tokens and
//! supplies concrete effects to the application delivery policy.
const view_chrome = @import("view_chrome.zig");
const core = @import("telar-core");
const common = @import("telar-client");

const TerminalAdapter = @import("../TerminalAdapter.zig");
const presentation_projection = @import("presentation_projection.zig");
const Output = @import("../host/Output.zig");

/// Publishes every revision the presenter uses after one client event commits.
///
/// ```zig
/// try presentation_lifecycle.observe(terminal);
/// ```
pub fn observe(terminal: *TerminalAdapter) !void {
    try view_chrome.refresh(terminal);
    try terminal.presenter.observe(presentation_projection.observation(terminal));
}

/// Completes one paced draw. Damage is retired only after the host terminal
/// flush succeeds; cell acknowledgements already followed frame application.
///
/// ```zig
/// try presentation_lifecycle.handleDraw(terminal, result);
/// ```
pub fn handleDraw(terminal: *TerminalAdapter, result: anyerror!void) !void {
    try terminal.presenter.completeDraw(result);
    try presentNow(terminal);
}

/// Presents whatever is pending on the caller's thread without touching the
/// paced draw token, so both the `.draw` completion and an immediate
/// presentation share one delivery path.
///
/// ```zig
/// try presentation_lifecycle.presentNow(terminal);
/// ```
pub fn presentNow(terminal: *TerminalAdapter) !void {
    const client = &terminal.app;

    // An event earlier in this inbox turn may have changed the model after
    // the last observation; the turn's closing observation asks for the
    // draw that presents it.
    const projection = presentation_projection.projection(terminal);
    if (!terminal.presenter.hasObserved(projection)) {
        return;
    }

    core.mark(client.io, .compose_start);
    if (terminal.output) |*output| {
        if (output.pending) {
            output.draw_deferred = true;
            return;
        }

        try output.prepareFrame(@as(usize, terminal.presenter.screen.back.w) * terminal.presenter.screen.back.h);
    }

    const delivery = try terminal.presenter.presentDue(
        projection,
        presentation_projection.resources(terminal),
    ) orelse return;
    errdefer _ = terminal.presenter.presentation_state.complete(delivery, .failed);

    if (terminal.output) |*output| {
        if (output.writer.end != 0) {
            output.delivery = delivery;
            try pumpOutput(terminal);
            return;
        }
    }

    try deliver(terminal, delivery);
}

fn deliver(terminal: *TerminalAdapter, token: common.Token) !void {
    const client = &terminal.app;

    const delivery = terminal.presenter.presentation_state.complete(token, .delivered) orelse return;
    const geometry = client.presentation.delivered_geometry;
    terminal.view.tab_drag.present(&terminal.view.hits, if (geometry) |value| if (value.location) |location| location.workspace else null else null);
    try common.presentation_delivery.apply(&client.model, delivery.commit);
    if (delivery.media_pending) {
        try terminal.presenter.requestMedia();
    }
}

/// Completes one lower-priority, byte-bounded host graphics pass.
///
/// ```zig
/// try presentation_lifecycle.handleMediaTick(terminal, result);
/// ```
pub fn handleMediaTick(terminal: *TerminalAdapter, result: anyerror!void) !void {
    try terminal.presenter.completeMediaTick(result);
    if (terminal.output) |*output| {
        if (output.pending) {
            output.media_deferred = true;
            return;
        }

        try output.prepareFrame(@as(usize, terminal.presenter.screen.back.w) * terminal.presenter.screen.back.h);
    }

    try terminal.presenter.presentMedia(
        presentation_projection.projection(terminal),
        presentation_projection.resources(terminal),
    );
}

/// Starts one host write without lending model or presentation state.
/// Example: `try pumpOutput(terminal);`.
pub fn pumpOutput(terminal: *TerminalAdapter) anyerror!void {
    const client = &terminal.app;

    const output = if (terminal.output) |*output| output else return;
    const pending = output.begin() orelse return;
    core.mark(client.io, .host_flush_start);
    const work = try output.tryWrite(pending);
    if (work.bytes.len == 0) {
        try handleWritten(terminal, {});
        return;
    }

    try terminal.inbox.start(.host_written, .{ Output.write, .{work} });
}

/// Commits only the presentation whose bytes reached the host, then folds work.
/// Example: `try handleWritten(terminal, result);`.
pub fn handleWritten(terminal: *TerminalAdapter, result: anyerror!void) !void {
    const client = &terminal.app;

    core.mark(client.io, .host_flush_done);
    const output = if (terminal.output) |*output| output else unreachable;
    const token = output.delivery;
    const completed = output.complete(result) catch |err| {
        if (token) |value| {
            _ = terminal.presenter.presentation_state.complete(value, .failed);
        }
        return err;
    };
    if (completed) |delivery| {
        try deliver(terminal, delivery);
    }

    if (output.draw_deferred) {
        output.draw_deferred = false;
        try terminal.presenter.requestDraw();
    }
    if (output.media_deferred) {
        output.media_deferred = false;
        try terminal.presenter.requestMedia();
    }

    try pumpOutput(terminal);
}
