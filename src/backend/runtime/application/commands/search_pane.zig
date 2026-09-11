//! Application query for copy-mode text search over one attached pane.

const Matches = @import("Matches.zig");

pub const SearchPaneResult = union(enum) {
    found: Matches,
    pane_not_attached,
};
