//! Coordinates disposable history search, paging and inspection state.
//! Controllers own wire decoding and delivery; bounded model APIs own storage.

const std = @import("std");
const ModelType = @import("../../model/Model.zig");
const Handler = @import("HistoryBrowserHandler.zig");

test "inspection constraints change semantic scroll only when it exceeds the bound" {
    const state = try std.testing.allocator.create(ModelType);
    defer std.testing.allocator.destroy(state);
    state.* = ModelType.init(std.testing.allocator, true);
    defer state.deinit();
    state.name_prompt.begin(.history_palette);
    _ = state.name_prompt.apply(.toggle_inspection);
    _ = state.name_prompt.apply(.page_down);
    const handler: Handler = .{ .model = state };
    handler.constrainInspection(2);
    try std.testing.expectEqual(@as(u32, 2), state.name_prompt.currentConst().?.detailScroll());
    const revision = state.version();
    handler.constrainInspection(2);
    try std.testing.expectEqualDeep(revision, state.version());
    handler.constrainInspection(0);
    try std.testing.expectEqual(@as(u32, 0), state.name_prompt.currentConst().?.detailScroll());
}
