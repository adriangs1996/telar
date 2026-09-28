//! Executes one client job on a worker thread and turns its result into the
//! client message the adapter delivers.
const pacing = @import("pacing");
const std = @import("std");
const core = @import("telar-core");
const Job = @import("Job.zig").Job;
const BackgroundJob = @import("BackgroundJob.zig").BackgroundJob;
const PluginActionsJob = @import("../plugins/PluginActionsJob.zig");
const Message = @import("Message.zig").Message;
const command = @import("../bars/command.zig");
const plugins = @import("../plugins/plugins.zig");
const path_completion = @import("../completion/path_completion.zig");
const host = @import("../links/host.zig");
const sound_playback = @import("../agents/sound_playback.zig");
const system_notification = @import("../notifications/system_notification.zig");
const config_reload = @import("../resources/config_reload.zig");
const runtime_link = @import("../connection/runtime_link.zig");
const machine_profiles = @import("../machines/machine_profiles.zig");

/// Runs `job` to completion. The adapter starts it as an inbox producer:
/// `try inbox.start(.client, .{ job_runner.run, .{ io, job } });`
pub fn run(io: std.Io, job: Job) Message {
    return switch (job) {
        .runtime_read => |state| .{ .server = state.read(io) },
        .runtime_send => |send| .{ .sent = sendRuntime(io, send) },
        .timer => |timer| switch (timer.kind) {
            .bar => .{ .bar_tick = pacing.deadline_timer.wait(io, timer.scheduler) },
            .notification => .{ .notification_tick = pacing.deadline_timer.wait(io, timer.scheduler) },
            .sidebar_animation => .{ .sidebar_animation_tick = pacing.deadline_timer.wait(io, timer.scheduler) },
            .runtime_retry => .{ .runtime_retry_tick = pacing.deadline_timer.wait(io, timer.scheduler) },
        },
        .telemetry_tick => .{ .telemetry_tick = core.waitForTick(io) },
        .telemetry_write => |telemetry| .{ .telemetry_written = telemetry.write(io) },
    };
}

/// Runs a background `job` to completion. The adapter starts it as an inbox
/// producer: `try inbox.start(.client, .{ job_runner.runBackground, .{ io, gpa, job } });`
pub fn runBackground(io: std.Io, gpa: std.mem.Allocator, job: BackgroundJob) Message {
    return switch (job) {
        .bar_command => |bar| .{ .bar_command = .{
            .execution_id = bar.execution_id,
            .result = command.run(io, bar.command),
        } },
        .plugin => |plugin| .{ .plugin_result = .{
            .execution_id = plugin.execution_id,
            .result = runPlugin(io, gpa, plugin),
        } },
        .path_completion => |completion| .{ .path_completion = .{
            .execution_id = completion.execution_id,
            .result = path_completion.run(io, gpa, completion),
        } },
        .link => |target| .{ .link_opened = host.open(io, target) },
        .sound => |kind| .{ .sound_played = sound_playback.play(io, kind) },
        .system_notification => |payload| .{ .notified = system_notification.post(io, payload) },
        .config_watch => |args| .{ .config_reload = config_reload.wait(args) },
        .runtime_connect => |connect| .{ .runtime_connected = runtime_link.runConnect(io, gpa, connect) },
        .machine_edit => |edit| .{ .machine_edited = machine_profiles.write(io, gpa, edit) },
    };
}

/// The completion of a job that never ran: its worker failed with `err`
/// before doing anything. The client handles it like any other failure, so
/// one completion path releases what starting the job reserved.
///
/// ```zig
/// _ = try client.update(job_runner.failed(job, error.InboxFull));
/// ```
pub fn failed(job: Job, err: anyerror) Message {
    return switch (job) {
        .runtime_read => .{ .server = err },
        .runtime_send => .{ .sent = err },
        .timer => |timer| switch (timer.kind) {
            .bar => .{ .bar_tick = err },
            .notification => .{ .notification_tick = err },
            .sidebar_animation => .{ .sidebar_animation_tick = err },
            .runtime_retry => .{ .runtime_retry_tick = err },
        },
        .telemetry_tick => .{ .telemetry_tick = err },
        .telemetry_write => .{ .telemetry_written = err },
    };
}

/// The completion of a background job that never ran, as `failed`.
///
/// ```zig
/// _ = try client.update(job_runner.failedBackground(job, error.InboxFull));
/// ```
pub fn failedBackground(job: BackgroundJob, err: anyerror) Message {
    return switch (job) {
        .bar_command => |bar| .{ .bar_command = .{
            .execution_id = bar.execution_id,
            .result = err,
        } },
        .plugin => |plugin| .{ .plugin_result = .{
            .execution_id = plugin.execution_id,
            .result = err,
        } },
        .path_completion => |completion| .{ .path_completion = .{
            .execution_id = completion.execution_id,
            .result = err,
        } },
        .link => .{ .link_opened = err },
        .sound => .{ .sound_played = err },
        .system_notification => .{ .notified = err },
        .config_watch => .{ .config_reload = err },
        .runtime_connect => .{ .runtime_connected = err },
        .machine_edit => .{ .machine_edited = err },
    };
}

fn runPlugin(io: std.Io, gpa: std.mem.Allocator, plugin: PluginActionsJob) anyerror!void {
    plugin.result.* = try plugins.executeWorker(io, gpa, plugin.request);
}

fn sendRuntime(io: std.Io, send: Job.RuntimeSend) anyerror!void {
    core.mark(io, .client_send_start);
    defer core.mark(io, .client_send_done);
    return send.state.send(io, send.bytes);
}
