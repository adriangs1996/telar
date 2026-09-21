//! Runtime graphics operations, reached from requests.dispatch.

const RequestGraphicsSnapshot = @import("../commands/RequestGraphicsSnapshot.zig");
const request_graphics_snapshot = @import("../commands/request_graphics_snapshot.zig");
const ReturnGraphicsCredit = @import("../commands/ReturnGraphicsCredit.zig");
const graphics_credit = @import("../commands/graphics_credit.zig");
const ConfigureGraphics = @import("../commands/ConfigureGraphics.zig");
const graphics_configuration = @import("../commands/graphics_configuration.zig");
const RequestGraphicsSnapshotType = @import("telar-core").RequestGraphicsSnapshot;
const GraphicsCreditType = @import("telar-core").GraphicsCredit;
const ConfigureGraphicsType = @import("telar-core").ConfigureGraphics;
const TerminalColors = @import("telar-core").TerminalColors;
const RequestContext = @import("../RequestContext.zig");

/// Example: `try graphics.routeRequestGraphicsSnapshot(request, wire);`.
pub fn routeRequestGraphicsSnapshot(request: *RequestContext, wire: RequestGraphicsSnapshotType) !void {
    const result = try requestGraphicsSnapshot(request, .{ .pane_id = wire.pane_id });

    if (result == .pane_not_attached) {
        request.application.metrics.stale_client_messages += 1;
    }
}

/// Example: `try graphics.routeGraphicsCredit(request, credit);`.
pub fn routeGraphicsCredit(request: *RequestContext, credit: GraphicsCreditType) !void {
    const result = try graphicsCredit(request, .{
        .pane_id = credit.pane_id,
        .bytes = credit.bytes,
    });

    if (result != .returned) {
        request.application.metrics.stale_client_messages += 1;
    }
}

/// Example: `try graphics.routeConfigureGraphics(request, configure);`.
pub fn routeConfigureGraphics(request: *RequestContext, configure: ConfigureGraphicsType) !void {
    _ = try configureGraphics(request, .{ .shared = configure.shared });
}

/// Example: `try graphics.routeConfigureTerminalColors(request, colors);`.
pub fn routeConfigureTerminalColors(request: *RequestContext, colors: TerminalColors) !void {
    if (request.session.setTerminalColors(colors)) {
        request.application.refreshTerminalColors(request.session.key);
    }
}

fn requestGraphicsSnapshot(request: *RequestContext, command: RequestGraphicsSnapshot) anyerror!request_graphics_snapshot.RequestGraphicsSnapshotResult {
    if (!request.session.attachments.requestGraphicsSnapshot(command.pane_id)) {
        return .pane_not_attached;
    }

    return .requested;
}

fn graphicsCredit(request: *RequestContext, command: ReturnGraphicsCredit) anyerror!graphics_credit.ReturnGraphicsCreditResult {
    return switch (request.session.attachments.returnGraphicsCredit(.{
        .pane_id = command.pane_id,
        .bytes = command.bytes,
    })) {
        .returned => .returned,
        .pane_not_attached => .pane_not_attached,
        .invalid_amount => .invalid_amount,
    };
}

fn configureGraphics(request: *RequestContext, command: ConfigureGraphics) anyerror!graphics_configuration.ConfigureGraphicsResult {
    return switch (request.session.attachments.configureGraphics(command.shared)) {
        .changed => .changed,
        .unchanged => .unchanged,
    };
}
