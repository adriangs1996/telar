const PaneRetirement = @import("../state/PaneRetirement.zig");
const StalePaneExit = @import("../state/StalePaneExit.zig");

pub const PaneExit = union(enum) {
    retired: PaneRetirement,
    stale: StalePaneExit,
};
