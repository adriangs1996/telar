const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");
const text_input = @import("text_input.zig");
const pointer_input = @import("pointer_input.zig");
const accessibility = @import("accessibility.zig");
const input_receiver = @import("InputReceiver.zig");
const InputReceiver = input_receiver.InputReceiver;
const WindowAppearance = @import("WindowAppearance.zig");
const HostState = @import("../HostState.zig");
const native = @import("../native.zig");
const c = native.c;
const Id = objc.c.id;
const Sel = objc.c.SEL;
const Object = objc.Object;
const Autoresizing = enum(usize) { width = 2, height = 16 };
const Kind = enum(u32) { focus = 5 };
const Focus = enum(u32) { inactive = 0, active = 1 };
extern "c" var NSWindowDidBecomeKeyNotification: Id;
extern "c" var NSWindowDidResignKeyNotification: Id;
extern "c" var NSWindowDidChangeScreenNotification: Id;
extern "c" var NSWindowDidChangeOcclusionStateNotification: Id;
extern "c" var NSApplicationDidChangeScreenParametersNotification: Id;
extern "c" var NSAccessibilityGroupRole: Id;

// AppKit owns the native view; MacosWindow owns the borrowed event queue.
// stop disconnects native sources before MacosWindow destroys that queue.
const Canvas = struct {
    host: ?*HostState = null,
    accessibility: Id = null,
    stopped: bool = false,
};
var offset: usize = 0;
var registered: ?objc.Class = null;

/// Create the sole NSView subclass used by MacosWindow. Text, pointer and window
/// events install methods on this class; they are separate flows, not superclasses.
pub fn create(host: *HostState) !Object {
    const class = try register();
    const allocated = class.msgSend(Object, "alloc", .{});
    const receiver: InputReceiver = .{ .context = host, .receive = receive };
    const raw = allocated.msgSend(Id, "initWithFrame:receiver:", .{ std.mem.zeroes(appkit.c.CGRect), receiver });
    if (raw == null) {
        return error.NativeViewInitializationFailed;
    }

    state(raw).?.host = host;
    return Object.fromId(raw);
}

fn register() !objc.Class {
    if (registered) |class| {
        return class;
    }

    try accessibility.install();
    const class = objc.allocateClassPair(objc.getClass("NSView").?, "TelarCanvasView") orelse return error.NativeClassRegistrationFailed;
    errdefer objc.disposeClassPair(class);
    offset = try appkit.addStorage(class, "telar_canvas");
    try text_input.install(class);
    try pointer_input.install(class);
    try appkit.method(class, "initWithFrame:receiver:", initialize);
    try appkit.method(class, "dealloc", deallocate);
    try appkit.method(class, "sendInput:", sendInput);
    try appkit.method(class, "stopInput", stopInput);
    try appkit.method(class, "stop", stop);
    try appkit.method(class, "viewDidMoveToWindow", movedToWindow);
    try appkit.method(class, "setFrameSize:", setFrameSize);
    try appkit.method(class, "viewDidChangeBackingProperties", backingChanged);
    try appkit.method(class, "wantsUpdateLayer", wantsUpdateLayer);
    try appkit.method(class, "updateLayer", updateLayer);
    try appkit.method(class, "invalidated:", invalidated);
    try appkit.method(class, "screenChanged:", screenChanged);
    try appkit.method(class, "focused:", focused);
    try appkit.method(class, "unfocused:", unfocused);
    try appkit.method(class, "setAccessibilityTree:", setAccessibility);
    try appkit.method(class, "accessibilityRole", accessibilityRole);
    try appkit.method(class, "accessibilityLabel", accessibilityLabel);
    try appkit.method(class, "accessibilityChildren", accessibilityChildren);
    try appkit.method(class, "accessibilityFocusedUIElement", accessibilityFocus);
    try appkit.method(class, "accessibilityHitTest:", accessibilityHitTest);
    objc.registerClassPair(class);
    registered = class;
    return class;
}

fn state(raw: Id) ?*Canvas {
    return appkit.storage(Canvas, raw, offset).*;
}

