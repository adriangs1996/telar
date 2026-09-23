//! Delivers the host requests the shared client left in `model.to_host`.

const client_module = @import("telar-client");
const data = @import("model");
const std = @import("std");
const TerminalClient = @import("../TerminalClient.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const capture_module = @import("../../attachments/capture.zig");
const term = @import("../../presentation/screen_support.zig");
const host_inputs = @import("../controllers/input/host_inputs.zig");

/// Drains every pending request after one event.
/// Example: `try host_effects.deliver(terminal);`
pub fn deliver(terminal: *TerminalClient) !void {
    const client = &terminal.app;

    const effects = &client.model.to_host;

    if (effects.takePlacementInvalidation()) {
        kitty_delivery.invalidatePlacements(&terminal.graphics_store);
    }

    // Terminal frames are paced as a whole, not per pane.
    effects.pane_input = null;
    if (effects.rebind_input) {
        effects.rebind_input = false;
        // A router the new bindings cannot compile keeps the previous one;
        // reload validation already rejects such bindings.
        if (host_inputs.buildRouter(client.routerConfig())) |router| {
            terminal.host_input.replaceRouter(client.io, router);
        } else |_| {}
    }

    if (effects.resume_input) {
        effects.resume_input = false;
        try host_inputs.scheduleRead(terminal);
    }

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
            .capture => |request| startCapture(terminal, request) catch |err| {
                try client.completeClipboardCapture(.{
                    .execution_id = @enumFromInt(request.sequence),
                    .result = err,
                });
            },
        }
    }
}

fn startCapture(terminal: *TerminalClient, request: data.CaptureRequest) !void {
    const client = &terminal.app;

    try terminal.inbox.start(.clipboard_image, .{ capture, .{
        client.gpa,
        request,
        &client.model.clipboard.orphan,
    } });
}

fn capture(gpa: std.mem.Allocator, request: data.CaptureRequest, orphan: *?*data.Capture) data.Completion {
    return .{
        .execution_id = @enumFromInt(request.sequence),
        .result = capture_module.captureClipboard(gpa, request, orphan),
    };
}
