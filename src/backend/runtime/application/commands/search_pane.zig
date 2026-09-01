//! Application query for copy-mode text search over one attached pane.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

const schema = core.schema;
const AttachmentStore = attachment_mod.AttachmentStore;

pub const SearchPane = struct {
    pane_id: schema.PaneId,
    needle: []const u8,
};

pub const Matches = struct {
    items: [schema.max_search_matches]schema.SearchMatch = undefined,
    count: u8 = 0,
    truncated: bool = false,

    pub fn slice(matches: *const Matches) []const schema.SearchMatch {
        return matches.items[0..matches.count];
    }
};

pub const SearchPaneResult = union(enum) {
    found: Matches,
    pane_not_attached,
};

pub const SearchPaneHandler = struct {
    attachments: *AttachmentStore,

    /// Resolves attachment authority and runs the bounded search.
    ///
    /// ```zig
    /// const result = handler.execute(.{ .pane_id = pane_id, .needle = "error" });
    /// ```
    pub fn execute(handler: *SearchPaneHandler, command: SearchPane) SearchPaneResult {
        const attachment = handler.attachments.find(command.pane_id) orelse return .pane_not_attached;
        var matches: Matches = .{};
        const result = attachment.pane.searchText(command.needle, &matches.items);
        matches.count = result.count;
        matches.truncated = result.truncated;
        return .{ .found = matches };
    }
};
