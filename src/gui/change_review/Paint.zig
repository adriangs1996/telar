const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Widget = @import("Widget.zig");
const Canvas = @import("../widgets/Canvas.zig");
const Rect = @import("../render/Rect.zig");
const DiffPaint = @import("../widgets/DiffPaint.zig");
const DiffRow = @import("../widgets/DiffRow.zig");
const Target = @import("../widgets/interaction/Target.zig");
const FormButton = @import("../widgets/FormButton.zig");
const TextField = @import("../widgets/TextField.zig");
const TextFit = @import("../widgets/TextFit.zig");
const WrappedLines = @import("../widgets/overlays/WrappedLines.zig");
const actions = @import("action.zig");
const Registry = @import("../widgets/interaction/Registry.zig");
const Self = @This();
const reserved_controls = 16;

widget: *Widget,
canvas: *Canvas,
viewport: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
cursor_y: f32 = 0,
cursor_height: f32 = 0,

pub fn draw(self: *Self) !void {
    const w = self.widget;
    const canvas = self.canvas;
    canvas.theme = w.theme_override orelse client.theme_support.builtin(w.theme);
    const width: f32 = @floatFromInt(canvas.viewport[0]);
    const height: f32 = @floatFromInt(canvas.viewport[1]);
    const p = canvas.chrome;
    const bounds: Rect = .{ .x = 0, .y = 0, .width = width, .height = height };
    try canvas.fillAt(bounds, canvas.theme.palette.surface_dim);
    try self.addTarget(.{ .bounds = bounds, .action = .{ .custom = actions.encode(.background, 0) }, .role = 6 }, "Diff review");
    const sidebar = @min(p.px(240), width * 0.28);
    const top = p.px(if (w.mode == .runtime) @as(f32, 144) else 104);
    const footer = p.px(if (w.search_prompt.open) @as(f32, 92) else 54);
    self.viewport = .{ .x = sidebar + p.px(12), .y = top, .width = @max(1, width - sidebar - p.px(24)), .height = @max(1, height - top - footer) };
    w.prepared_viewport.height = self.viewport.height;
    w.prepared_viewport.generation = w.generation;
    w.prepared_viewport.file = w.model.file;
    var label: [512]u8 = undefined;
    const title = if (w.mode == .runtime)
        try std.fmt.bufPrint(&label, "Change review  /  Edition {d}{s}{s}{s}", .{ w.edition_id, if (w.source_label.len != 0) " · " else "", w.source_label, if (w.next_edition) " · Newer edit available" else "" })
    else
        try std.fmt.bufPrint(&label, "Change review  /  Edition {d}", .{w.model.revision + 1});
    try self.writeLabel(.{ .x = p.px(16), .y = 0, .width = @max(1, width - p.px(310)), .height = p.px(38) }, title);
    try self.button(.{ .x = width - p.px(280), .y = p.px(4), .width = p.px(166), .height = p.px(32) }, .{ .kind = if (w.model.available) .version else if (w.mode != .fixture) .submit else .simulate, .text = if (w.model.available) (if (w.model.revision == 0) "Open edition 2" else "Back to edition 1") else if (w.mode == .fixture) "Simulate next edit" else if (w.delivery == .sending) "Sending review..." else if (w.delivery == .pending) "Retry delivery" else if (w.delivery == .sent) "Review sent" else "Send review", .enabled = w.model.available or w.mode == .fixture or w.delivery == .idle or w.delivery == .pending });
    try self.button(.{ .x = width - p.px(104), .y = p.px(4), .width = p.px(88), .height = p.px(32) }, .{ .kind = if (w.mode == .runtime) .close else .theme, .text = if (w.mode == .runtime) "Close review" else "Theme" });
    if (w.mode == .runtime) {
        try self.button(.{ .x = p.px(16), .y = p.px(94), .width = p.px(96), .height = p.px(32) }, .{ .kind = .previous_edition, .text = "Older edit", .enabled = w.previous_edition and !w.loading });
        try self.button(.{ .x = p.px(120), .y = p.px(94), .width = p.px(100), .height = p.px(32) }, .{ .kind = .next_edition, .text = "Newer edit", .enabled = w.next_edition and !w.loading });
        try self.button(.{ .x = p.px(228), .y = p.px(94), .width = p.px(136), .height = p.px(32) }, .{ .kind = .refresh, .text = "Refresh / retry" });
    }
    if (w.model.current().file_count == 0) {
        try self.writeLabel(.{ .x = p.px(24), .y = top, .width = width - p.px(48), .height = p.px(54) }, if (w.loading) "Loading recorded changes..." else "No diff is available.");
        try self.writeLabel(.{ .x = p.px(24), .y = top + p.px(56), .width = width - p.px(48), .height = p.px(54) }, w.model.status);
        return;
    }
    try self.button(.{ .x = self.viewport.x, .y = p.px(50), .width = p.px(86), .height = p.px(34) }, .{ .kind = .previous, .text = "Previous" });
    try self.button(.{ .x = self.viewport.x + p.px(94), .y = p.px(50), .width = p.px(68), .height = p.px(34) }, .{ .kind = .next, .text = "Next" });
    try self.button(.{ .x = self.viewport.x + p.px(170), .y = p.px(50), .width = p.px(94), .height = p.px(34) }, .{ .kind = .comment, .text = "Comment", .enabled = !w.read_only and !w.loading });
    if (self.viewport.width > p.px(410)) {
        try self.button(.{ .x = self.viewport.x + self.viewport.width - p.px(136), .y = p.px(50), .width = p.px(136), .height = p.px(34) }, .{ .kind = .reviewed, .text = if (w.model.current().files[w.model.file].reviewed) "Reviewed [x]" else if (w.mode == .runtime) "Review edition" else "Mark reviewed", .enabled = !w.read_only and !w.loading });
    }
    try self.drawSidebar(.{ .x = 0, .y = top, .width = sidebar, .height = self.viewport.height });
    const revision = w.model.current();
    const file = revision.files[w.model.file];
    var diff: DiffPaint = .{ .canvas = canvas, .bounds = self.viewport, .viewport = self.viewport, .text = revision.text(w.model.file), .source_start = @intFromPtr(revision.source.ptr), .roles = w.roles[w.model.revision][file.start..file.end], .paint = false, .annotations = .{ .context = self, .row = row, .after = after } };
    w.maximum_scroll = @max(0, try diff.layout() - self.viewport.height);
    w.prepared_viewport.maximum_scroll = w.maximum_scroll;
    if (w.reveal) {
        if (w.model.head == file.first and w.model.search.match == null and w.model.editing == null) {
            w.scroll = 0;
        } else if (self.cursor_y < w.scroll) {
            w.scroll = self.cursor_y;
        } else if (self.cursor_y + self.cursor_height > w.scroll + self.viewport.height) {
            w.scroll = @min(self.cursor_y, self.cursor_y + self.cursor_height - self.viewport.height);
        }
        w.reveal = false;
    }
    w.scroll = std.math.clamp(w.scroll, 0, w.maximum_scroll);
    diff.bounds.y -= w.scroll;
    diff.paint = true;
    _ = try diff.layout();
    const anchor = w.model.anchor();
    var selected_lines: usize = 0;
    if (w.model.visual) {
        for (revision.rows[anchor.first .. anchor.last + 1]) |selected| {
            if (selected.before() == anchor.before) {
                selected_lines += 1;
            }
        }
    }
    var status = if (w.model.visual) try std.fmt.bufPrint(&label, "VISUAL LINE · {d} line(s) · {s} · c: comment on selection · Esc: cancel", .{ selected_lines, if (anchor.before) "before" else "after" }) else w.model.status;
    if (w.model.search.query.len != 0) {
        status = try self.searchStatus(&label);
    } else if (w.search_prompt.open) {
        status = "Literal search in this file · case sensitive · Enter: accept · Esc: cancel";
    }
    if (w.search_prompt.open) {
        status = w.search_prompt.failure orelse status;
    }
    const status_y = height - p.px(54);
    if (w.search_prompt.open) {
        const field = &w.search_prompt.field;
        try self.writeLabel(.{ .x = p.px(16), .y = height - footer, .width = p.px(20), .height = p.px(32) }, "/");
        try (TextField{ .bounds = .{ .x = p.px(40), .y = height - footer, .width = width - p.px(56), .height = p.px(32) }, .text = field.text(), .selection = .{ @intCast(field.anchor), @intCast(field.head) }, .action = .{ .custom = actions.encode(.search, 0) }, .generation = w.generation, .layer = w.layer, .form_control = true, .placeholder = "Search in this file", .label = "Search in diff" }).draw(canvas);
    }
    try self.writeLabel(.{ .x = p.px(16), .y = status_y, .width = width - p.px(32), .height = p.px(27) }, status);
    const help = if (w.search_prompt.open) "Enter: accept · Esc: restore previous position · Search stays within the visual hunk and side" else if (w.model.editing != null) "Cmd/Ctrl+Enter: save comment · Esc: fold · Cmd/Ctrl+C/X/V: clipboard" else if (w.model.search.query.len != 0) "j/k: lines · gg/G: first/last · Ctrl+u/d: half page · /: search · n/N: matches · v: select · c: comment" else "j/k: lines · gg/G: first/last · Ctrl+u/d: half page · /: search · n/p: changes · v: select · c: comment";
    try self.writeLabel(.{ .x = p.px(16), .y = height - p.px(27), .width = width - p.px(32), .height = p.px(27) }, help);
}

