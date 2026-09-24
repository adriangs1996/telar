//! Git branch and cleanliness of a working tree, read without libgit.

pub const Status = @import("Status.zig");
pub const probe = @import("probe.zig");

test {
    _ = @import("Status.zig");
    _ = @import("probe.zig");
}
