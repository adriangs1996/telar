//! Schedules bounded Git observation through the workspace reservation protocol.

const std = @import("std");
const worker = @import("../resources/root.zig").git_probe;
pub const Io = std.Io;
pub const Completion = worker.Completion;
pub const probe_interval_ms = worker.probe_interval_ms;

pub const Observer = @import("GenericGitStatusObserver.zig").Type;
