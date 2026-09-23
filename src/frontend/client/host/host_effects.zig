//! Delivers the host requests the shared client left in `model.to_host`.

const client_module = @import("telar-client");
const data = @import("model");
const std = @import("std");
const TerminalAdapter = @import("../TerminalAdapter.zig");
const kitty_delivery = @import("../../graphics/kitty_delivery.zig");
const capture_module = @import("../../attachments/capture.zig");
const term = @import("../../presentation/screen_support.zig");
const host_inputs = @import("../input/host_inputs.zig");

/// Drains every pending host request after one event, then starts the
/// runtime write and every job the event left. A job that fails to start can
/// leave new host requests, so both drain until the host queue is empty.
/// Example: `try host_effects.deliver(terminal);`
pub fn deliver(terminal: *TerminalAdapter) !void {
    const client = &terminal.app;

    while (true) {
        try deliverRequests(terminal);
        try startJobs(terminal);
        if (client.model.to_host.count == 0) {
            return;
        }
    }
}

fn deliverRequests(terminal: *TerminalAdapter) !void {
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
                try client_module.clipboard_capture.completeClipboardCapture(client, .{
                    .execution_id = @enumFromInt(request.sequence),
                    .result = err,
                });
            },
        }
    }
}

/// Starts each queued job as an inbox producer; one the inbox rejects
/// finishes as a failure, which may queue its successor.
fn startJobs(terminal: *TerminalAdapter) !void {
    const client = &terminal.app;

    try client.flush();
    while (client.to_workers.pop()) |job| {
        terminal.inbox.start(.client, .{ client_module.job_runner.run, .{ client.io, client.gpa, job } }) catch |err| {
            try client.failJob(job, err);
            try client.flush();
        };
    }
}

fn startCapture(terminal: *TerminalAdapter, request: data.CaptureRequest) !void {
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
