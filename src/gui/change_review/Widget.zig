//! Reusable native change-review surface. Runtime and experiments supply editions.
const syntaxhl = @import("syntaxhl");
const data = @import("model");
const event_module = @import("../input/event.zig");
const std = @import("std");
const client = @import("telar-client");
const Canvas = @import("../widgets/Canvas.zig");
const State = @import("../widgets/interaction/State.zig");
const Route = @import("../widgets/interaction/Route.zig");
const Key = @import("../input/KeyInput.zig");
const native = @import("../native/native.zig");
const Services = @import("../host/Services.zig");
const Paint = @import("Paint.zig");
const Input = @import("input.zig");
const Editor = @import("editor.zig");
const actions = @import("action.zig");
const SearchPrompt = @import("SearchPrompt.zig");
const Self = @This();

host: Services = .{},
host_port: ?*Services = null,
layer: u8 = 0,
mode: enum { fixture, external, runtime } = .fixture,
command: ?enum { close, previous_edition, next_edition, refresh } = null,
changed_comments: u32 = 0,
deleted_comments: u32 = 0,
reviewed_changed: bool = false,
theme_override: ?data.ColorTheme = null,
edition_id: u64 = 1,
source_label: []const u8 = "",
previous_edition: bool = false,
next_edition: bool = false,
loading: bool = false,
read_only: bool = false,
delivery: enum { idle, queued, pending, sending, sent, failed } = .idle,
live_status: [320]u8 = undefined,
model: client.ChangeReviewModel = .{},
/// Borrowed roles of each revision's source, one per byte, owned by whoever
/// owns that source (the panel's visible edition slot). Shorter roles than
/// the source paint it plain.
roles: [2][]const syntaxhl.Role = @splat(&.{}),
theme: data.theme_support.Builtin = .shade,
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
search_prompt: SearchPrompt = .{},
pending_g: bool = false,
prepared_viewport: Viewport = .{},
viewport: Viewport = .{},

/// Uses the native field machinery for both search and review comments.
/// Example: `const field = widget.activeField() orelse return;`
pub fn activeField(self: *Self) ?*SearchPrompt.Field {
    if (self.search_prompt.open) {
        return &self.search_prompt.field;
    }

    const index = self.model.editing orelse return null;
    return &self.model.comments[index].body;
}

/// Updates only the owner of the currently edited field.
/// Example: `widget.fieldChanged();`
pub fn fieldChanged(self: *Self) void {
    if (self.search_prompt.open) {
        self.search_prompt.failure = null;
        self.previewSearch();
    } else if (self.model.editing) |index| {
        self.model.comments[index].draft = true;
        self.noteComment(index);
    }
    self.text_revision += 1;
}

/// Starts an incremental search without discarding the previous position/query.
/// Example: `widget.beginSearch();`
pub fn beginSearch(self: *Self) void {
    if (self.model.editing != null or self.search_prompt.open) {
        return;
    }

    self.search_prompt = .{ .open = true, .previous = self.model.search, .head = self.model.head, .tail = self.model.tail, .visual = self.model.visual, .scroll = self.scroll };
    self.model.clearSearch();
    self.changedOwner();
    self.reveal = false;
}

fn previewSearch(self: *Self) void {
    self.model.head = self.search_prompt.head;
    self.model.tail = self.search_prompt.tail;
    self.model.visual = self.search_prompt.visual;
    _ = self.model.startSearch(self.search_prompt.field.text());
    self.scroll = self.search_prompt.scroll;
    self.reveal = self.model.search.match != null;
}

/// Confirms a query or restores the position and query from before `/`.
/// Example: `widget.finishSearch(false);`
pub fn finishSearch(self: *Self, accept: bool) void {
    if (!self.search_prompt.open) {
        return;
    }

    if (!accept) {
        self.model.head = self.search_prompt.head;
        self.model.tail = self.search_prompt.tail;
        self.model.visual = self.search_prompt.visual;
        self.scroll = self.search_prompt.scroll;
        self.model.search = self.search_prompt.previous;
    }
    self.search_prompt.open = false;
    // Closing retires the search action through activeField/ownsField while
    // keeping any code-selection gesture attached to its delivered target.
    self.refocus();
    self.reveal = accept and self.model.search.match != null;
}

