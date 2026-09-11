const source_namespace = @import("io.zig");
const core = @import("telar-core");
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
        pub fn handleInputWritten(application: *Application, event: source_namespace.PaneInputEvent) !void {
            var input_pump = paneInputPump(application);
            try input_pump.complete(event);
        }

        /// Releases one completed runtime-response write and starts the next
        /// queued response for that pane when one exists.
        ///
        /// ```zig
        /// try PaneIoEvents.handleResponseWritten(&application, event);
        /// ```
        pub fn handleResponseWritten(application: *Application, event: source_namespace.PaneResponseEvent) !void {
            var response_pump = paneResponsePump(application);
            try response_pump.complete(event);
        }

        /// Starts the pane's next queued user-input write when no input write is
        /// already in flight.
        ///
        /// ```zig
        /// try PaneIoEvents.scheduleInput(&application, pane);
        /// ```
        pub fn scheduleInput(application: *Application, pane: *source_namespace.Pane) !void {
            var input_pump = paneInputPump(application);
            return input_pump.schedule(pane);
        }

        /// Starts the pane's next queued runtime-response write when no response
        /// write is already in flight.
        ///
        /// ```zig
        /// try PaneIoEvents.scheduleResponse(&application, pane);
        /// ```
        pub fn scheduleResponse(application: *Application, pane: *source_namespace.Pane) !void {
            var response_pump = paneResponsePump(application);
            return response_pump.schedule(pane);
        }

        const pane_input_runtime_port: source_namespace.pane_input_pump.RuntimePort(Application) = .{
            .start = startPaneInputWrite,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneInputPump = source_namespace.pane_input_pump.Pump(Application, pane_input_runtime_port);

        fn paneInputPump(application: *Application) RuntimePaneInputPump {
            return RuntimePaneInputPump.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn startPaneInputWrite(application: *Application, write: source_namespace.pane_input_pump.Write) !void {
            core.echo_trace.mark(application.io, .pty_write_queued);
            try application.select.concurrent(.pane_input_written, writePaneInput, .{write});
        }

        fn writePaneInput(write: source_namespace.pane_input_pump.Write) source_namespace.PaneInputEvent {
            core.echo_trace.mark(write.io, .pty_write_start);
            defer core.echo_trace.mark(write.io, .pty_write_done);
            const path = source_namespace.diagnostics.enter(.interactive);
            defer path.restore();

            write.pane.pty_write_mutex.lockUncancelable(write.io);
            defer write.pane.pty_write_mutex.unlock(write.io);

            return .{
                .pane = write.pane.key(),
                .started_ns = write.started_ns,
                .result = write.pane.session.writeAll(write.io, write.bytes),
            };
        }

        const pane_response_runtime_port: source_namespace.pane_response_pump.RuntimePort(Application) = .{
            .start = startPaneResponseWrite,
            .collect = collectPaneLifecycle,
        };

        const RuntimePaneResponsePump = source_namespace.pane_response_pump.Pump(Application, pane_response_runtime_port);

        fn paneResponsePump(application: *Application) RuntimePaneResponsePump {
            return RuntimePaneResponsePump.init(application, .{
                .io = application.io,
                .panes = &application.model.panes,
                .metrics = &application.metrics,
            });
        }

        fn startPaneResponseWrite(application: *Application, write: source_namespace.pane_response_pump.Write) !void {
            try application.select.concurrent(.pane_response_written, writePaneResponse, .{write});
        }

        fn writePaneResponse(write: source_namespace.pane_response_pump.Write) source_namespace.PaneResponseEvent {
            const path = source_namespace.diagnostics.enter(.interactive);
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
