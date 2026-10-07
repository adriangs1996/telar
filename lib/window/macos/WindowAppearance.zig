//! Main-thread native decoration and background state. Observers borrow this
//! stable allocation until deinit disconnects them before closing the window.
const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");
const canvas_view = @import("canvas_view.zig");
const Appearance = @import("../Appearance.zig");
const c = @cImport({
    @cInclude("dlfcn.h");
});
const WindowAppearance = @This();
const Observer = objc.Block(struct { owner: *WindowAppearance }, .{objc.c.id}, void);
const StyleMask = @import("StyleMask.zig").StyleMask;
const Material = enum(isize) { under_window = 21 };
const EffectState = enum(isize) { active = 1 };
const Blending = enum(isize) { behind_window = 0 };
const Autoresizing = enum(usize) { width_height = 2 | 16 };
const Title = enum(isize) { visible = 0, hidden = 1 };
const controls_lead: f64 = 14;
const controls_pitch: f64 = 20;
const controls_trail: f64 = 10;
const Connection = *const fn () callconv(.c) ?*anyopaque;
const SetRadius = *const fn (?*anyopaque, usize, c_int) callconv(.c) i32;
extern "c" var NSWindowWillEnterFullScreenNotification: objc.c.id;
extern "c" var NSWindowWillExitFullScreenNotification: objc.c.id;
extern "c" var NSWindowDidEnterFullScreenNotification: objc.c.id;
extern "c" var NSWindowDidExitFullScreenNotification: objc.c.id;
extern "c" var NSWindowDidResizeNotification: objc.c.id;
extern "c" var NSViewFrameDidChangeNotification: objc.c.id;

window: objc.Object,
view: objc.Object,
root: objc.Object,
effect: objc.Object,
observers: [8]?objc.Object = @splat(null),
value: Appearance = .{},
transitioning: bool = false,
changing: bool = false,
connection: ?Connection,
set_radius: ?SetRadius,
applied_radius: ?u8 = null,
applied_window: isize = 0,
applied_style: usize = 0,

pub fn init(window: objc.Object, view: objc.Object) !*WindowAppearance {
    const self = try std.heap.c_allocator.create(WindowAppearance);
    errdefer std.heap.c_allocator.destroy(self);
    const bounds = view.msgSend(appkit.c.CGRect, "bounds", .{});
    const root = objc.getClass("NSView").?.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithFrame:", .{bounds});
    errdefer root.release();
    const effect = objc.getClass("NSVisualEffectView").?.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "initWithFrame:", .{bounds});
    errdefer effect.release();
    if (root.value == null or effect.value == null) {
        return error.BackgroundEffectFailed;
    }

    self.* = .{
        .window = window,
        .view = view,
        .root = root,
        .effect = effect,
        .connection = @ptrCast(@alignCast(c.dlsym(c.RTLD_DEFAULT, "CGSDefaultConnectionForThread"))),
        .set_radius = @ptrCast(@alignCast(c.dlsym(c.RTLD_DEFAULT, "CGSSetWindowBackgroundBlurRadius"))),
    };
    effect.msgSend(void, "setAutoresizingMask:", .{@intFromEnum(Autoresizing.width_height)});
    effect.msgSend(void, "setBlendingMode:", .{@intFromEnum(Blending.behind_window)});
    effect.msgSend(void, "setMaterial:", .{@intFromEnum(Material.under_window)});
    effect.msgSend(void, "setState:", .{@intFromEnum(EffectState.active)});
    effect.msgSend(void, "setHidden:", .{true});
    root.msgSend(void, "addSubview:", .{effect});
    root.msgSend(void, "addSubview:", .{view});
    window.msgSend(void, "setContentView:", .{root});
    _ = window.msgSend(bool, "makeFirstResponder:", .{view});
    const center = objc.getClass("NSNotificationCenter").?.msgSend(objc.Object, "defaultCenter", .{});
    const block = Observer.init(.{ .owner = self }, &changed);
    for ([_]objc.c.id{ NSWindowWillEnterFullScreenNotification, NSWindowWillExitFullScreenNotification, NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification, NSWindowDidResizeNotification }, 0..) |name, i| {
        self.observers[i] = center.msgSend(objc.Object, "addObserverForName:object:queue:usingBlock:", .{ name, window, @as(objc.c.id, null), &block }).retain();
    }
    for (0..3) |i| {
        const button = window.msgSend(objc.Object, "standardWindowButton:", .{i});
        button.msgSend(void, "setPostsFrameChangedNotifications:", .{true});
        self.observers[5 + i] = center.msgSend(objc.Object, "addObserverForName:object:queue:usingBlock:", .{ NSViewFrameDidChangeNotification, button, @as(objc.c.id, null), &block }).retain();
    }
    self.set(.{});
    return self;
}

pub fn deinit(self: *WindowAppearance) void {
    const center = objc.getClass("NSNotificationCenter").?.msgSend(objc.Object, "defaultCenter", .{});
    for (self.observers) |observer| {
        if (observer) |value| {
            center.msgSend(void, "removeObserver:", .{value});
            value.release();
        }
    }
    self.effect.release();
    self.root.release();
    std.heap.c_allocator.destroy(self);
}

