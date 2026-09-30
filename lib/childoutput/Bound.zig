/// How much of one stream a read keeps.
pub const Bound = union(enum) {
    /// More than this many bytes fails the whole read.
    fail_past: usize,
    /// Keeps the newest this-many bytes; older ones are dropped and counted.
    keep_tail: usize,
};
