const core = @import("telar-core");
const pane_mod = @import("../../../../pane/pane_namespace.zig");
const InputCompletion = @import("../../../entrypoints/events/pane/InputCompletion.zig");
const ResponseCompletion = @import("../../../entrypoints/events/pane/ResponseCompletion.zig");
const PaneType = @import("../../../../pane/Pane.zig");
const InputWrite = @import("../../../entrypoints/events/pane/InputWrite.zig");
const ResponseWrite = @import("../../../entrypoints/events/pane/ResponseWrite.zig");

const RuntimeModel = @import("../../../RuntimeModel.zig");

/// Releases one completed user-input write and starts the next queued
/// write for that pane when one exists.
///
/// ```zig
/// try PaneIoEvents.handleInputWritten(&model, event);
/// ```
pub fn handleInputWritten(model: *RuntimeModel, completion: InputCompletion) !void {
    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    const result: pane_mod.PtyWriteResult = if (completion.result) |_| .succeeded else |_| .failed;

    pane.completePtyInputWrite(result);

    if (comptime core.enabled) {
        model.metrics.input_write.observe(
            core.elapsed(completion.started_ns, core.now(model.io)),
        );
    }

    if (result == .succeeded) {
        try scheduleInput(model, pane);
    }
}

/// Releases one completed runtime-response write and starts the next
/// queued response for that pane when one exists.
///
/// ```zig
/// try PaneIoEvents.handleResponseWritten(&model, event);
/// ```
pub fn handleResponseWritten(model: *RuntimeModel, completion: ResponseCompletion) !void {
    const pane = model.panes.resolve(completion.pane) orelse {
        model.metrics.stale_pane_events += 1;
        return;
    };

    const result: pane_mod.PtyWriteResult = if (completion.result) |_| .succeeded else |_| .failed;

    pane.completePtyResponseWrite(result);

    if (result == .succeeded) {
        try scheduleResponse(model, pane);
    }
}

/// Starts the pane's next queued user-input write when no input write is
/// already in flight.
///
/// ```zig
/// try PaneIoEvents.scheduleInput(&model, pane);
/// ```
pub fn scheduleInput(model: *RuntimeModel, pane: *PaneType) !void {
    const bytes = pane.beginPtyInputWrite() orelse return;
    const write: InputWrite = .{
        .io = model.io,
        .pane = pane,
        .bytes = bytes,
        .started_ns = if (comptime core.enabled) core.now(model.io) else 0,
    };

    startPaneInputWrite(model, write) catch |err| {
        pane.cancelPtyInputWrite();
        return err;
    };
}

/// Starts the pane's next queued runtime-response write when no response
/// write is already in flight.
///
/// ```zig
/// try PaneIoEvents.scheduleResponse(&model, pane);
/// ```
pub fn scheduleResponse(model: *RuntimeModel, pane: *PaneType) !void {
    const bytes = pane.beginPtyResponseWrite() orelse return;
    const write: ResponseWrite = .{
        .io = model.io,
        .pane = pane,
        .bytes = bytes,
    };

    startPaneResponseWrite(model, write) catch |err| {
        pane.cancelPtyResponseWrite();
        return err;
    };
}

fn startPaneInputWrite(model: *RuntimeModel, write: InputWrite) !void {
    core.mark(model.io, .pty_write_queued);
    try model.select.concurrent(.pane_input_written, writePaneInput, .{write});
}

fn writePaneInput(write: InputWrite) InputCompletion {
    core.mark(write.io, .pty_write_start);
    defer core.mark(write.io, .pty_write_done);
    const path = core.enter(.interactive);
    defer path.restore();

    write.pane.pty_write_mutex.lockUncancelable(write.io);
    defer write.pane.pty_write_mutex.unlock(write.io);

    return .{
        .pane = write.pane.key(),
        .started_ns = write.started_ns,
        .result = write.pane.session.writeAll(write.io, write.bytes),
    };
}

fn startPaneResponseWrite(model: *RuntimeModel, write: ResponseWrite) !void {
    try model.select.concurrent(.pane_response_written, writePaneResponse, .{write});
}

fn writePaneResponse(write: ResponseWrite) ResponseCompletion {
    const path = core.enter(.interactive);
    defer path.restore();

    write.pane.pty_write_mutex.lockUncancelable(write.io);
    defer write.pane.pty_write_mutex.unlock(write.io);

    return .{
        .pane = write.pane.key(),
        .result = write.pane.session.writeAll(write.io, write.bytes),
    };
}