fn searchStatus(self: *Self, buffer: []u8) ![]const u8 {
    const w = self.widget;
    const revision = w.model.current();
    const file = revision.files[w.model.file];
    const query = w.model.search.query.text();
    const anchor = revision.rows[w.model.tail];
    var count: usize = 0;
    var selected: usize = 0;
    for (revision.rows[file.first..file.last], file.first..) |line, index| {
        if (w.model.visual and (line.hunk != anchor.hunk or line.before() != anchor.before())) {
            continue;
        }

        var offset: usize = 0;
        while (std.mem.indexOfPos(u8, line.value.text, offset, query)) |at| {
            count += 1;
            if (w.model.search.match) |match| {
                if (match.row == index and match.start == at) {
                    selected = count;
                }
            }
            offset = at + 1;
        }
    }

    if (count == 0) {
        return std.fmt.bufPrint(buffer, "/{s} · No matches{s}", .{ query, if (w.model.visual) " in this visual hunk and side" else " in this file" });
    }
    return std.fmt.bufPrint(buffer, "/{s} · {d}/{d} matches · n/N: next/previous · Esc: clear", .{ query, selected, count });
}

fn drawSidebar(self: *Self, area: Rect) !void {
    const w = self.widget;
    const p = self.canvas.chrome;
    const row_height = p.px(48);
    const capacity: usize = @intFromFloat(@max(1, @floor(area.height / row_height)));
    if (w.reveal and (w.model.file < w.sidebar_start or w.model.file >= w.sidebar_start + capacity)) {
        w.sidebar_start = w.model.file -| (capacity - 1);
    }
    const revision = w.model.current();
    w.sidebar_start = @min(w.sidebar_start, revision.file_count -| capacity);
    for (revision.files[w.sidebar_start..@min(revision.file_count, w.sidebar_start + capacity)], w.sidebar_start..) |file, index| {
        const bounds: Rect = .{ .x = area.x + p.px(8), .y = area.y + @as(f32, @floatFromInt(index - w.sidebar_start)) * row_height, .width = area.width - p.px(16), .height = row_height - p.px(4) };
        if (index == w.model.file) {
            try self.canvas.fillRoundedAt(bounds, .{ .color = self.canvas.theme.palette.surface1, .radius = p.px(6) });
        }
        var count: usize = 0;
        for (w.model.comments) |comment| {
            if (comment.alive and comment.anchor.revision == w.model.revision and comment.anchor.file == index) {
                count += 1;
            }
        }
        var buffer: [core.change_review.max_path_bytes + "[x] ".len]u8 = undefined;
        const basename = std.fs.path.basename(file.path);
        const name = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ if (file.reviewed) "[x] " else "", basename });
        try self.writeLabel(.{ .x = bounds.x + p.px(8), .y = bounds.y, .width = bounds.width - p.px(16), .height = bounds.height / 2 }, name);
        const summary = try std.fmt.bufPrint(&buffer, "+{d} -{d}  ·  {d} comments", .{ file.counts[0], file.counts[1], count });
        try self.writeLabel(.{ .x = bounds.x + p.px(8), .y = bounds.y + bounds.height / 2, .width = bounds.width - p.px(16), .height = bounds.height / 2 }, summary);
        try self.addTarget(.{ .bounds = bounds, .action = .{ .custom = actions.encode(.file, index) } }, file.path);
    }
}

