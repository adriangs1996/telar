const InputCompletion = @import("../../../entrypoints/events/pane/InputCompletion.zig");
const ResponseCompletion = @import("../../../entrypoints/events/pane/ResponseCompletion.zig");
const PaneType = @import("../../../../pane/Pane.zig");
const GenericInputRuntimePort = @import("../../../entrypoints/events/pane/GenericInputRuntimePort.zig").Type;
const GenericInputPump = @import("../../../entrypoints/events/pane/GenericInputPump.zig").Type;
const InputWrite = @import("../../../entrypoints/events/pane/InputWrite.zig");
const mark_module = @import("telar-core").mark;
const enter_module = @import("telar-core").enter;
const GenericResponseRuntimePort = @import("../../../entrypoints/events/pane/GenericResponseRuntimePort.zig").Type;
const GenericResponsePump = @import("../../../entrypoints/events/pane/GenericResponsePump.zig").Type;
const ResponseWrite = @import("../../../entrypoints/events/pane/ResponseWrite.zig");

/// Binds pane input and response writes to one concrete Application type.
///
/// ```zig
/// const PaneIoEvents = Dispatcher(Application);
/// ```
pub fn Type(comptime Application: type) type {
    return struct {
        /// Releases one completed user-input write and starts the next queued
        /// write for that pane when one exists.
        ///
        /// ```zig
        /// try PaneIoEvents.handleInputWritten(&application, event);
        /// ```
        pub fn handleInputWritten(application: *Application, event: InputCompletion) !void {
            var input_pump = paneInputPump(application);
            try input_pump.complete(event);
        }

        /// Releases one completed runtime-response write and starts the next
        /// queued response for that pane when one exists.
        ///
        /// ```zig
        /// try PaneIoEvents.handleResponseWritten(&application, event);
        /// ```
        pub fn handleResponseWritten(application: *Application, event: ResponseCompletion) !void {
            var response_pump = paneResponsePump(application);
            try response_pump.complete(event);
        }

        /// Starts the pane's next queued user-input write when no input write is
        /// already in flight.
        ///
        /// ```zig
        /// try PaneIoEvents.scheduleInput(&application, pane);
        /// ```
        pub fn scheduleInput(application: *Application, pane: *PaneType) !void {
            var input_pump = paneInputPump(application);
            return input_pump.schedule(pane);
        }

        /// Starts the pane's next queued runtime-response write when no response
        /// write is already in flight.
        ///
        /// ```zig
        /// try PaneIoEvents.scheduleResponse(&application, pane);
        /// ```
        pub fn scheduleResponse(application: *Application, pane: *PaneType) !void {
            var response_pump = paneResponsePump(application);
            return response_pump.schedule(pane);
        }

        const pane_input_runtime_port: GenericInputRuntimePort(Application) = .{
            .start = startPaneInputWrite,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneInputPump = GenericInputPump(Application, pane_input_runtime_port);

        fn paneInputPump(application: *Application) RuntimePaneInputPump {
            return RuntimePaneInputPump.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
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

        const pane_response_runtime_port: GenericResponseRuntimePort(Application) = .{
            .start = startPaneResponseWrite,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneResponsePump = GenericResponsePump(Application, pane_response_runtime_port);

        fn paneResponsePump(application: *Application) RuntimePaneResponsePump {
            return RuntimePaneResponsePump.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
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

        fn collectPaneLifecycle(application: *Application) void {
            application.collect();
        }
    };
}
