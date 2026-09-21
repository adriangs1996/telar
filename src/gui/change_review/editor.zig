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
    if (!ownsField(w, target)) {
        return false;
    }
    if (w.read_only and !w.search_prompt.open) {
        return true;
    }
    const field = w.activeField() orelse return false;
    const state = w.widgets orelse return false;
    const current: FieldView = .{ .text = field.text(), .anchor = @intCast(field.anchor), .head = @intCast(field.head) };
    switch (event) {
        .text => |text| {
            if (text.phase == .release) {
                return false;
            }
            const composing = if (state.preedit.owner) |owner| owner.eql(target.id) else false;
            const range = if (text.replacement_start != std.math.maxInt(u32)) [2]u32{ text.replacement_start, text.replacement_end } else if (composing) state.preedit.replacement else current.selection();
            replace(w, .{ .range = range, .text = text.bytes });
        },
        .paste => |bytes| replace(w, .{ .range = current.selection(), .text = bytes }),
        .composition => |composition| {
            if (!composition.cancel) {
                const composing = if (state.preedit.owner) |owner| owner.eql(target.id) else false;
                const range = if (composition.replacement_start != std.math.maxInt(u32)) [2]u32{ composition.replacement_start, composition.replacement_end } else if (composing) state.preedit.replacement else current.selection();
                if (!validReplacement(w, .{ .range = range, .text = composition.text })) {
                    return true;
                }
            }
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
            if (w.clipboard_id != result.request_id or result.target_id != target.id.target_id or result.generation != target.id.generation) {
                return false;
            }
            w.clipboard_id = null;
            if (result.status != .success or w.clipboard_revision != w.text_revision) {
                w.model.status = "Clipboard operation was cancelled; the text is unchanged.";
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
            var display = EditorDisplay.capture(current, null);
            const visible = display.field.view(geometry.columns);
            const layout: MultilineLayout = .{ .text = if (geometry.multiline) field.text() else visible.text, .head = if (geometry.multiline) @intCast(field.head) else 0, .columns = if (geometry.multiline) geometry.columns else std.math.maxInt(u16), .rows = @intFromFloat(@max(1, @floor(geometry.bounds.height / geometry.line_height))) };
            const offset = layout.offset(.{ (pointer.x - geometry.bounds.x) / geometry.cell_width, if (geometry.multiline) (pointer.y - geometry.bounds.y) / geometry.line_height else 0 }) + (if (geometry.multiline) @as(u32, 0) else @as(u32, @intCast(display.field.scroll)));
            if (field.selectRange(.{ if (pointer.kind == .drag or pointer.mods & 1 != 0) @intCast(field.anchor) else offset, offset })) {
                w.text_revision += 1;
            }
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
                    'a' => {
                        field.selectAll();
                        w.text_revision += 1;
                    },
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
                    if (w.search_prompt.open) {
                        w.finishSearch(false);
                    } else {
                        w.model.editing = null;
                        w.model.expanded = null;
                        w.changedOwner();
                    }
                    return true;
                },
                .enter => {
                    if (w.search_prompt.open) {
                        w.finishSearch(true);
                    } else if (command) {
                        w.saveComment();
                        w.changedOwner();
                    } else {
                        replace(w, .{ .range = current.selection(), .text = "\n" });
                    }
                    return true;
                },
                .backspace => {
                    field.backspace();
                    w.fieldChanged();
                    return true;
                },
                .delete => {
                    field.delete();
                    w.fieldChanged();
                    return true;
                },
                .left => if (key.mods.alt or key.mods.ctrl) field.moveWordLeft(key.mods.shift) else field.moveLeft(key.mods.shift),
                .right => if (key.mods.alt or key.mods.ctrl) field.moveWordRight(key.mods.shift) else field.moveRight(key.mods.shift),
                .home => field.home(key.mods.shift),
                .end => field.end(key.mods.shift),
                .up, .down => {
                    const geometry = state.editors.presented().find(target.id) orelse return true;
                    if (!geometry.multiline) {
                        return true;
                    }
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
    const field = w.activeField() orelse return;
    const owner: Owner = .{ .target_id = target.id.target_id, .generation = target.id.generation };
    w.clipboard_id = if (command == 'v') try w.services().read(owner) else try w.services().writeOwned(owner, field.selected());
    w.clipboard_selection = .{ @intCast(@min(field.anchor, field.head)), @intCast(@max(field.anchor, field.head)) };
    w.clipboard_revision = w.text_revision;
    w.clipboard_cut = command == 'x';
}

fn replace(w: *Widget, request: struct { range: [2]u32, text: []const u8 }) void {
    if (!validReplacement(w, .{ .range = request.range, .text = request.text })) {
        return;
    }

    const field = w.activeField() orelse return;
    _ = field.replace(request.range, request.text);
    w.fieldChanged();
    w.widgets.?.cancelComposition();
}

fn validReplacement(w: *Widget, request: struct { range: [2]u32, text: []const u8 }) bool {
    const field = w.activeField() orelse return false;
    const view: FieldView = .{ .text = field.text(), .head = @intCast(field.head), .anchor = @intCast(field.anchor) };
    const limit: usize = if (w.search_prompt.open) w.model.search.query.bytes.len else field.bytes.len;
    const valid = request.range[0] <= request.range[1] and view.validRange(request.range) and std.unicode.utf8ValidateSlice(request.text);
    const single_line = !w.search_prompt.open or std.mem.indexOfAny(u8, request.text, "\x00\r\n") == null;
    if (valid and single_line) {
        const remaining = field.len - (request.range[1] - request.range[0]);
        if (remaining <= limit and request.text.len <= limit - remaining) {
            return true;
        }
    }

    if (w.search_prompt.open) {
        w.search_prompt.failure = "Search limit: 256 UTF-8 bytes, without line breaks or NUL. Nothing was truncated.";
    } else {
        w.model.status = "Comment limit: 2048 UTF-8 bytes. Nothing was truncated.";
    }
    return false;
}

fn ownsField(w: *const Widget, target: Target) bool {
    const expected: actions.Kind = if (w.search_prompt.open) .search else .editor;
    return target.id.generation == w.generation and target.action == .custom and actions.kind(target.action.custom) == expected;
}

pub fn context(w: *Widget, out: *native.TextContext) bool {
    const field = w.activeField() orelse return false;
    const state = w.widgets orelse return false;
    const target = state.dispatcher.focusedTarget() orelse return false;
    if (!ownsField(w, target) or (w.read_only and !w.search_prompt.open)) {
        return false;
    }
    const geometry = state.editors.presented().find(target.id) orelse return false;
    const preedit = if (state.preedit.owner) |owner| if (owner.eql(target.id)) &state.preedit else null else null;
    var display = EditorDisplay.capture(.{ .text = field.text(), .head = @intCast(field.head), .anchor = @intCast(field.anchor) }, preedit);
    const layout: MultilineLayout = .{ .text = display.field.text(), .head = @intCast(display.field.head), .columns = geometry.columns, .rows = @intFromFloat(@max(1, @floor(geometry.bounds.height / geometry.line_height))) };
    const caret = if (geometry.multiline) layout.position(@intCast(display.field.head)) else [2]u32{ display.field.view(geometry.columns).cursor, 0 };
    out.* = .{ .target_id = target.id.target_id, .generation = target.id.generation, .revision = w.text_revision +% state.dispatcher.revision, .enabled = 1, .composition_active = @intFromBool(preedit != null), .text = field.text().ptr, .len = field.len, .selection_start = @intCast(field.anchor), .selection_end = @intCast(field.head), .x = geometry.bounds.x + @as(f64, @floatFromInt(@min(caret[0], geometry.columns -| 1))) * geometry.cell_width, .y = geometry.bounds.y + (if (geometry.multiline) @as(f64, @floatFromInt(caret[1] -| layout.firstRow())) * geometry.line_height else 0), .width = 1, .height = geometry.line_height };
    return true;
}
