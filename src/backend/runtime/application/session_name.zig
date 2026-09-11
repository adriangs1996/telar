//! Schedules session-file reads and applies generation-matched title results.
const std = @import("std");
const readers = @import("../../agent/root.zig").session_readers;
pub const Io = std.Io;
pub const probe_interval_ms: i64 = 1_000;
pub const Completion = readers.Completion;

pub const Observer = @import("GenericSessionNameObserver.zig").Type;