fn row(context: *anyopaque, canvas: *Canvas, value: DiffRow) !void {
    const self: *Self = @ptrCast(@alignCast(context));
    const w = self.widget;
    const revision = w.model.current();
    const offset = @intFromPtr(value.line.text.ptr) - @intFromPtr(revision.source.ptr);
    const index = revision.findRow(offset) orelse return;
    const anchor = w.model.anchor();
    if (index >= anchor.first and index <= anchor.last and revision.rows[index].before() == anchor.before) {
        const first = canvas.quads.items().len;
        try canvas.fillAt(value.code, canvas.theme.palette.accent);
        canvas.quads.fadeFrom(first, 0.12);
        try canvas.fillAt(.{ .x = value.code.x, .y = value.code.y, .width = canvas.chrome.px(2), .height = value.code.height }, canvas.theme.palette.accent);
    }
    const fragment_offset = @intFromPtr(value.fragment.ptr) - @intFromPtr(revision.source.ptr);
    const query = w.model.search.query.text();
    const anchor_row = revision.rows[w.model.tail];
    const search_scope = !w.model.visual or (revision.rows[index].hunk == anchor_row.hunk and revision.rows[index].before() == anchor_row.before());
    if (query.len != 0 and search_scope) {
        const fragment_start = fragment_offset - offset;
        var occurrence = std.mem.indexOfPos(u8, value.line.text, fragment_start -| (query.len - 1), query);
        var clusters: core.GraphemeIterator = .{ .bytes = value.fragment };
        var x = value.code.x;
        while (clusters.next()) |cluster| {
            const end = fragment_start + clusters.index;
            const start = end - cluster.bytes.len;
            const width = @as(f32, @floatFromInt(cluster.width)) * w.prepared_cell;
            while (occurrence != null and occurrence.? + query.len <= start) {
                occurrence = std.mem.indexOfPos(u8, value.line.text, occurrence.? + 1, query);
            }
            if (occurrence) |at| {
                if (at < end) {
                    const selected = if (w.model.search.match) |match| match.row == index and match.end > start and match.start < end else false;
                    const first = canvas.quads.items().len;
                    try canvas.fillAt(.{ .x = x, .y = value.code.y, .width = width, .height = value.code.height }, if (selected) canvas.theme.palette.accent else canvas.theme.palette.yellow);
                    canvas.quads.fadeFrom(first, if (selected) 0.48 else 0.25);
                }
            }
            x += width;
        }
    }
    if (w.copy_range) |selection| {
        const low = @min(selection[0], selection[1]);
        const high = @max(selection[0], selection[1]);
        var clusters: core.GraphemeIterator = .{ .bytes = value.fragment };
        var x = value.code.x;
        while (clusters.next()) |cluster| {
            const end = fragment_offset + clusters.index;
            const width = @as(f32, @floatFromInt(cluster.width)) * w.prepared_cell;
            if (end > low and end - cluster.bytes.len < high) {
                const first = canvas.quads.items().len;
                try canvas.fillAt(.{ .x = x, .y = value.code.y, .width = width, .height = value.code.height }, canvas.theme.palette.accent);
                canvas.quads.fadeFrom(first, 0.28);
            }
            x += width;
        }
    }
    const gutter: Rect = .{ .x = value.bounds.x, .y = value.bounds.y, .width = value.code.x - value.bounds.x, .height = value.bounds.height };
    try self.addTarget(.{ .bounds = clip(gutter, self.viewport), .action = .{ .custom = actions.encode(.line, fragment_offset) }, .focusable = false }, "Select line");
    try self.addTarget(.{ .bounds = clip(value.code, self.viewport), .action = .{ .custom = actions.encode(.code, fragment_offset) }, .focusable = false }, "Select code to copy");
    if (fragment_offset == offset) {
        const plus: Rect = .{ .x = gutter.x, .y = gutter.y, .width = canvas.chrome.px(18), .height = gutter.height };
        var hovered = false;
        if (w.widgets.?.dispatcher.hovered) |id| {
            if (w.widgets.?.dispatcher.maps.presented().find(id)) |target| {
                hovered = target.action == .custom and (actions.kind(target.action.custom) == .line or actions.kind(target.action.custom) == .line_comment) and target.bounds.y == plus.y;
            }
        }
        if (hovered or index == w.model.head) {
            _ = try canvas.textAt(plus, .{ .text = "+", .color = canvas.theme.palette.accent });
        }
        if (!w.read_only and !w.loading) {
            try self.addTarget(.{ .bounds = clip(plus, self.viewport), .action = .{ .custom = actions.encode(.line_comment, index) }, .focusable = false }, "Comment on this line");
        }
    }
}