fn initialize(raw: Id, _: Sel, frame: appkit.c.CGRect, receiver: InputReceiver) callconv(.c) Id {
    const view = Object.fromId(raw).msgSendSuper(objc.getClass("NSView").?, Id, "initWithFrame:", .{frame});
    if (view == null) {
        return null;
    }

    const canvas = std.heap.c_allocator.create(Canvas) catch {
        Object.fromId(view).release();
        return null;
    };
    canvas.* = .{};
    appkit.storage(Canvas, view, offset).* = canvas;
    text_input.init(view, receiver) catch {
        Object.fromId(view).release();
        return null;
    };
    pointer_input.init(view) catch {
        Object.fromId(view).release();
        return null;
    };
    canvas.accessibility = objc.getClass("TelarAccessibility").?.msgSend(Object, "alloc", .{}).msgSend(Id, "initWithView:receiver:", .{ view, receiver });
    if (canvas.accessibility == null) {
        Object.fromId(view).release();
        return null;
    }

    Object.fromId(view).msgSend(void, "setAutoresizingMask:", .{@intFromEnum(Autoresizing.width) | @intFromEnum(Autoresizing.height)});
    return view;
}

fn deallocate(raw: Id, selector: Sel) callconv(.c) void {
    stop(raw, selector);
    pointer_input.deinit(raw);
    text_input.deinit(raw);
    if (state(raw)) |canvas| {
        Object.fromId(canvas.accessibility).release();
        std.heap.c_allocator.destroy(canvas);
        appkit.storage(Canvas, raw, offset).* = null;
    }

    Object.fromId(raw).msgSendSuper(objc.getClass("NSView").?, void, "dealloc", .{});
}

fn receive(context: *anyopaque, value: c.telar_gui_input) callconv(.c) bool {
    const host: *HostState = @ptrCast(@alignCast(context));
    return host.receive(value);
}

fn sendInput(raw: Id, _: Sel, value: c.telar_gui_input) callconv(.c) bool {
    const canvas = state(raw) orelse return false;
    if (canvas.stopped) {
        return false;
    }

    const accepted = text_input.receive(raw, value);
    pointer_input.refresh(raw);
    return accepted;
}

fn stopInput(raw: Id, _: Sel) callconv(.c) void {
    pointer_input.stop(raw);
    text_input.stop(raw);
}

fn center() Object {
    return objc.getClass("NSNotificationCenter").?.msgSend(Object, "defaultCenter", .{});
}

// Frame/backing/screen callbacks coalesce native values in HostState. They never
// run the GUI update or submit a GPU frame; the Zig loop consumes the next event.
fn geometryChanged(raw: Id) void {
    const canvas = state(raw) orelse return;
    const host = canvas.host orelse return;
    const view = Object.fromId(raw);
    const window = view.msgSend(Object, "window", .{});
    if (canvas.stopped or window.value == null) {
        return;
    }

    const pixels = view.msgSend(appkit.c.CGRect, "convertRectToBacking:", .{view.msgSend(appkit.c.CGRect, "bounds", .{})});
    if (pixels.size.width >= 1 and pixels.size.height >= 1 and pixels.size.width <= std.math.maxInt(u32) and pixels.size.height <= std.math.maxInt(u32)) {
        host.resize(.{
            .width = @intFromFloat(pixels.size.width),
            .height = @intFromFloat(pixels.size.height),
            .scale = @floatCast(appkit.double(window, "backingScaleFactor")),
            .controls = @intFromFloat(@ceil(WindowAppearance.controlsInset(window) * appkit.double(window, "backingScaleFactor"))),
        });
    }

    const rate = window.msgSend(Object, "screen", .{}).msgSend(isize, "maximumFramesPerSecond", .{});
    if (rate > 0) {
        host.displayInterval(std.time.ns_per_s / @as(u64, @intCast(rate)));
    }
}

// Rebind observers whenever AppKit attaches or detaches the view. Removing the
// old registrations prevents events from a former window reaching this queue.
fn movedToWindow(raw: Id, _: Sel) callconv(.c) void {
    const view = Object.fromId(raw);
    view.msgSendSuper(objc.getClass("NSView").?, void, "viewDidMoveToWindow", .{});
    const notifications = center();
    notifications.msgSend(void, "removeObserver:", .{raw});
    const canvas = state(raw) orelse return;
    const window = view.msgSend(Id, "window", .{});
    if (canvas.stopped or canvas.host == null or window == null) {
        return;
    }

    const names = [_]Id{ NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification, NSWindowDidChangeScreenNotification, NSWindowDidChangeOcclusionStateNotification, NSApplicationDidChangeScreenParametersNotification };
    inline for (.{ "focused:", "unfocused:", "screenChanged:", "invalidated:", "screenChanged:" }, 0..) |selector, index| {
        notifications.msgSend(void, "addObserver:selector:name:object:", .{ raw, objc.sel(selector), names[index], if (names[index] == NSApplicationDidChangeScreenParametersNotification) @as(Id, null) else window });
    }

    geometryChanged(raw);
}

