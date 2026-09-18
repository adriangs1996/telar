pub const Failure = enum { invalid, unsupported, limit, unavailable, timeout };

pub const View = union(enum) {
    pending,
    failed: Failure,
    ready: @import("Ready.zig"),
};
