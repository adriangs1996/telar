//! The wire filters one history palette query means, resolved from the
//! typed text and the prompt's chips.
const core = @import("telar-core");
const HistoryFilters = @This();

/// The search text without its `!` prefix.
query: []const u8,
author: core.HistoryAuthorFilter,
failed_only: bool,
