const Id = @import("Id.zig");

pub const Owner = union(enum) {
    fallback,
    discarded,
    widget: Id,
};