/// Invalidates view-local input when replacing the displayed file or edition.
/// Example: `widget.resetNavigation();`
pub fn resetNavigation(self: *Self) void {
    self.search_prompt = .{};
    self.model.clearSearch();
    self.pending_g = false;
}

/// Scrolls a delivered page fraction and moves the review cursor with it.
/// Example: `widget.page(0.5);`
pub fn page(self: *Self, fraction: f32) void {
    if (self.viewport.generation != self.generation or self.viewport.file != self.model.file) {
        return;
    }

    const reached = self.viewport.move(&self.model, .{ .fraction = fraction, .scroll = self.scroll });
    self.scroll = std.math.clamp(self.scroll + self.viewport.height * fraction, 0, self.viewport.maximum_scroll);
    self.reveal = self.model.visual and !reached;
    self.copy_range = null;
    self.pending_g = false;
}

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

pub fn input(self: *Self, event: event_module.Event, route: Route) !bool {
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
    self.refocus();
}

fn refocus(self: *Self) void {
    self.needs_focus = true;
    self.reveal = true;
    self.copy_range = null;
    self.dragging = false;
    self.pending_g = false;
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
    self.viewport = self.prepared_viewport;
    if (!self.needs_focus) {
        return;
    }

    const state = self.widgets orelse return;
    const desired: actions.Kind = if (self.search_prompt.open) .search else if (self.model.editing != null) .editor else .background;
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
    state.accessibility_dropped = 0;
    for (registry.targets[0..registry.len]) |*target| {
        if (target.id.generation != self.generation or target.label_len == 0) {
            continue;
        }

        if (count == state.native_nodes.len) {
            state.accessibility_dropped += 1;
            continue;
        }

        state.native_nodes[count] = .{ .id = target.id.target_id, .generation = target.id.generation, .role = target.role, .flags = 1, .actions = 1 | 2, .x = target.bounds.x, .y = target.bounds.y, .width = target.bounds.width, .height = target.bounds.height, .label = &target.label, .label_len = target.label_len };
        if (target.action == .custom and (actions.kind(target.action.custom) == .editor or actions.kind(target.action.custom) == .search) and self.activeField() != null) {
            const field = self.activeField().?;
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

/// Delivered row positions keep page motions proportional to the visible diff,
/// including wrapped code and inline comments.
const Viewport = struct {
    const row_capacity = @typeInfo(@FieldType(client.ChangeReviewRevision, "rows")).array.len;

    height: f32 = 0,
    line_height: f32 = 1,
    maximum_scroll: f32 = 0,
    starts: [row_capacity]f32 = @splat(0),
    ends: [row_capacity]f32 = @splat(0),
    generation: u64 = 0,
    file: usize = 0,

    /// Moves through selectable rows toward a visible pixel position. Returns false
    /// at a file or visual boundary; wrapped fragments can keep the same logical row.
    /// Example: `_ = viewport.move(&model, .{ .fraction = 0.5, .scroll = scroll });`
    pub fn move(self: *const Viewport, model: *client.ChangeReviewModel, request: struct { fraction: f32, scroll: f32 }) bool {
        const start = std.math.clamp(self.starts[model.head], request.scroll, request.scroll + @max(0, self.height - self.line_height));
        const destination = start + self.height * request.fraction;
        model.search.match = null;
        while (true) {
            if (destination >= self.starts[model.head] and destination < self.ends[model.head]) {
                return true;
            }

            const previous = model.head;
            model.move(.{ .delta = if (request.fraction < 0) -1 else 1, .extend = model.visual });
            if (model.head == previous) {
                return false;
            }
            if ((request.fraction > 0 and self.starts[model.head] >= destination) or (request.fraction < 0 and self.ends[model.head] <= destination)) {
                return true;
            }
        }
    }
};
