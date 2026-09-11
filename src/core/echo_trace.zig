//! Opt-in fixed-capacity traces. The process bootstrap owns the recorder.
const std = @import("std");
const root = @import("root");

pub const enabled = @hasDecl(root, "telar_echo_trace") and root.telar_echo_trace;
pub const cpu_enabled = enabled and @hasDecl(root, "telar_echo_trace_cpu") and root.telar_echo_trace_cpu;
threadlocal var thread_id: ?std.Thread.Id = null;
pub const Tag = enum {
    host_read,
    client_input,
    client_send_start,
    client_send_done,
    runtime_read,
    runtime_dispatch,
    input_forward,
    foreground_start,
    foreground_done,
    input_observed,
    pty_write_queued,
    pty_write_start,
    pty_write_done,
    pty_read,
    output_dispatch,
    vt_queued,
    vt_start,
    vt_done,
    ingest_dispatch,
    runtime_send_start,
    runtime_send_done,
    client_read,
    client_frame,
    compose_start,
    host_flush_start,
    host_flush_done,
};

pub const Recorder = @import("Recorder.zig");

/// Compiles away without `-Decho-trace`; records no contents, pane or request IDs.
/// Example: `echo_trace.mark(io, .pty_read);`.
pub fn mark(io: std.Io, tag: Tag) void {
    if (comptime enabled) {
        if (comptime cpu_enabled) {
            if (thread_id == null) {
                thread_id = std.Thread.getCurrentId();
            }
        }

        root.echo_recorder.append(.{
            .ns = @intCast(std.Io.Clock.awake.now(io).nanoseconds),
            .tag = tag,
            .cpu_ns = if (cpu_enabled) @intCast(std.Io.Clock.cpu_thread.now(io).nanoseconds) else {},
            .thread = if (cpu_enabled) thread_id.? else {},
        });
    }
}

test "trace saturation does not overwrite retained records" {
    const recorder = try std.testing.allocator.create(Recorder);
    defer std.testing.allocator.destroy(recorder);
    recorder.* = .{};

    for (0..Recorder.capacity + 10) |index| {
        recorder.append(.{ .ns = index, .tag = .host_read });
    }

    try std.testing.expectEqual(@as(u64, 0), recorder.records[0].ns);
    try std.testing.expectEqual(@as(u64, Recorder.capacity - 1), recorder.records[Recorder.capacity - 1].ns);
}
