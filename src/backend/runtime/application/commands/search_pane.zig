//! Application query for copy-mode text search over one attached pane.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

pub const schema = core.schema;
pub const AttachmentStore = attachment_mod.AttachmentStore;

pub const SearchPane = @import("SearchPane.zig");

pub const Matches = @import("Matches.zig");

pub const SearchPaneResult = union(enum) {
    found: Matches,
    pane_not_attached,
};

pub const SearchPaneHandler = @import("SearchPaneHandler.zig");
