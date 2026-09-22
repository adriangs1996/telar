const ConfigurationCommitType = @import("../state/ConfigurationCommit.zig");

pub const ConfigReloadOutcome = union(enum) {
    unchanged,
    rejected,
    adopted: ConfigurationCommitType,
};
