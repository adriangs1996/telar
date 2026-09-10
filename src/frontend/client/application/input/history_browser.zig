//! Coordinates disposable history search, paging and inspection state.
//! Controllers own wire decoding and delivery; bounded model APIs own storage.

const std = @import("std");
const core = @import("telar-core");
const model = @import("telar-client").model;
const schema = core.schema;

pub const Handler = struct {
    model: *model.Model,

    pub const Page = model.HistoryPageResult;

    /// Opens one search generation with the configured Enter behavior.
    /// Example: `handler.begin(.{ .enter_runs = false, .match_fuzzy = true });`.
    pub fn begin(handler: Handler, options: struct { enter_runs: bool, match_fuzzy: bool }) void {
        handler.model.history_palette.begin();
        handler.model.history_palette.configure(.{ .enter_runs = options.enter_runs, .match_fuzzy = options.match_fuzzy });
    }

    /// Invalidates pagination and selection when the query or scope changes.
    /// Example: `handler.restart();`.
    pub fn restart(handler: Handler) void {
        handler.model.history_palette.restartQuery();
        handler.model.name_prompt.updateHistory(.{ .selection = 0, .reset_scroll = true });
    }

    /// Reserves a request before delivery and makes previous rows non-actionable.
    /// Example: `if (!handler.requestPage(id, .global)) return;`.
    pub fn requestPage(handler: Handler, id: u64, scope: schema.HistoryScope) bool {
        return handler.model.history_palette.beginPageRequest(id, scope);
    }

    /// Commits only the current result page, preserving the search field and inspector.
    /// Example: `_ = handler.apply(page);`.
    pub fn apply(handler: Handler, page: Page) bool {
        const palette = &handler.model.history_palette;
        if (palette.applyFull(page.request_id, page.entries)) {
            return true;
        }

        const previous_offset = palette.page_offset;
        if (!palette.acceptPageResult(page)) {
            return false;
        }

        if (handler.model.name_prompt.currentConst()) |prompt| {
            const selection = if (palette.page_offset < previous_offset) palette.len -| 1 else @min(prompt.selection(), palette.len -| 1);
            handler.model.name_prompt.updateHistory(.{ .selection = selection, .reset_scroll = true });
        }

        return true;
    }

    /// Consumes navigation intent before planning an adjacent page.
    /// Example: `if (handler.navigate()) sendPage();`.
    pub fn navigate(handler: Handler) bool {
        const prompt = handler.model.name_prompt.currentConst() orelse return false;
        const palette = &handler.model.history_palette;
        if (prompt.target() != .history) {
            return false;
        }

        const requested = handler.model.name_prompt.takeHistoryPage();
        if (!palette.page(if (requested == .older or prompt.selection() >= palette.len)
            .older
        else if (requested == .newer)
            .newer
        else
            return false))
        {
            return false;
        }

        handler.model.name_prompt.updateHistory(.{ .selection = 0, .reset_scroll = true });
        return true;
    }

    pub const Read = struct { id: u64, kind: enum { command, output } };

    /// Selects the next missing detail, clearing output as soon as inspection closes.
    /// Example: `const read = handler.nextRead() orelse return;`.
    pub fn nextRead(handler: Handler) ?Read {
        const palette = &handler.model.history_palette;
        const prompt = handler.model.name_prompt.currentConst();
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

    /// Applies a presentation-provided bound without depending on inspector geometry.
    /// Example: `handler.constrainInspection(limit);`.
    pub fn constrainInspection(handler: Handler, limit: u32) void {
        handler.model.name_prompt.updateHistory(.{ .scroll_limit = limit });
    }

    /// Correlates each admitted detail request with its selected history entry.
    /// Example: `if (!handler.requestRead(request_id, read)) return;`.
    pub fn requestRead(handler: Handler, request_id: u64, read: Read) bool {
        const palette = &handler.model.history_palette;
        if (!palette.track(request_id)) {
            return false;
        }

        switch (read.kind) {
            .command => palette.expectFull(.{ .request_id = request_id, .id = read.id }),
            .output => palette.expectOutput(.{ .request_id = request_id, .id = read.id }),
        }

        return true;
    }

    pub fn output(handler: Handler, reply: schema.HistoryOutput) bool {
        return handler.model.history_palette.applyOutput(reply);
    }

    pub fn fail(handler: Handler, reply: schema.RequestFailed) bool {
        return handler.model.history_palette.fail(reply);
    }

    pub fn reject(handler: Handler, message: []const u8) void {
        handler.model.history_palette.setError(message);
    }

    /// Reserves an exact-entry deletion without removing the visible row optimistically.
    /// Example: `const id = handler.requestDelete(request_id, selection) orelse return;`.
    pub fn requestDelete(handler: Handler, request_id: u64, selection: u16) ?u64 {
        const palette = &handler.model.history_palette;
        if (palette.len == 0 or palette.phase != .ready or palette.delete_request != 0 or !palette.track(request_id)) {
            return null;
        }

        palette.expectDelete(request_id);
        return palette.slice()[@min(selection, palette.len - 1)].id;
    }

    pub fn pruned(handler: Handler, request_id: u64) bool {
        if (!handler.model.history_palette.pruned(request_id)) {
            return false;
        }

        const prompt = handler.model.name_prompt.currentConst() orelse return false;
        return prompt.target() == .history;
    }
};

test "inspection constraints change semantic scroll only when it exceeds the bound" {
    const state = try std.testing.allocator.create(model.Model);
    defer std.testing.allocator.destroy(state);
    state.* = model.Model.init(std.testing.allocator, true);
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
