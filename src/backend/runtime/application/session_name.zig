//! Schedules session-file reads and applies generation-matched title results.
const std = @import("std");
const readers = @import("../../agent/root.zig").session_readers;
const Io = std.Io;
pub const probe_interval_ms: i64 = 1_000;
pub const Completion = readers.Completion;

/// Binds probing to one application type providing `io`, `select`,
/// `model.agents`, `session_name_probe_in_flight`, `noteSessionChange` and
/// `pumpAll`.
pub fn Observer(comptime Application: type) type {
    return struct {
        /// Starts one probe for the stalest due session file, if any.
        ///
        /// ```zig
        /// SessionNameObserver.tick(&application);
        /// ```
        pub fn tick(application: *Application) void {
            if (application.session_name_probe_in_flight) {
                return;
            }

            const now_ms = Io.Timestamp.now(application.io, .real).toMilliseconds();
            const watch = application.model.agents.nextSessionFileProbe(now_ms, probe_interval_ms) orelse return;

            application.session_name_probe_in_flight = true;
            application.select.concurrent(.session_name, readers.probe, .{readers.Job{ .io = application.io, .watch = watch }}) catch {
                application.session_name_probe_in_flight = false;
                _ = application.model.agents.finishSessionFileProbe(.{ .key = watch.key, .offset = watch.offset }, now_ms);
            };
        }

        /// Applies one probe result and publishes a changed title.
        ///
        /// ```zig
        /// SessionNameObserver.handleCompletion(&application, completion);
        /// ```
        pub fn handleCompletion(application: *Application, completion: Completion) void {
            application.session_name_probe_in_flight = false;
            const now_ms = Io.Timestamp.now(application.io, .real).toMilliseconds();

            if (application.model.agents.finishSessionFileProbe(completion, now_ms)) {
                application.noteSessionChange();
                application.pumpAll();
            }
        }
    };
}
