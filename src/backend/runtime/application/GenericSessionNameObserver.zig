const std = @import("std");
const session_name_ops = @import("session_name.zig");
const readers = @import("../../agent/session_readers/session_readers.zig");
const JobType = @import("../../agent/session_readers/Job.zig");
const CompletionType = @import("../../agent/Completion.zig");

/// Binds probing to one model type providing `io`, `select`,
/// `model.agents`, `session_name_probe_in_flight` and `noteSessionChange`.
pub fn Type(comptime RuntimeModel: type) type {
    return struct {
        /// Starts one probe for the stalest due session file, if any.
        ///
        /// ```zig
        /// SessionNameObserver.tick(&model);
        /// ```
        pub fn tick(model: *RuntimeModel) void {
            if (model.session_name_probe_in_flight) {
                return;
            }

            const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();
            const watch = model.agents.nextSessionFileProbe(now_ms, session_name_ops.probe_interval_ms) orelse return;

            model.session_name_probe_in_flight = true;
            model.select.concurrent(.session_name, readers.probe, .{JobType{ .io = model.io, .watch = watch }}) catch {
                model.session_name_probe_in_flight = false;
                _ = model.agents.finishSessionFileProbe(.{ .key = watch.key, .offset = watch.offset }, now_ms);
            };
        }

        /// Applies one probe result and publishes a changed title.
        ///
        /// ```zig
        /// SessionNameObserver.handleCompletion(&model, completion);
        /// ```
        pub fn handleCompletion(model: *RuntimeModel, completion: CompletionType) void {
            model.session_name_probe_in_flight = false;
            const now_ms = std.Io.Timestamp.now(model.io, .real).toMilliseconds();

            if (model.agents.finishSessionFileProbe(completion, now_ms)) {
                model.noteSessionChange();
            }
        }
    };
}
