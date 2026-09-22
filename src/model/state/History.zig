const name_prompt = @import("name_prompt.zig");
const History = @This();

selection: u16 = 0,
scope: name_prompt.HistoryScope = .global,
inspecting: bool = false,
detail_scroll: u32 = 0,
page_requested: enum { none, older, newer } = .none,
