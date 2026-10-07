//! The window's view state: what only makes sense while someone looks at
//! this window and holds no host resource. Widgets, chrome and overlays,
//! the pointer and its gesture owners, the key router and its bindings,
//! the sidebar width, focus, the cursor blink and the native input waiting
//! to be routed. `GuiAdapter` keeps it beside the host resources and the
//! clients; a procedure that touches only it takes `model: *WindowModel`.

const keyinput = @import("keyinput");
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const pointer_owner = @import("input/pointer_owner.zig");
const Window = @import("telar-window");
const InputQueue = @import("InputQueue.zig");
const Geometry = @import("input/PointerGeometry.zig");
const PointerHover = @import("input/PointerHover.zig");
const Hit = @import("input/LinkHit.zig");
const PointerSample = @import("input/PointerSample.zig");
const TerminalClipboard = @import("host/TerminalClipboard.zig");
const State = @import("widgets/interaction/State.zig");
const Chrome = @import("widgets/Chrome.zig");
const Overlays = @import("widgets/overlays/Overlays.zig");
const SidebarPreference = @import("SidebarPreference.zig");
const CursorClock = @import("CursorClock.zig");
const PointerEvent = @FieldType(Window.Input, "pointer");
const WindowModel = @This();

input_queue: InputQueue = .{},
input_revision: u64 = 0,
/// The input revision the cursor blink last restarted at.
observed_input_revision: u64 = 0,
router: client.key_router.Type,
binding_revision: u64 = 0,
pointer: PointerState = .{},
terminal_clipboard: TerminalClipboard = .{},
paste_route: enum { shared, widget } = .shared,
recovery_interactions_finished: bool = false,
focused: bool = true,
cursor_clock: CursorClock = .{},
widgets: State = .{},
chrome: Chrome = .{},
/// The sidebar band width preference; the shared model keeps only visibility.
sidebar: SidebarPreference = .{},
overlays: Overlays = .{},

/// Builds the view state in its final address: the overlays borrow the
/// router beside them.
/// Example: `try gui.model.init(gpa, options);`
pub fn init(self: *WindowModel, gpa: std.mem.Allocator, options: client.Options) !void {
    const router = try client.key_router.build(
        .{
            .prefix = options.prefix,
            .bindings = options.bindings,
            .sequence_timeout_ns = options.input_sequence_timeout_ns,
        },
    );

    self.* = .{
        .router = router,
        .cursor_clock = .{
            .config = options.gui.cursor,
        },
        .sidebar = .init(options.gui.sidebar.width),
    };
    self.overlays.router = &self.router;
    try self.input_queue.init(gpa);
}

/// Example: `gui.model.deinit(gpa);`
pub fn deinit(self: *WindowModel, gpa: std.mem.Allocator) void {
    self.input_queue.deinit(gpa);
    self.chrome.favicons.deinit(gpa);
}

/// Native geometry admission plus independent bounded gesture owners.
const PointerState = struct {
    geometry: Geometry = .{},
    revision: u64 = 0,
    gesture_revision: u64 = 0,
    scroll_remainder: f64 = 0,
    owners: [3]pointer_owner.Owner = @splat(.shared),
    last: [3]keyinput.Mouse = @splat(.{
        .x = 0,
        .y = 0,
        .kind = .release,
    }),
    hover: PointerHover = .{},
    link_gesture: LinkGesture = .{},

    /// Example: `pointer.configure(origin, size);`
    pub fn configure(self: *PointerState, origin: [2]u32, size: core.TerminalSize) void {
        const candidate: Geometry = .{ .origin = origin, .size = size };
        if (!std.meta.eql(self.geometry, candidate)) {
            self.geometry = candidate;
            self.revision +%= 1;
            self.hover.dirty = true;
            self.link_gesture.cancel();
        }
    }

    /// Example: `const sample = pointer.sample(event);`
    pub fn sample(self: *const PointerState, event: PointerEvent) PointerSample {
        return .{ .event = event, .geometry_revision = self.revision, .gesture_revision = self.gesture_revision };
    }

    /// Invalidates queued gesture starts while an ordered cancellation waits for
    /// transport capacity. Example: `pointer.invalidateGestures();`
    pub fn invalidateGestures(self: *PointerState) void {
        self.gesture_revision +%= 1;
    }
};

/// A native link opens on release; dragging or changed identity cancels it.
const LinkGesture = struct {
    pressed: ?Hit = null,
    version: data.Version = .{},

    /// Acquires the complete gesture without dispatching an external operation.
    /// Example: `gesture.begin(hit, app.model.version());`
    pub fn begin(self: *LinkGesture, hit: Hit, version: data.Version) void {
        self.pressed = hit;
        self.version = version;
    }

    /// A release opens only the unchanged target, returned with the pane it
    /// was printed in. Cancellation never opens a URL.
    /// Example: `const hit = gesture.finish(current_hit, app.model.version());`
    pub fn finish(self: *LinkGesture, current: ?Hit, version: data.Version) ?Hit {
        self.validate(current, version);
        const pressed = self.pressed orelse return null;
        self.pressed = null;
        const released = current orelse return null;
        return if (pressed.eql(&released)) pressed else null;
    }

    /// Navigation or an intervening target change cancels, even if later restored.
    /// Example: `gesture.validate(hover.link, app.model.version());`
    pub fn validate(self: *LinkGesture, current: ?Hit, version: data.Version) void {
        const pressed = self.pressed orelse return;
        const same_context = self.version.workspace == version.workspace and self.version.active_tab == version.active_tab and
            self.version.tabs == version.tabs and self.version.panes == version.panes and self.version.host == version.host and
            self.version.configuration == version.configuration and self.version.viewport == version.viewport;
        const same_target = if (current) |hit| pressed.eql(&hit) else false;
        if (!same_context or !same_target) {
            self.cancel();
        }
    }

    pub fn cancel(self: *LinkGesture) void {
        self.pressed = null;
    }
};
