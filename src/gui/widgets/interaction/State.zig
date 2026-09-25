//! Presentation-owned targets plus client-owned transient editor state.
const Registry = @import("Registry.zig");
const native = @import("../../native/native.zig");
const labels = @import("labels.zig");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const GenericPresentedState = @import("../../render/GenericPresentedState.zig").Type;
const Dispatcher = @import("Dispatcher.zig");
const Geometry = @import("EditorGeometry.zig");
const Preedit = @import("Preedit.zig");
const Target = @import("Target.zig");
const Id = @import("Id.zig");
const CopyFeedback = @import("../CopyFeedback.zig");
const TabDropSlots = @import("TabDropSlots.zig");
const TabMotions = @import("../TabMotions.zig");
const PasteBuffer = @import("PasteBuffer.zig");
const PendingCut = @import("PendingCut.zig");
const PendingPaste = @import("PendingPaste.zig");
const ChromeRegistration = @import("ChromeRegistration.zig");
const Overlays = @import("../overlays/Overlays.zig");
const TabMoveIntent = ?client.TabMoveIntent;

const State = @This();

dispatcher: Dispatcher = .{},
copy_feedback: CopyFeedback = .{},
tab_drag: client.TabDrag = .{},
tab_drag_step: f64 = 4,
tab_drop_slots: TabDropSlots = .{},
tab_motions: TabMotions = .{},
tab_pointer: [2]f64 = .{ 0, 0 },
tab_grab_offset: f64 = 0,
tab_drop_pending: TabMoveIntent = null,
editors: GenericPresentedState(Editors) = .{},
preedit: Preedit = .{},
prompt_generation: u64 = 0,
paste_owner: ?Id = null,
paste_consumed: bool = false,
paste_buffer: PasteBuffer = .{},
paste_selection: [2]u32 = .{ 0, 0 },
paste_revision: u64 = 0,
directory_scroll_remainder: f64 = 0,
history_scroll_remainder: f64 = 0,
history_scroll_generation: u64 = 0,
history_scroll_inspecting: bool = false,
native_nodes: [Registry.capacity]native.AccessibilityNode = undefined,
pending_cuts: [4]?PendingCut = @splat(null),
pending_pastes: [4]?PendingPaste = @splat(null),

/// Cancelling provisional text changes pixels even when committed text and
/// selection stay untouched. Example: `state.cancelComposition();`
pub fn cancelComposition(self: *State) void {
    if (self.preedit.owner != null) {
        self.preedit.clear();
        self.dispatcher.revision +%= 1;
    }
}

/// Example: `state.begin(projection.prompt != null);`
pub fn begin(self: *State, modal: bool) void {
    self.dispatcher.begin().modal_layer = if (modal) 1 else 0;
    _ = self.editors.begin();
}

/// Imports existing chrome's semantic controls with their exact rectangles.
/// Example: `try state.chrome(canvas, &chrome);`
pub fn chrome(self: *State, canvas: *Canvas, input: ChromeRegistration) !void {
    self.tab_drag_step = canvas.chrome.px(4);
    const value = input.chrome;
    if (value.prepared().bands.sidebar.width > 0) {
        _ = try self.dispatcher.add((Target{ .bounds = value.prepared().bands.sidebar, .action = .{ .custom = 1 }, .namespace = 1, .focusable = false, .role = 6 }).labelled("Agents"));
    }

    for (value.prepared().band_hits.items[0..value.prepared().band_hits.len]) |hit| {
        const action: Target.Action = switch (hit.action) {
            .intent => |intent| if (intent == .none) continue else .{ .intent = intent },
            .resize_sidebar => .resize_sidebar,
            .pane_content => continue,
        };
        const target: Target = .{ .bounds = hit.area, .action = action, .focusable = action != .resize_sidebar };
        _ = try self.dispatcher.add(target.labelled(labels.forAction(input.projection, action)));
    }

    if (self.dispatcher.focused) |id| {
        if (self.dispatcher.maps.prepared().find(id)) |target| {
            if (target.action != .text_field and self.dispatcher.maps.prepared().modal_layer == 0) {
                try canvas.ringAt(target.bounds, .{ .color = canvas.theme.palette.accent, .width = 1, .radius = 4 });
            }
        }
    }
}

/// Imports modal result rows after their field, preserving painter priority.
/// Example: `try state.overlays(canvas, &overlays);`
pub fn overlays(self: *State, canvas: *Canvas, value: *Overlays) !void {
    const notifications = &value.prepared().notifications;
    for (notifications.hits[0..notifications.count]) |hit| {
        _ = try self.dispatcher.add(hit);
    }

    const palette = &value.prepared().palette;
    for (palette.rows[0..palette.count], 0..) |row, index| {
        _ = try self.dispatcher.add(.{ .id = .{ .generation = self.prompt_generation }, .bounds = canvas.rect(row), .action = .{ .intent = .{ .prompt_row = palette.first + @as(u16, @intCast(index)) } }, .layer = 1, .focusable = false });
    }
}

/// Example: `state.seal();`
pub fn seal(self: *State) void {
    self.dispatcher.seal();
    self.editors.seal();
}

/// Example: `state.present(delivered);`
pub fn present(self: *State, delivered: bool) void {
    self.dispatcher.present(delivered);
    self.editors.present(delivered);
    if (!delivered) {
        return;
    }

    for (self.editors.presented().items[0..self.editors.presented().len]) |editor| {
        if (editor.preferred) {
            _ = self.dispatcher.focus(editor.id);
            break;
        }
    }

    if (self.preedit.owner) |owner| {
        if (self.dispatcher.focused == null or !self.dispatcher.focused.?.eql(owner)) {
            self.preedit.clear();
        }
    }
}

const Editors = struct {
    pub const capacity = 16;
    items: [capacity]Geometry = undefined,
    len: usize = 0,

    /// Example: `try editors.add(geometry);`
    pub fn add(self: *Editors, geometry: Geometry) !void {
        if (self.len == capacity) {
            return error.WidgetEditorCapacityExceeded;
        }

        self.items[self.len] = geometry;
        self.len += 1;
    }

    /// Example: `const geometry = editors.find(target.id) orelse return;`
    pub fn find(self: *const Editors, id: Id) ?Geometry {
        for (self.items[0..self.len]) |item| {
            if (item.id.eql(id)) {
                return item;
            }
        }

        return null;
    }
};
