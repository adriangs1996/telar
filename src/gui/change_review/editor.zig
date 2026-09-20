//! Reuses the same bounded UTF-8 field, wrapping and preedit as native editors.
const std = @import("std");
const Widget = @import("Widget.zig");
const Event = @import("../input/event.zig").Event;
const Target = @import("../widgets/interaction/Target.zig");
const FieldView = @import("../widgets/interaction/FieldView.zig");
const EditorDisplay = @import("../widgets/interaction/EditorDisplay.zig");
const MultilineLayout = @import("../widgets/interaction/MultilineLayout.zig");
const Owner = @import("../host/Owner.zig");
const native = @import("../native/native.zig");
const actions = @import("action.zig");

pub fn apply(w: *Widget, event: Event, target: Target) !bool {
    if (w.read_only) {
        return true;
    }
    const index = w.model.editing orelse return false;
    const comment = &w.model.comments[index];
    const field = &comment.body;
    const state = w.widgets.?;
    const current: FieldView = .{ .text = field.text(), .anchor = @intCast(field.anchor), .head = @intCast(field.head) };
    switch (event) {
        .text => |text| {
            if (text.phase == .release) {
                return false;
            }
            const range = if (text.replacement_start != std.math.maxInt(u32)) [2]u32{ text.replacement_start, text.replacement_end } else if (state.preedit.owner != null) state.preedit.replacement else current.selection();
            replace(w, .{ .range = range, .text = text.bytes });
        },
        .paste => |bytes| replace(w, .{ .range = current.selection(), .text = bytes }),
        .composition => |composition| {
            state.preedit.update(target.id, .{ .composition = composition, .current = current }) catch {
                w.model.status = "Composition rejected: invalid text or capacity exceeded.";
            };
        },
        .accessibility => |value| {
            if (value.revision != 0 and value.revision != w.text_revision) {
                return false;
            }
            switch (value.action) {
                .set_value => replace(w, .{ .range = .{ 0, @intCast(field.len) }, .text = value.text }),
                .replace_range => replace(w, .{ .range = .{ value.replacement_start, value.replacement_end }, .text = value.text }),
                .set_selection => {
                    _ = field.selectRange(.{ value.selection_start, value.selection_end });
                    state.cancelComposition();
                    w.text_revision += 1;
                },
                .copy => try clipboard(w, target, 'c'),
                .cut => try clipboard(w, target, 'x'),
                .paste => try clipboard(w, target, 'v'),
                else => {},
            }
        },
        .delete_surrounding => |value| {
            if (value.before <= field.head and value.after <= field.len - field.head) {
                replace(w, .{ .range = .{ @intCast(field.head - value.before), @intCast(field.head + value.after) }, .text = "" });
            }
        },
        .clipboard => |result| {
            if (w.clipboard_id != result.request_id) {
                return false;
            }
            w.clipboard_id = null;
            if (result.status != .success or w.clipboard_revision != w.text_revision) {
                w.model.status = "Clipboard operation was cancelled; the draft is unchanged.";
                return true;
            }
            if (result.operation == .read) {
                replace(w, .{ .range = w.clipboard_selection, .text = result.text });
            } else if (w.clipboard_cut) {
                replace(w, .{ .range = w.clipboard_selection, .text = "" });
            }
        },
        .pointer => |pointer| {
            if (pointer.button != .left or (pointer.kind != .press and pointer.kind != .drag)) {
                return false;
            }
            const geometry = state.editors.presented().find(target.id) orelse return false;
            const layout: MultilineLayout = .{ .text = field.text(), .head = @intCast(field.head), .columns = geometry.columns, .rows = @intFromFloat(@max(1, @floor(geometry.bounds.height / geometry.line_height))) };
            const offset = layout.offset(.{ (pointer.x - geometry.bounds.x) / geometry.cell_width, (pointer.y - geometry.bounds.y) / geometry.line_height });
            _ = field.selectRange(.{ if (pointer.kind == .drag or pointer.mods & 1 != 0) @intCast(field.anchor) else offset, offset });
            state.cancelComposition();
        },
        .key => |key| {
            if (key.phase == .release) {
                return false;
            }
            const command = key.mods.ctrl or key.mods.super;
            if (command and key.code == .char) {
                const letter = key.code.char;
                if (letter.len != 1) {
                    return true;
                }
                switch (std.ascii.toLower(letter.bytes[0])) {
                    'a' => field.selectAll(),
                    'c', 'x', 'v' => |ch| try clipboard(w, target, ch),
                    else => {},
                }
                return true;
            }
            if (state.preedit.owner != null) {
                if (key.code == .escape) {
                    state.cancelComposition();
                }
                return true;
            }
            switch (key.code) {
                .escape => {
                    w.model.editing = null;
                    w.model.expanded = null;
                    w.changedOwner();
                },
                .enter => {
                    if (command) {
                        w.saveComment();
                        w.changedOwner();
                    } else {
                        replace(w, .{ .range = current.selection(), .text = "\n" });
                    }
                },
                .backspace => {
                    field.backspace();
                    comment.draft = true;
                    w.noteComment(index);
                },
                .delete => {
                    field.delete();
                    comment.draft = true;
                    w.noteComment(index);
                },
                .left => if (key.mods.alt or key.mods.ctrl) field.moveWordLeft(key.mods.shift) else field.moveLeft(key.mods.shift),
                .right => if (key.mods.alt or key.mods.ctrl) field.moveWordRight(key.mods.shift) else field.moveRight(key.mods.shift),
                .home => field.home(key.mods.shift),
                .end => field.end(key.mods.shift),
                .up, .down => {
                    const geometry = state.editors.presented().find(target.id) orelse return true;
                    const layout: MultilineLayout = .{ .text = field.text(), .head = @intCast(field.head), .columns = geometry.columns, .rows = 65535 };
                    const position = layout.position(@intCast(field.head));
                    const row = if (key.code == .up) position[1] -| 1 else position[1] + 1;
                    const at = layout.offset(.{ @floatFromInt(position[0]), @floatFromInt(row) });
                    _ = field.selectRange(.{ if (key.mods.shift) @intCast(field.anchor) else at, at });
                },
                else => {},
            }
            w.text_revision += 1;
        },
        else => return false,
    }
    return true;
}

