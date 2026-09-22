const TabRemoval = @import("../state/TabRemoval.zig");
const StaleTabRemoval = @import("../state/StaleTabRemoval.zig");

pub const TabRemovalCommit = union(enum) {
    removed: TabRemoval,
    stale: StaleTabRemoval,
};
