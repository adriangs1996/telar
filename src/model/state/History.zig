const core = @import("telar-core");
const name_prompt = @import("name_prompt.zig");
const History = @This();

selection: u16 = 0,
scope: name_prompt.HistoryScope = .global,
/// Whose commands the page lists; the palette opens with the configured default.
author: core.HistoryAuthorFilter = .human,
/// Only commands that exited non-zero.
failed_only: bool = false,
inspecting: bool = false,
detail_scroll: u32 = 0,
page_requested: enum { none, older, newer } = .none,
