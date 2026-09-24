const cellgrid = @import("cellgrid");
const data = @import("model");
const event_module = @import("../input/event.zig");
const std = @import("std");
const Widget = @import("Widget.zig");
const Editor = @import("editor.zig");
const Route = @import("../widgets/interaction/Route.zig");
const Target = @import("../widgets/interaction/Target.zig");
const actions = @import("action.zig");
const syntax_limits = @import("../syntax/limits.zig");

pub fn apply(w: *Widget, event: event_module.Event, route: Route) !bool {
    if (event == .focus and !event.focus) {
        w.dragging = false;
        w.pending_g = false;
        return false;
    }
    const target = route.target orelse return false;
    if (target.id.generation != w.generation or target.action != .custom) {
        return false;
    }
    const kind = actions.kind(target.action.custom) orelse return false;
    const item = actions.item(target.action.custom);
    if (event == .scroll) {
        if (kind == .file) {
            w.sidebar_start = if (event.scroll.delta_y > 0) w.sidebar_start + 1 else w.sidebar_start -| 1;
        } else {
            w.scroll = std.math.clamp(w.scroll + @as(f32, @floatCast(event.scroll.delta_y)) * (if (event.scroll.precise) @as(f32, 1) else 30), 0, w.maximum_scroll);
        }
        return true;
    }
    if (kind == .editor or kind == .search) {
        return Editor.apply(w, event, target);
    }
    if (w.search_prompt.open and (event == .text or event == .key)) {
        return true;
    }
    if (w.model.current().row_count == 0 and event != .pointer and event != .accessibility) {
        if (event == .key and event.key.code == .escape) {
            w.command = .close;
        }
        return true;
    }
    switch (event) {
        .pointer => |pointer| {
            if (pointer.button != .left) {
                return false;
            }
            if (pointer.kind == .press) {
                w.pending_g = false;
                if (kind == .code or kind == .line) {
                    w.finishSearch(true);
                }
            }
            if (kind == .code) {
                if (pointer.kind == .press) {
                    const at = sourceOffset(w, target, pointer.x);
                    w.copy_range = .{ at, at };
                    w.dragging = true;
                    const row = w.model.current().findRow(item) orelse return true;
                    w.model.select(.{ .row = row, .extend = false });
                } else if ((pointer.kind == .drag or pointer.kind == .release) and w.dragging) {
                    const hit = w.widgets.?.dispatcher.maps.presented().at(.{ pointer.x, pointer.y });
                    if (hit) |value| {
                        if (value.id.generation == w.generation and value.action == .custom and actions.kind(value.action.custom) == .code) {
                            w.copy_range.?[1] = sourceOffset(w, value, pointer.x);
                        }
                    }
                    if (pointer.kind == .release) {
                        w.dragging = false;
                    }
                }
                return true;
            }
            if (kind == .line and pointer.kind == .press) {
                const row = w.model.current().findRow(item) orelse return false;
                w.model.select(.{ .row = row, .extend = w.model.visual or pointer.mods & 1 != 0 });
                w.copy_range = null;
                return true;
            }
            if (pointer.kind == .release and target.contains(.{ pointer.x, pointer.y })) {
                activate(w, .{ .kind = kind, .item = item });
                return true;
            }
        },
        .accessibility => |value| {
            if (value.action == .press) {
                activate(w, .{ .kind = kind, .item = item });
                return true;
            }
        },
        .key => |key| {
            if (key.phase == .release) {
                return false;
            }
            if (key.code == .enter and kind == .file) {
                activate(w, .{ .kind = kind, .item = item });
                return true;
            }
            if (key.code == .char and (key.mods.ctrl or key.mods.super)) {
                const ch = key.code.char;
                w.pending_g = false;
                if (w.model.editing == null and ch.len == 1 and key.mods.ctrl and !key.mods.super and !key.mods.alt) {
                    switch (std.ascii.toLower(ch.bytes[0])) {
                        'u', 'd' => |letter| {
                            w.page(if (letter == 'u') -0.5 else 0.5);
                            return true;
                        },
                        'b', 'f' => |letter| {
                            w.page(if (letter == 'b') -1 else 1);
                            return true;
                        },
                        else => {},
                    }
                }
                if (ch.len == 1 and std.ascii.toLower(ch.bytes[0]) == 'c') {
                    try copy(w);
                    return true;
                }
                return false;
            }
            if (w.model.editing != null) {
                return false;
            }
            if (key.code == .up or key.code == .down) {
                w.pending_g = false;
                w.model.move(.{ .delta = if (key.code == .up) -1 else 1, .extend = w.model.visual or key.mods.shift });
                w.reveal = true;
                w.copy_range = null;
                return true;
            }
            if (key.code == .page_down or key.code == .page_up) {
                w.page(if (key.code == .page_up) -1 else 1);
                return true;
            }
            if (key.code == .home or key.code == .end) {
                if (key.code == .home) {
                    w.model.first();
                } else {
                    w.model.last();
                }
                w.pending_g = false;
                w.reveal = true;
                w.copy_range = null;
                return true;
            }
            if (key.code == .escape) {
                if (w.mode == .runtime and !w.pending_g and !w.model.visual and w.model.expanded == null and w.copy_range == null and w.model.search.query.len == 0) {
                    w.command = .close;
                }
                w.pending_g = false;
                w.model.clearSearch();
                w.model.cancelVisual();
                w.copy_range = null;
                w.model.expanded = null;
                return true;
            }
        },
        .text => |text| {
            if (text.phase == .release or w.model.editing != null) {
                return false;
            }
            const previous_g = w.pending_g;
            w.pending_g = false;
            if (text.bytes.len != 1) {
                return false;
            }
            switch (text.bytes[0]) {
                'g' => {
                    if (previous_g) {
                        w.model.first();
                        w.reveal = true;
                        w.copy_range = null;
                    } else {
                        w.pending_g = true;
                    }
                },
                'G' => {
                    w.model.last();
                    w.reveal = true;
                    w.copy_range = null;
                },
                '/' => w.beginSearch(),
                'j', 'k', 'J', 'K' => |ch| {
                    w.model.move(.{ .delta = if (ch == 'j' or ch == 'J') 1 else -1, .extend = w.model.visual or std.ascii.isUpper(ch) });
                    w.reveal = true;
                    w.copy_range = null;
                },
                'v', 'V' => {
                    w.model.toggleVisual();
                    w.copy_range = null;
                    w.reveal = true;
                },
                'n', 'N' => |ch| {
                    if (w.model.search.query.len != 0) {
                        _ = w.model.repeatSearch(if (ch == 'n') .forward else .backward);
                        w.reveal = true;
                        w.copy_range = null;
                    } else {
                        activate(w, .{ .kind = if (ch == 'n') .next else .previous });
                    }
                },
                'p' => activate(w, .{ .kind = .previous }),
                'c' => activate(w, .{ .kind = .comment }),
                't', 'T' => activate(w, .{ .kind = .theme }),
                else => return false,
            }
            return true;
        },
        else => {},
    }
    return false;
}

