const History = @This();
const source_namespace = @import("name_prompt.zig");
selection: u16 = 0,
scope: source_namespace.HistoryScope = .global,
inspecting: bool = false,
detail_scroll: u32 = 0,
page_requested: enum { none, older, newer } = .none,