fn setFrameSize(raw: Id, _: Sel, size: appkit.c.CGSize) callconv(.c) void {
    Object.fromId(raw).msgSendSuper(objc.getClass("NSView").?, void, "setFrameSize:", .{size});
    geometryChanged(raw);
}

fn backingChanged(raw: Id, _: Sel) callconv(.c) void {
    Object.fromId(raw).msgSendSuper(objc.getClass("NSView").?, void, "viewDidChangeBackingProperties", .{});
    geometryChanged(raw);
}

fn wantsUpdateLayer(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

// AppKit's layer invalidation only wakes the loop; Surface owns presentation.
fn updateLayer(raw: Id, _: Sel) callconv(.c) void {
    const canvas = state(raw) orelse return;
    if (canvas.host) |host| {
        host.wake_pending = true;
    }
}

fn invalidated(raw: Id, selector: Sel, _: Id) callconv(.c) void {
    updateLayer(raw, selector);
}

fn screenChanged(raw: Id, _: Sel, _: Id) callconv(.c) void {
    geometryChanged(raw);
}

fn focused(raw: Id, selector: Sel, _: Id) callconv(.c) void {
    const canvas = state(raw) orelse return;
    if (canvas.stopped) {
        return;
    }

    _ = sendInput(raw, selector, std.mem.zeroInit(c.telar_gui_input, .{ .kind = @intFromEnum(Kind.focus), .code = @intFromEnum(Focus.active) }));
    pointer_input.restore(raw);
}

fn unfocused(raw: Id, selector: Sel, _: Id) callconv(.c) void {
    const canvas = state(raw) orelse return;
    if (canvas.stopped) {
        return;
    }

    text_input.releasePressedKeys(raw, selector);
    pointer_input.reset(raw);
    _ = sendInput(raw, selector, std.mem.zeroInit(c.telar_gui_input, .{ .kind = @intFromEnum(Kind.focus), .code = @intFromEnum(Focus.inactive) }));
}

fn setAccessibility(raw: Id, _: Sel, tree: c.telar_gui_accessibility_tree) callconv(.c) void {
    const canvas = state(raw) orelse return;
    Object.fromId(canvas.accessibility).msgSend(void, "setTree:", .{tree});
}

fn accessibilityRole(_: Id, _: Sel) callconv(.c) Id {
    return NSAccessibilityGroupRole;
}

fn accessibilityLabel(_: Id, _: Sel) callconv(.c) Id {
    return appkit.autorelease(appkit.string("Telar", "Telar".len));
}

fn accessibilityChildren(raw: Id, _: Sel) callconv(.c) Id {
    const canvas = state(raw) orelse return null;
    return Object.fromId(canvas.accessibility).msgSend(Id, "children", .{});
}

fn accessibilityFocus(raw: Id, _: Sel) callconv(.c) Id {
    const canvas = state(raw) orelse return raw;
    const focused_element = Object.fromId(canvas.accessibility).msgSend(Id, "focusedElement", .{});
    return if (focused_element != null) focused_element else raw;
}

fn accessibilityHitTest(raw: Id, _: Sel, point: appkit.c.CGPoint) callconv(.c) Id {
    const canvas = state(raw) orelse return raw;
    const found = Object.fromId(canvas.accessibility).msgSend(Id, "hitTest:", .{point});
    return if (found != null) found else raw;
}

fn stop(raw: Id, selector: Sel) callconv(.c) void {
    const canvas = state(raw) orelse return;
    if (canvas.stopped) {
        return;
    }

    center().msgSend(void, "removeObserver:", .{raw});
    stopInput(raw, selector);
    Object.fromId(canvas.accessibility).msgSend(void, "stop", .{});
    canvas.host = null;
    canvas.stopped = true;
}

/// Window decoration changes can alter the reserved inset without resizing NSView.
pub fn refreshGeometry(view: Object) void {
    geometryChanged(view.value);
}