pub fn activate(w: *Widget, value: struct { kind: actions.Kind, item: usize = 0 }) void {
    if (w.read_only) {
        switch (value.kind) {
            .comment, .line_comment, .edit, .save, .delete, .reviewed => return,
            else => {},
        }
    }
    if (w.model.current().row_count == 0 and value.kind != .close and value.kind != .next_edition and value.kind != .previous_edition and value.kind != .refresh) {
        return;
    }
    w.finishSearch(true);
    w.pending_g = false;
    switch (value.kind) {
        .file => {
            w.model.selectFile(value.item);
            w.resetNavigation();
            w.scroll = 0;
            w.changedOwner();
        },
        .previous, .next => {
            const file = w.model.file;
            w.model.move(.{ .delta = if (value.kind == .previous) -1 else 1, .extend = false, .hunk = true });
            if (w.model.file != file) {
                w.resetNavigation();
                w.scroll = 0;
                w.changedOwner();
            }
            w.reveal = true;
        },
        .line_comment => {
            const anchor = w.model.anchor();
            const selected = value.item >= anchor.first and value.item <= anchor.last and w.model.current().rows[value.item].before() == anchor.before;
            if (!selected) {
                w.model.select(.{ .row = value.item, .extend = false });
            }

            w.model.comment();
            if (w.model.editing) |index| {
                w.noteComment(index);
            }
            w.changedOwner();
        },
        .comment => {
            w.model.comment();
            if (w.model.editing) |index| {
                w.noteComment(index);
            }
            w.changedOwner();
        },
        .save => {
            w.saveComment();
            w.changedOwner();
        },
        .fold => {
            w.model.editing = null;
            w.model.expanded = null;
            w.changedOwner();
        },
        .open_comment, .edit => {
            const comment = &w.model.comments[value.item];
            if (!comment.alive or comment.anchor.revision != w.model.revision) {
                return;
            }
            w.model.visual = false;
            w.model.expanded = value.item;
            w.model.editing = if (!w.read_only and (comment.draft or value.kind == .edit)) value.item else null;
            w.model.head = comment.anchor.last;
            w.model.tail = comment.anchor.first;
            w.changedOwner();
        },
        .delete => {
            w.deleted_comments |= @as(u32, 1) << @as(u5, @intCast(value.item));
            w.changed_comments &= ~(@as(u32, 1) << @as(u5, @intCast(value.item)));
            w.model.comments[value.item].pending = true;
            w.model.comments[value.item].alive = false;
            w.model.editing = null;
            w.model.expanded = null;
            w.changedOwner();
        },
        .submit => {
            if (w.mode != .fixture and (w.delivery == .idle or w.delivery == .pending) and !w.model.available) {
                w.delivery = .queued;
            }
        },
        .close => w.command = .close,
        .previous_edition => w.command = .previous_edition,
        .next_edition => w.command = .next_edition,
        .refresh => w.command = .refresh,
        .simulate => w.model.simulate(),
        .version => {
            w.model.switchRevision();
            w.resetNavigation();
            w.scroll = 0;
            w.changedOwner();
        },
        .reviewed => {
            const file = &w.model.current().files[w.model.file];
            file.reviewed = !file.reviewed;
            if (w.mode == .runtime) {
                const reviewed = file.reviewed;
                for (w.model.current().files[0..w.model.current().file_count]) |*entry| {
                    entry.reviewed = reviewed;
                }
            }
            w.reviewed_changed = true;
        },
        .theme => {
            const themes = std.meta.tags(data.theme_support.Builtin);
            w.theme = themes[(@intFromEnum(w.theme) + 1) % themes.len];
        },
        else => {},
    }
}

