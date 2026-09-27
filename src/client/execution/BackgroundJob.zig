//! Work the shared client asks its adapter to run off the event loop that
//! carries its own copy of the request: bar commands, plugin actions, path
//! completion, links, sounds, system notices, the configuration watch and
//! connecting to the runtime.
//! The copies are kilobytes, so these jobs queue apart from the interactive
//! `Job`s and a runtime read never moves them. Every job completes as one
//! `Message`; `job_runner.runBackground` executes it.
const core = @import("telar-core");
const data = @import("model");
const BarUpdatesJob = @import("../bars/BarUpdatesJob.zig");
const PluginActionsJob = @import("../plugins/PluginActionsJob.zig");
const PathCompletionJob = @import("../completion/PathCompletionJob.zig");
const WaitArgs = @import("../resources/WaitArgs.zig");
const RuntimeConnectJob = @import("../connection/RuntimeConnectJob.zig");

pub const BackgroundJob = union(enum) {
    bar_command: BarUpdatesJob,
    plugin: PluginActionsJob,
    path_completion: PathCompletionJob,
    link: data.LinkTarget,
    sound: core.AgentSound,
    system_notification: data.NotificationPayload,
    /// Waits for the configuration file to change and loads it.
    config_watch: WaitArgs,
    /// Connects to the client's machine, starting or reaching its runtime.
    runtime_connect: RuntimeConnectJob,
};
