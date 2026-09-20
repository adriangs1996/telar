//! Reusable native change-review surface. Runtime and experiments supply editions.
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("../widgets/Canvas.zig");
const State = @import("../widgets/interaction/State.zig");
const Route = @import("../widgets/interaction/Route.zig");
const Event = @import("../input/event.zig").Event;
const Key = @import("../input/KeyInput.zig");
const native = @import("../native/native.zig");
const Services = @import("../host/Services.zig");
const syntax_limits = @import("../syntax/limits.zig");
const Model = @import("telar-client").ChangeReviewModel;
const Paint = @import("Paint.zig");
const Input = @import("input.zig");
const Editor = @import("editor.zig");
const actions = @import("action.zig");
const Self = @This();

host: Services = .{},
host_port: ?*Services = null,
layer: u8 = 0,
mode: enum { fixture, external, runtime } = .fixture,
command: ?enum { close, previous_edition, next_edition, refresh } = null,
changed_comments: u32 = 0,
deleted_comments: u32 = 0,
reviewed_changed: bool = false,
theme_override: ?client.ColorTheme = null,
edition_id: u64 = 1,
source_label: []const u8 = "",
previous_edition: bool = false,
next_edition: bool = false,
loading: bool = false,
read_only: bool = false,
delivery: enum { idle, queued, pending, sending, sent, failed } = .idle,
live_status: [320]u8 = undefined,
model: Model = .{},
roles: [2][syntax_limits.source_bytes]client.SyntaxRole = undefined,
theme: client.theme_support.Builtin = .shade,
widgets: ?*State = null,
generation: u64 = 1,
text_revision: u64 = 1,
scroll: f32 = 0,
maximum_scroll: f32 = 0,
sidebar_start: usize = 0,
reveal: bool = true,
needs_focus: bool = false,
prepared_cell: f32 = 1,
cell: f32 = 1,
copy_range: ?[2]usize = null,
dragging: bool = false,
clipboard_id: ?u64 = null,
clipboard_revision: u64 = 0,
clipboard_selection: [2]u32 = .{ 0, 0 },
clipboard_cut: bool = false,

pub fn services(self: *Self) *Services {
    return self.host_port orelse &self.host;
}

pub fn noteComment(self: *Self, index: usize) void {
    self.changed_comments |= @as(u32, 1) << @as(u5, @intCast(index));
}

pub fn saveComment(self: *Self) void {
    const index = self.model.editing orelse return;
    self.model.save();
    self.noteComment(index);
}

pub fn draw(self: *Self, canvas: *Canvas) !void {
    self.widgets = canvas.widgets;
    self.prepared_cell = @floatFromInt(canvas.metrics.cell_width);
    var paint: Paint = .{ .widget = self, .canvas = canvas };
    try paint.draw();
}

pub fn input(self: *Self, event: Event, route: Route) !bool {
    return Input.apply(self, event, route);
}

/// Escape cancels preedit or folds a draft before generic focus traversal.
/// Example: `if (widget.ownsKey(key)) dispatcher.editorKey(key);`
pub fn ownsKey(self: *const Self, key: Key) bool {
    const state = self.widgets orelse return false;
    const target = state.dispatcher.focusedTarget() orelse return false;
    return key.code == .escape and target.id.generation == self.generation;
}

/// Retires old native editor identities when changing the draft or revision.
/// Example: `widget.changedOwner();`
pub fn changedOwner(self: *Self) void {
    self.generation += 1;
    self.needs_focus = true;
    self.reveal = true;
    self.copy_range = null;
    self.dragging = false;
    if (self.widgets) |state| {
        state.cancelComposition();
    }
}

/// Focus requests wait for successful delivery of their editor geometry.
/// Example: `widget.present(delivered);`
pub fn present(self: *Self, delivered: bool) void {
    if (!delivered) {
        return;
    }

    self.cell = self.prepared_cell;
    if (!self.needs_focus) {
        return;
    }

    const state = self.widgets orelse return;
    const desired: actions.Kind = if (self.model.editing != null) .editor else .background;
    const registry = state.dispatcher.maps.presented();
    for (registry.targets[0..registry.len]) |target| {
        if (target.id.generation == self.generation and target.action == .custom and actions.kind(target.action.custom) == desired) {
            _ = state.dispatcher.focus(target.id);
            self.needs_focus = false;
            return;
        }
    }
}

pub fn textContext(self: *Self, out: *native.TextContext) bool {
    return Editor.context(self, out);
}

pub fn accessibility(self: *Self, out: *native.AccessibilityTree) bool {
    const state = self.widgets orelse return false;
    const registry = state.dispatcher.maps.presented();
    var count: usize = 0;
    for (registry.targets[0..registry.len]) |*target| {
        if (target.id.generation != self.generation or target.label_len == 0) {
            continue;
        }

        state.native_nodes[count] = .{ .id = target.id.target_id, .generation = target.id.generation, .role = target.role, .flags = 1, .actions = 1 | 2, .x = target.bounds.x, .y = target.bounds.y, .width = target.bounds.width, .height = target.bounds.height, .label = &target.label, .label_len = target.label_len };
        if (target.action == .custom and actions.kind(target.action.custom) == .editor and self.model.editing != null) {
            const field = &self.model.comments[self.model.editing.?].body;
            const node = &state.native_nodes[count];
            node.flags |= 8;
            node.actions |= 4 | 8 | 64 | 128 | 256 | 512;
            node.value = field.text().ptr;
            node.value_len = field.len;
            node.selection_start = @intCast(field.anchor);
            node.selection_end = @intCast(field.head);
            node.text_revision = self.text_revision;
        }
        count += 1;
    }

    out.* = .{ .revision = self.text_revision +% state.dispatcher.revision, .nodes = &state.native_nodes, .count = @intCast(count) };
    return true;
}
