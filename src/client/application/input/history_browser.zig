//! Coordinates disposable history search, paging and inspection state.
//! Operations own wire decoding and delivery; bounded model APIs own storage.

const ReadType = @import("Read.zig");
const PageResult = @import("../../model/PageResult.zig");
const std = @import("std");
const ModelType = @import("../../model/Model.zig");

pub fn begin(model: *ModelType, options: struct { enter_runs: bool, match_fuzzy: bool }) void {
    model.history_palette.begin();
    model.history_palette.configure(.{ .enter_runs = options.enter_runs, .match_fuzzy = options.match_fuzzy });
}

pub fn restart(model: *ModelType) void {
    model.history_palette.restartQuery();
    model.name_prompt.updateHistory(.{ .selection = 0, .reset_scroll = true });
}

pub fn select(model: *ModelType, index: u16, revision: u64) bool {
    const prompt = model.name_prompt.currentConst() orelse return false;
    const palette = &model.history_palette;
    if (prompt.target() != .history or palette.phase != .ready or palette.version() != revision or index >= palette.len) {
        return false;
    }

    model.name_prompt.updateHistory(.{ .selection = index, .reset_scroll = true });
    return true;
}

pub fn apply(model: *ModelType, page: PageResult) bool {
    const palette = &model.history_palette;
    if (palette.applyFull(page.request_id, page.entries)) {
        return true;
    }

    const previous_offset = palette.page_offset;
    if (!palette.acceptPageResult(page)) {
        return false;
    }

    if (model.name_prompt.currentConst()) |prompt| {
        const selection = if (palette.page_offset < previous_offset) palette.len -| 1 else @min(prompt.selection(), palette.len -| 1);
        model.name_prompt.updateHistory(.{ .selection = selection, .reset_scroll = true });
    }

    return true;
}

pub fn navigate(model: *ModelType) bool {
    const prompt = model.name_prompt.currentConst() orelse return false;
    const palette = &model.history_palette;
    if (prompt.target() != .history) {
        return false;
    }

    const requested = model.name_prompt.takeHistoryPage();
    if (!palette.page(if (requested == .older or prompt.selection() >= palette.len)
        .older
    else if (requested == .newer)
        .newer
    else
        return false))
    {
        return false;
    }

    model.name_prompt.updateHistory(.{ .selection = 0, .reset_scroll = true });
    return true;
}

pub fn nextRead(model: *ModelType) ?ReadType {
    const palette = &model.history_palette;
    const prompt = model.name_prompt.currentConst();
    if (prompt == null or prompt.?.target() != .history or palette.phase != .ready or palette.len == 0) {
        palette.clearOutput();
        return null;
    }

    if (!prompt.?.inspecting()) {
        palette.clearOutput();
    }

    const selection = @min(prompt.?.selection(), palette.len - 1);
    const entry = &palette.slice()[selection];
    if (!entry.captured_truncated and palette.commandAt(selection) == null and palette.full_id != entry.id) {
        return .{ .id = entry.id, .kind = .command };
    }

    if (prompt.?.inspecting() and palette.output_id != entry.id) {
        return .{ .id = entry.id, .kind = .output };
    }

    return null;
}

pub fn constrainInspection(model: *ModelType, limit: u32) void {
    model.name_prompt.updateHistory(.{ .scroll_limit = limit });
}

pub fn scrollInspection(model: *ModelType, lines: i16) void {
    if (model.history_palette.phase == .ready) {
        model.name_prompt.updateHistory(.{ .scroll_by = lines });
    }
}

pub fn requestRead(model: *ModelType, request_id: u64, read: ReadType) bool {
    const palette = &model.history_palette;
    if (!palette.track(request_id)) {
        return false;
    }

    switch (read.kind) {
        .command => palette.expectFull(.{ .request_id = request_id, .id = read.id }),
        .output => palette.expectOutput(.{ .request_id = request_id, .id = read.id }),
    }

    return true;
}

pub fn requestDelete(model: *ModelType, request_id: u64, selection: u16) ?u64 {
    const palette = &model.history_palette;
    if (palette.len == 0 or palette.phase != .ready or palette.delete_request != 0 or !palette.track(request_id)) {
        return null;
    }

    palette.expectDelete(request_id);
    return palette.slice()[@min(selection, palette.len - 1)].id;
}

pub fn pruned(model: *ModelType, request_id: u64) bool {
    if (!model.history_palette.pruned(request_id)) {
        return false;
    }

    const prompt = model.name_prompt.currentConst() orelse return false;
    return prompt.target() == .history;
}

test "inspection constraints change semantic scroll only when it exceeds the bound" {
    const state = try std.testing.allocator.create(ModelType);
    defer std.testing.allocator.destroy(state);
    state.* = ModelType.init(std.testing.allocator, true);
    defer state.deinit();
    state.name_prompt.begin(.history_palette);
    _ = state.name_prompt.apply(.toggle_inspection);
    _ = state.name_prompt.apply(.page_down);
    constrainInspection(state, 2);
    try std.testing.expectEqual(@as(u32, 2), state.name_prompt.currentConst().?.detailScroll());
    const revision = state.version();
    constrainInspection(state, 2);
    try std.testing.expectEqualDeep(revision, state.version());
    constrainInspection(state, 0);
    try std.testing.expectEqual(@as(u32, 0), state.name_prompt.currentConst().?.detailScroll());
}
