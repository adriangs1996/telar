//! Owned provider session-file work, independent of runtime scheduling.
const std = @import("std");
const session_file = @import("../session_file.zig");
pub const Completion = session_file.Completion;
pub const Job = @import("Job.zig");
