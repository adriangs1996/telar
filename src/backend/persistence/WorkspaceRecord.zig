const WorkspaceRecord = @This();

id: u64,
path: []const u8,
/// Explicit user name, empty when the workspace derives its name.
name: []const u8,
/// The first tab, which every workspace owns from creation. Further tabs
/// follow as `TabRecord`s in display order.
first_tab_id: u64,
first_tab_label: []const u8,