fn clipboard(w: *Widget, target: Target, command: u8) !void {
    const field = &w.model.comments[w.model.editing.?].body;
    const owner: Owner = .{ .target_id = target.id.target_id, .generation = target.id.generation };
    w.clipboard_id = if (command == 'v') try w.services().read(owner) else try w.services().writeOwned(owner, field.selected());
    w.clipboard_selection = .{ @intCast(@min(field.anchor, field.head)), @intCast(@max(field.anchor, field.head)) };
    w.clipboard_revision = w.text_revision;
    w.clipboard_cut = command == 'x';
}

fn replace(w: *Widget, request: struct { range: [2]u32, text: []const u8 }) void {
    const index = w.model.editing orelse return;
    const comment = &w.model.comments[index];
    const view: FieldView = .{ .text = comment.body.text(), .head = @intCast(comment.body.head), .anchor = @intCast(comment.body.anchor) };
    const start = @min(request.range[0], request.range[1]);
    const end = @max(request.range[0], request.range[1]);
    if (!view.validRange(request.range) or !std.unicode.utf8ValidateSlice(request.text) or request.text.len > comment.body.bytes.len - (comment.body.len - (end - start))) {
        w.model.status = "Comment limit: 2048 UTF-8 bytes. Nothing was truncated.";
        return;
    }
    _ = comment.body.replace(request.range, request.text);
    comment.draft = true;
    w.noteComment(w.model.editing.?);
    w.text_revision += 1;
    w.widgets.?.cancelComposition();
}

pub fn context(w: *Widget, out: *native.TextContext) bool {
    const index = w.model.editing orelse return false;
    const state = w.widgets orelse return false;
    const target = state.dispatcher.focusedTarget() orelse return false;
    if (target.id.generation != w.generation or target.action != .custom or actions.kind(target.action.custom) != .editor) {
        return false;
    }
    const geometry = state.editors.presented().find(target.id) orelse return false;
    const field = &w.model.comments[index].body;
    const preedit = if (state.preedit.owner != null) &state.preedit else null;
    var display = EditorDisplay.capture(.{ .text = field.text(), .head = @intCast(field.head), .anchor = @intCast(field.anchor) }, preedit);
    const layout: MultilineLayout = .{ .text = display.field.text(), .head = @intCast(display.field.head), .columns = geometry.columns, .rows = @intFromFloat(@max(1, @floor(geometry.bounds.height / geometry.line_height))) };
    const caret = layout.position(@intCast(display.field.head));
    out.* = .{ .target_id = target.id.target_id, .generation = target.id.generation, .revision = w.text_revision +% state.dispatcher.revision, .enabled = 1, .composition_active = @intFromBool(preedit != null), .text = field.text().ptr, .len = field.len, .selection_start = @intCast(field.anchor), .selection_end = @intCast(field.head), .x = geometry.bounds.x + @as(f64, @floatFromInt(caret[0])) * geometry.cell_width, .y = geometry.bounds.y + @as(f64, @floatFromInt(caret[1] -| layout.firstRow())) * geometry.line_height, .width = 1, .height = geometry.line_height };
    return true;
}