fn after(context: *anyopaque, _: *Canvas, value: DiffRow) !f32 {
    const self: *Self = @ptrCast(@alignCast(context));
    const w = self.widget;
    const revision = w.model.current();
    const offset = @intFromPtr(value.line.text.ptr) - @intFromPtr(revision.source.ptr);
    const index = revision.findRow(offset) orelse return 0;
    if (!value.paint) {
        w.prepared_viewport.starts[index] = value.start_y - self.viewport.y;
        w.prepared_viewport.ends[index] = value.bounds.y - self.viewport.y;
        w.prepared_viewport.line_height = value.line_height;
    }
    var height: f32 = 0;
    var editor_top: ?f32 = null;
    var editor_height: f32 = 0;
    for (&w.model.comments, 0..) |*comment, comment_index| {
        if (!comment.alive or comment.anchor.revision != w.model.revision or comment.anchor.file != w.model.file or comment.anchor.last != index) {
            continue;
        }
        const editing = w.model.editing == comment_index;
        const expanded = w.model.expanded == comment_index;
        const columns: u16 = @intFromFloat(@max(1, @min(65535, @floor((self.viewport.width - self.canvas.chrome.px(56)) / w.prepared_cell))));
        const text_rows = (WrappedLines{ .text = comment.body.text(), .width = columns }).count();
        const size = self.canvas.chrome.px(if (editing) @as(f32, 192) else if (expanded) 88 + @as(f32, @floatFromInt(text_rows)) * 22 else 42);
        if (editing) {
            editor_top = value.bounds.y + height - self.viewport.y;
            editor_height = size;
        }
        const area: Rect = .{ .x = self.viewport.x, .y = value.bounds.y + height, .width = self.viewport.width, .height = size };
        if (value.paint and area.y + area.height > self.viewport.y and area.y < self.viewport.y + self.viewport.height) {
            try self.drawComment(area, comment_index);
        }
        height += size;
    }
    if (!value.paint and index == w.model.head) {
        const row_height = value.line_height;
        self.cursor_y = editor_top orelse (value.bounds.y - self.viewport.y - row_height);
        self.cursor_height = if (editor_top != null) editor_height else row_height;
        if (editor_top == null) {
            if (w.model.search.match) |match| {
                if (match.row == index) {
                    self.revealMatch(value, match.start);
                }
            }
        }
    }
    return height;
}

