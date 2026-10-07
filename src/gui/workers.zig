//! Starts every machine's client jobs as producers of the native inbox,
//! outside native callbacks. Each completion comes back tagged with the
//! slot of the client that queued it.
const client = @import("telar-client");
const MachineMessage = @import("MachineMessage.zig");
const std = @import("std");

pub fn run(io: std.Io, slot: u8, job: client.Job) MachineMessage {
    return .{
        .slot = slot,
        .message = client.job_runner.run(io, job),
    };
}

pub fn runBackground(io: std.Io, gpa: std.mem.Allocator, slot: u8, job: client.BackgroundJob) MachineMessage {
    return .{
        .slot = slot,
        .message = client.job_runner.runBackground(io, gpa, job),
    };
}
