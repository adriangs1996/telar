//! Application policy for one configured bar-source result.

const data = @import("model");
const BarUpdateFailure = @import("BarUpdateFailure.zig");

pub const Result = union(enum) {
    content: data.Content,
    failed: BarUpdateFailure,
};

pub const Outcome = union(enum) {
    updated: data.BarUpdateCommit,
    unchanged,
    stale,
    failed: anyerror,
};