fn revealMatch(self: *Self, value: DiffRow, start: usize) void {
    var wrapped: WrappedLines = .{ .text = value.line.text, .width = value.columns };
    var y = value.start_y - self.viewport.y;
    while (wrapped.next()) |fragment| {
        const offset = @intFromPtr(fragment.ptr) - @intFromPtr(value.line.text.ptr);
        if (start >= offset and start < offset + fragment.len) {
            self.cursor_y = y;
            return;
        }
        y += value.line_height;
    }
}

fn drawComment(self: *Self, area: Rect, index: usize) !void {
    const w = self.widget;
    const comment = &w.model.comments[index];
    const p = self.canvas.chrome;
    const editing = w.model.editing == index;
    const expanded = w.model.expanded == index;
    const first_target = w.widgets.?.dispatcher.maps.preparing().len;
    defer {
        const registry = w.widgets.?.dispatcher.maps.preparing();
        for (registry.targets[first_target..registry.len]) |*target| {
            target.bounds = clip(target.bounds, self.viewport);
        }
    }
    const card: Rect = .{ .x = area.x + p.px(18), .y = area.y + p.px(4), .width = @max(1, area.width - p.px(36)), .height = area.height - p.px(8) };
    try self.canvas.fillRoundedAt(card, .{ .color = self.canvas.theme.palette.surface0, .radius = p.px(8) });
    const revision = &w.model.revisions[comment.anchor.revision];
    const start = revision.rows[comment.anchor.first].value;
    const end = revision.rows[comment.anchor.last].value;
    var buffer: [core.change_review.max_path_bytes + "[x] ".len]u8 = undefined;
    const label = try std.fmt.bufPrint(&buffer, "{s} · Edition {d} · {s} lines {d}–{d}", .{ if (comment.draft) "Draft" else "Comment", if (w.mode == .runtime) w.edition_id else comment.anchor.revision + 1, if (comment.anchor.before) "old" else "new", (if (comment.anchor.before) start.old else start.new) orelse 0, (if (comment.anchor.before) end.old else end.new) orelse 0 });
    try self.writeLabel(.{ .x = card.x + p.px(10), .y = card.y, .width = card.width - p.px(100), .height = p.px(32) }, label);
    if (!expanded and !editing) {
        try self.button(.{ .x = card.x + card.width - p.px(82), .y = card.y, .width = p.px(76), .height = p.px(30) }, .{ .kind = .open_comment, .item = index, .text = "Open" });
        return;
    }
    const content: Rect = .{ .x = card.x + p.px(10), .y = card.y + p.px(34), .width = card.width - p.px(20), .height = card.height - p.px(80) };
    if (editing) {
        try (TextField{ .bounds = content, .text = comment.body.text(), .selection = .{ @intCast(comment.body.anchor), @intCast(comment.body.head) }, .action = .{ .custom = actions.encode(.editor, index) }, .generation = w.generation, .multiline = true, .form_control = true, .placeholder = "What should change, and why?", .label = "Review comment" }).draw(self.canvas);
    } else {
        var lines: WrappedLines = .{ .text = comment.body.text(), .width = @intFromFloat(@max(1, @floor(content.width / w.prepared_cell))) };
        var y = content.y;
        while (lines.next()) |text| {
            if (y + p.px(22) > content.y + content.height) {
                break;
            }
            if (y + p.px(22) > self.viewport.y and y < self.viewport.y + self.viewport.height) {
                try self.writeLabel(.{ .x = content.x, .y = y, .width = content.width, .height = p.px(22) }, text);
            }
            y += p.px(22);
        }
    }
    const y = card.y + card.height - p.px(38);
    try self.button(.{ .x = card.x + p.px(10), .y = y, .width = p.px(108), .height = p.px(30) }, .{ .kind = if (editing) .save else .edit, .item = index, .text = if (editing) "Save comment" else "Edit", .enabled = !w.read_only });
    try self.button(.{ .x = card.x + p.px(126), .y = y, .width = p.px(70), .height = p.px(30) }, .{ .kind = .fold, .item = index, .text = "Fold" });
    try self.button(.{ .x = card.x + card.width - p.px(80), .y = y, .width = p.px(70), .height = p.px(30) }, .{ .kind = .delete, .item = index, .text = "Delete", .enabled = !w.read_only });
}