fn sourceOffset(w: *Widget, target: Target, x: f64) usize {
    const start = actions.item(target.action.custom);
    const source = w.model.current().source;
    const end = start + (std.mem.indexOfAny(u8, source[start..], "\r\n") orelse source.len - start);
    const wanted = std.math.clamp(x - target.bounds.x, 0, target.bounds.width);
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = source[start..end] };
    var used: f64 = 0;
    var at = start;
    while (iterator.next()) |cluster| {
        const width = @as(f64, @floatFromInt(cluster.width)) * w.cell;
        if (wanted < used + width / 2) {
            break;
        }
        used += width;
        at = start + iterator.index;
    }
    return at;
}

fn copy(w: *Widget) !void {
    const selection = w.copy_range orelse return;
    const first = @min(selection[0], selection[1]);
    const last = @max(selection[0], selection[1]);
    var buffer: [syntax_limits.source_bytes]u8 = undefined;
    var length: usize = 0;
    var started = false;
    const revision = w.model.current();
    const file = revision.files[w.model.file];
    for (revision.rows[file.first..file.last]) |row| {
        if (row.offset + row.value.text.len < first or row.offset > last) {
            continue;
        }
        if (started) {
            buffer[length] = '\n';
            length += 1;
        }
        const start = @max(first, row.offset) - row.offset;
        const end = @min(last, row.offset + row.value.text.len) - row.offset;
        const text = row.value.text[start..end];
        @memcpy(buffer[length..][0..text.len], text);
        length += text.len;
        started = true;
    }
    _ = try w.services().write(buffer[0..length]);
    w.model.status = "Code copy requested.";
}
