//! Bounded latest-wins state for host link-opening workers.

const data = @import("../model.zig");

pub const Request = union(enum) {
    start: data.LinkTarget,
    queued,
};
