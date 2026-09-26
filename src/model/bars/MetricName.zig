//! Host metrics a bar can show without a Lua callback.
pub const MetricName = enum(u2) {
    cpu,
    memory,
    battery,
};
