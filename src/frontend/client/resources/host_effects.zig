//! Delivers the host requests the shared client left in `model.to_host`.

const client_module = @import("telar-client");
const data = @import("model");
const std = @import("std");
const TerminalClient = @import("../TerminalClient.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const capture_module = @import("../../attachments/capture.zig");
const term = @import("../../presentation/screen_support.zig");

/// Drains every pending request after one event.
/// Example: `try host_effects.deliver(client);`
pub fn deliver(client: *client_module.AttachedClient) !void {
    const terminal = TerminalClient.of(client);
    const effects = &client.model.to_host;

    if (effects.takePlacementInvalidation()) {
        kitty_delivery.invalidatePlacements(&terminal.graphics_store);
    }

    // Terminal frames are paced as a whole, not per pane.
    effects.pane_input = null;

    while (effects.pop()) |effect| {
        switch (effect) {
            .clipboard => {
                try term.writeClipboard(terminal.writer, effects.clipboard.items);
                try terminal.writer.flush();
            },
            .terminal_notification => |payload| {
                try term.writeHostNotification(terminal.writer, payload.titleSlice(), payload.messageSlice());
                try terminal.writer.flush();
            },
            .capture => |request| startCapture(client, request) catch |err| {
                try client.completeClipboardCapture(.{
                    .execution_id = @enumFromInt(request.sequence),
                    .result = err,
                });
            },
        }
    }
}

fn startCapture(client: *client_module.AttachedClient, request: data.CaptureRequest) !void {
    try TerminalClient.of(client).inbox.start(.clipboard_image, .{ capture, .{
        client.gpa,
        request,
        &client.model.clipboard.orphan,
    } });
}

fn capture(gpa: std.mem.Allocator, request: data.CaptureRequest, orphan: *?*data.Capture) client_module.operations.ClipboardImageCompletion {
    return .{
        .execution_id = @enumFromInt(request.sequence),
        .result = capture_module.captureClipboard(gpa, request, orphan),
    };
}
