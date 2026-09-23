//! Work the shared client asks its adapter to run off the event loop. Every
//! job completes as one `Message`; `workers.run` executes it.
const core = @import("telar-core");
const data = @import("model");
const RuntimeTransportState = @import("../connection/RuntimeTransportState.zig");
const BarUpdatesJob = @import("../bars/BarUpdatesJob.zig");
const PluginActionsJob = @import("../plugins/PluginActionsJob.zig");
const PathCompletionJob = @import("../completion/PathCompletionJob.zig");

pub const Job = union(enum) {
    runtime_read: *RuntimeTransportState,
    runtime_send: RuntimeSend,
    /// Waits for a client deadline; the timer names the completion.
    timer: Timer,
    bar_command: BarUpdatesJob,
    plugin: PluginActionsJob,
    path_completion: PathCompletionJob,
    link: data.LinkTarget,
    sound: core.AgentSound,
    system_notification: data.NotificationPayload,

    pub const RuntimeSend = struct {
        state: *RuntimeTransportState,
        /// Owned by `state` until the send completes.
        bytes: []const u8,
    };

    pub const Timer = struct {
        kind: Kind,
        scheduler: *core.DeadlineScheduler,
    };

    pub const Kind = enum {
        bar,
        notification,
        sidebar_animation,
    };
};
