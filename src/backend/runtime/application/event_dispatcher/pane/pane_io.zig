const enabled_module = @import("telar-core").enabled;
const now_module = @import("telar-core").now;
const pane_mod = @import("../../../../pane/pane_namespace.zig");
const elapsed_module = @import("telar-core").elapsed;
const InputCompletion = @import("../../../entrypoints/events/pane/InputCompletion.zig");
const ResponseCompletion = @import("../../../entrypoints/events/pane/ResponseCompletion.zig");
const PaneType = @import("../../../../pane/Pane.zig");
const InputWrite = @import("../../../entrypoints/events/pane/InputWrite.zig");
const mark_module = @import("telar-core").mark;
const enter_module = @import("telar-core").enter;
const ResponseWrite = @import("../../../entrypoints/events/pane/ResponseWrite.zig");

const Application = @import("../../Application.zig");

/// Releases one completed user-input write and starts the next queued
/// write for that pane when one exists.
///
/// ```zig
/// try PaneIoEvents.handleInputWritten(&application, event);
/// ```
pub fn handleInputWritten(application: *Application, completion: InputCompletion) !void {
    const pane = application.model.panes.resolve(completion.pane) orelse {
        application.metrics.stale_pane_events += 1;
        return;
    };

    const result: pane_mod.PtyWriteResult = if (completion.result) |_| .succeeded else |_| .failed;

    pane.completePtyInputWrite(result);

    if (comptime enabled_module) {
        application.metrics.input_write.observe(
            elapsed_module(completion.started_ns, now_module(application.io)),
        );
    }

    if (result == .succeeded) {
        try scheduleInput(application, pane);
    }

    application.collect();
}

/// Releases one completed runtime-response write and starts the next
/// queued response for that pane when one exists.
///
/// ```zig
/// try PaneIoEvents.handleResponseWritten(&application, event);
/// ```
pub fn handleResponseWritten(application: *Application, completion: ResponseCompletion) !void {
    const pane = application.model.panes.resolve(completion.pane) orelse {
        application.metrics.stale_pane_events += 1;
        return;
    };

    const result: pane_mod.PtyWriteResult = if (completion.result) |_| .succeeded else |_| .failed;

    pane.completePtyResponseWrite(result);

    if (result == .succeeded) {
        try scheduleResponse(application, pane);
    }

    application.collect();
}

/// Starts the pane's next queued user-input write when no input write is
/// already in flight.
///
/// ```zig
/// try PaneIoEvents.scheduleInput(&application, pane);
/// ```
pub fn scheduleInput(application: *Application, pane: *PaneType) !void {
    const bytes = pane.beginPtyInputWrite() orelse return;
    const write: InputWrite = .{
        .io = application.io,
        .pane = pane,
        .bytes = bytes,
        .started_ns = if (comptime enabled_module) now_module(application.io) else 0,
    };

    startPaneInputWrite(application, write) catch |err| {
        pane.cancelPtyInputWrite();
        return err;
    };
}

/// Starts the pane's next queued runtime-response write when no response
/// write is already in flight.
///
/// ```zig
/// try PaneIoEvents.scheduleResponse(&application, pane);
/// ```
pub fn scheduleResponse(application: *Application, pane: *PaneType) !void {
    const bytes = pane.beginPtyResponseWrite() orelse return;
    const write: ResponseWrite = .{
        .io = application.io,
        .pane = pane,
        .bytes = bytes,
    };

    startPaneResponseWrite(application, write) catch |err| {
        pane.cancelPtyResponseWrite();
        return err;
    };
}

fn startPaneInputWrite(application: *Application, write: InputWrite) !void {
    mark_module(application.io, .pty_write_queued);
    try application.select.concurrent(.pane_input_written, writePaneInput, .{write});
}

fn writePaneInput(write: InputWrite) InputCompletion {
    mark_module(write.io, .pty_write_start);
    defer mark_module(write.io, .pty_write_done);
    const path = enter_module(.interactive);
    defer path.restore();

    write.pane.pty_write_mutex.lockUncancelable(write.io);
    defer write.pane.pty_write_mutex.unlock(write.io);

    return .{
        .pane = write.pane.key(),
        .started_ns = write.started_ns,
        .result = write.pane.session.writeAll(write.io, write.bytes),
    };
}

fn startPaneResponseWrite(application: *Application, write: ResponseWrite) !void {
    try application.select.concurrent(.pane_response_written, writePaneResponse, .{write});
}

fn writePaneResponse(write: ResponseWrite) ResponseCompletion {
    const path = enter_module(.interactive);
    defer path.restore();

    write.pane.pty_write_mutex.lockUncancelable(write.io);
    defer write.pane.pty_write_mutex.unlock(write.io);

    return .{
        .pane = write.pane.key(),
        .result = write.pane.session.writeAll(write.io, write.bytes),
    };
}
