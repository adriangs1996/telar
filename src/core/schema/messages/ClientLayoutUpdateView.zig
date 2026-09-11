const ClientLayoutUpdateView = @This();
const source_namespace = @import("layout.zig");
const ClientTabLayoutIterator = @import("ClientTabLayoutIterator.zig");
sidebar_visible: bool,
sidebar_width: u16,
workspace_list_collapsed: bool,
active_tab: source_namespace.TabLocation,
tab_count: u16,
encoded_tabs: []const u8,

/// Iterates the validated layouts retained by this client update.
///
/// ```zig
/// var tabs = update.tabs();
/// while (try tabs.next()) |tab| use(tab);
/// ```
pub fn tabs(update: ClientLayoutUpdateView) ClientTabLayoutIterator {
    return .{ .decoder = .init(update.encoded_tabs), .remaining = update.tab_count };
}