fn writeLabel(self: *Self, area: Rect, text: []const u8) !void {
    var buffer: [TextFit.max_bytes]u8 = undefined;
    const fitted = try (TextFit{ .canvas = self.canvas, .width = @max(0, area.width) }).fit(.{ .text = text, .face = .sans, .size = .small }, &buffer);
    _ = try self.canvas.textAt(area, .{ .text = fitted, .face = .sans, .size = .small, .color = self.canvas.theme.palette.text });
}

fn addTarget(self: *Self, original: Target, label_text: []const u8) !void {
    var target_value = original.labelled(label_text);
    target_value.id.generation = self.widget.generation;
    target_value.layer = self.widget.layer;
    if (self.widget.widgets.?.dispatcher.maps.preparing().len >= Registry.capacity - reserved_controls) {
        return;
    }
    _ = try self.widget.widgets.?.dispatcher.add(target_value);
}

fn button(self: *Self, area: Rect, value: struct { kind: actions.Kind, item: usize = 0, text: []const u8, enabled: bool = true }) !void {
    try (FormButton{ .bounds = area, .text = value.text, .enabled = value.enabled, .action = .{ .custom = actions.encode(value.kind, value.item) }, .generation = self.widget.generation, .namespace = 0 }).draw(self.canvas);
}

fn clip(area: Rect, viewport: Rect) Rect {
    const x = @max(area.x, viewport.x);
    const y = @max(area.y, viewport.y);
    return .{ .x = x, .y = y, .width = @max(0, @min(area.x + area.width, viewport.x + viewport.width) - x), .height = @max(0, @min(area.y + area.height, viewport.y + viewport.height) - y) };
}