/// Called by Window after preparation, and by AppKit after native relayout.
/// Keep alpha on the canvas, never on the window: glyphs remain fully opaque.
pub fn set(self: *WindowAppearance, value: Appearance) void {
    self.value = value;
    if (self.changing) {
        return;
    }
    self.changing = true;
    defer self.changing = false;
    var style = self.window.msgSend(usize, "styleMask", .{});
    if (!self.transitioning and style & @intFromEnum(StyleMask.fullscreen) == 0) {
        const next = if (value.titlebar) style & ~@intFromEnum(StyleMask.full_content) else style | @intFromEnum(StyleMask.full_content);
        if (next != style) {
            const frame = self.window.msgSend(appkit.c.CGRect, "frame", .{});
            const responder = self.window.msgSend(objc.c.id, "firstResponder", .{});
            self.window.msgSend(void, "setStyleMask:", .{next});
            self.window.msgSend(void, "setFrame:display:", .{ frame, true });
            _ = self.window.msgSend(bool, "makeFirstResponder:", .{responder});
            style = next;
        }
        self.window.msgSend(void, "setTitlebarAppearsTransparent:", .{!value.titlebar});
        self.window.msgSend(void, "setTitleVisibility:", .{@intFromEnum(if (value.titlebar) Title.visible else Title.hidden)});
        self.placeControls();
    }
    const is_opaque = value.opacity >= 1;
    const radius = if (is_opaque) 0 else value.blur;
    const number = self.window.msgSend(isize, "windowNumber", .{});
    if (self.applied_radius != radius or self.applied_window != number or self.applied_style != style or self.window.msgSend(bool, "isOpaque", .{}) != is_opaque) {
        self.window.msgSend(void, "setOpaque:", .{is_opaque});
        self.window.msgSend(void, "setBackgroundColor:", .{objc.getClass("NSColor").?.msgSend(objc.Object, "clearColor", .{})});
        self.view.msgSend(objc.Object, "layer", .{}).msgSend(void, "setOpaque:", .{is_opaque});
        var numeric = false;
        if (self.connection) |connection| {
            if (self.set_radius) |set_radius| {
                numeric = number > 0 and set_radius(connection(), @intCast(number), radius) == 0;
            }
        }
        self.effect.msgSend(void, "setHidden:", .{radius == 0 or numeric});
        self.applied_radius = radius;
        self.applied_window = number;
        self.applied_style = style;
        self.window.msgSend(void, "invalidateShadow", .{});
    }
    canvas_view.refreshGeometry(self.view);
}

fn placeControls(self: *WindowAppearance) void {
    if (self.value.titlebar or self.value.navigation == 0) {
        return;
    }
    const scale = appkit.double(self.window, "backingScaleFactor");
    if (scale <= 0) {
        return;
    }
    const height = @as(f64, @floatFromInt(self.value.navigation)) / scale;
    const close = self.window.msgSend(objc.Object, "standardWindowButton:", .{@as(usize, 0)});
    const container = close.msgSend(objc.Object, "superview", .{}).msgSend(objc.Object, "superview", .{});
    if (container.value == null) {
        return;
    }
    var bar = container.msgSend(appkit.c.CGRect, "frame", .{});
    bar.size.height = height;
    bar.origin.y = self.window.msgSend(appkit.c.CGRect, "frame", .{}).size.height - height;
    container.msgSend(void, "setFrame:", .{bar});
    for (0..3) |i| {
        const button = self.window.msgSend(objc.Object, "standardWindowButton:", .{i});
        const frame = button.msgSend(appkit.c.CGRect, "frame", .{});
        button.msgSend(void, "setHidden:", .{false});
        button.msgSend(void, "setFrameOrigin:", .{appkit.c.CGPoint{ .x = controls_lead + @as(f64, @floatFromInt(i)) * controls_pitch, .y = @round((height - frame.size.height) / 2) }});
    }
}

// Notifications cannot call the GUI or draw. They restore window-owned geometry;
// canvas_view publishes any resulting resize for the next loop iteration.
fn changed(block: *const Observer.Context, notification: objc.c.id) callconv(.c) void {
    const self = block.owner;
    const name = objc.Object.fromId(notification).msgSend(objc.c.id, "name", .{});
    if (name == NSWindowWillEnterFullScreenNotification or name == NSWindowWillExitFullScreenNotification) {
        self.transitioning = true;
    } else if (name == NSWindowDidEnterFullScreenNotification or name == NSWindowDidExitFullScreenNotification) {
        self.transitioning = false;
    }
    self.set(self.value);
}

/// Canvas geometry reserves these device pixels only when controls overlap it.
pub fn controlsInset(window: objc.Object) f64 {
    const style = window.msgSend(usize, "styleMask", .{});
    if (style & @intFromEnum(StyleMask.full_content) == 0 or style & @intFromEnum(StyleMask.fullscreen) != 0) {
        return 0;
    }
    const button = window.msgSend(objc.Object, "standardWindowButton:", .{@as(usize, 2)});
    return controls_lead + 2 * controls_pitch + button.msgSend(appkit.c.CGRect, "frame", .{}).size.width + controls_trail;
}
