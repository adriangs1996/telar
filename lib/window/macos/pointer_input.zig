const std = @import("std");
const objc = @import("objc");
const appkit = @import("appkit.zig");
const native = @import("../native.zig");
const ScrollEvent = @import("../input/ScrollEvent.zig");
const PointerEvent = @import("../input/PointerEvent.zig");
const c = native.c;
const Id = objc.c.id;
const Sel = objc.c.SEL;
const Object = objc.Object;
const Tracking = enum(usize) { enter_exit = 1, moved = 2, cursor = 4, key_window = 32, visible_rect = 512 };
const NativePhase = enum(usize) { began = 1, stationary = 2, changed = 4, ended = 8, cancelled = 16, may_begin = 32 };
const Kind = enum(u32) { pointer = 6, scroll = 8 };
const Code = enum(u32) { press = 1, release = 2, drag = 3, move = 6, leave = 7 };
const Phase = enum(u32) { press = 1 };
const NativeButton = enum(isize) { left = 0, right = 1, middle = 2, _ };
const Pointer = struct {
    tracking: Id = null,
    cursor: Id = null,
    inside: bool = false,
    stopped: bool = false,
    last: c.telar_gui_input = std.mem.zeroes(c.telar_gui_input),
};
var offset: usize = 0;

/// Install pointer callbacks on the same NSView that owns text input. AppKit
/// delivers these through tracking areas and its responder chain, on the main thread.
pub fn install(class: objc.Class) !void {
    offset = try appkit.addStorage(class, "telar_pointer");
    try appkit.method(class, "updateTrackingAreas", updateTrackingAreas);
    try appkit.method(class, "acceptsFirstMouse:", acceptsFirstMouse);
    try appkit.method(class, "setPointerCursor:", setCursor);
    try appkit.method(class, "flagsChanged:", flagsChanged);
    try appkit.method(class, "mouseEntered:", mouseMoved);
    try appkit.method(class, "mouseExited:", mouseExited);
    try appkit.method(class, "cursorUpdate:", cursorUpdate);
    try appkit.method(class, "mouseMoved:", mouseMoved);
    inline for (.{ "mouse", "rightMouse", "otherMouse" }) |prefix| {
        try appkit.method(class, prefix ++ "Down:", mouseDown);
        try appkit.method(class, prefix ++ "Up:", mouseUp);
        try appkit.method(class, prefix ++ "Dragged:", mouseDragged);
    }

    try appkit.method(class, "scrollWheel:", scrollWheel);
}

pub fn init(raw: Id) !void {
    const pointer = try std.heap.c_allocator.create(Pointer);
    pointer.* = .{};
    appkit.storage(Pointer, raw, offset).* = pointer;
}

pub fn deinit(raw: Id) void {
    if (appkit.storage(Pointer, raw, offset).*) |pointer| {
        stop(raw);
        Object.fromId(pointer.cursor).release();
        std.heap.c_allocator.destroy(pointer);
        appkit.storage(Pointer, raw, offset).* = null;
    }
}

fn state(raw: Id) ?*Pointer {
    return appkit.storage(Pointer, raw, offset).*;
}

// A view may outlive its window because AppKit still retains it. Stop removes
// the tracking source and makes queued native events harmless before queue teardown.
pub fn stop(raw: Id) void {
    const pointer = state(raw) orelse return;
    if (pointer.stopped) {
        return;
    }

    reset(raw);
    pointer.stopped = true;
    if (pointer.tracking != null) {
        Object.fromId(raw).msgSend(void, "removeTrackingArea:", .{pointer.tracking});
        appkit.replace(&pointer.tracking, null);
    }
}

fn updateTrackingAreas(raw: Id, _: Sel) callconv(.c) void {
    const view = Object.fromId(raw);
    view.msgSendSuper(objc.getClass("NSView").?, void, "updateTrackingAreas", .{});
    const pointer = state(raw) orelse return;
    if (pointer.stopped) {
        return;
    }

    if (pointer.tracking != null) {
        view.msgSend(void, "removeTrackingArea:", .{pointer.tracking});
    }

    const options = @intFromEnum(Tracking.enter_exit) | @intFromEnum(Tracking.moved) | @intFromEnum(Tracking.cursor) | @intFromEnum(Tracking.key_window) | @intFromEnum(Tracking.visible_rect);
    const tracking = objc.getClass("NSTrackingArea").?.msgSend(Object, "alloc", .{}).msgSend(Id, "initWithRect:options:owner:userInfo:", .{ std.mem.zeroes(appkit.c.CGRect), options, raw, @as(Id, null) });
    appkit.replace(&pointer.tracking, tracking);
    if (tracking != null) {
        view.msgSend(void, "addTrackingArea:", .{tracking});
    }
}

fn acceptsFirstMouse(_: Id, _: Sel, _: Id) callconv(.c) bool {
    return true;
}

fn setCursor(raw: Id, _: Sel, cursor: Id) callconv(.c) void {
    const pointer = state(raw) orelse return;
    appkit.replace(&pointer.cursor, Object.fromId(cursor).retain().value);
    refresh(raw);
}

/// Reapply the model-selected cursor after input or publication. Native hover
/// and keyboard focus determine whether this view currently owns the cursor.
pub fn refresh(raw: Id) void {
    const pointer = state(raw) orelse return;
    if (pointer.stopped or !pointer.inside or pointer.cursor == null or !Object.fromId(raw).msgSend(Object, "window", .{}).msgSend(bool, "isKeyWindow", .{})) {
        return;
    }

    if (objc.getClass("NSCursor").?.msgSend(Id, "currentCursor", .{}) != pointer.cursor) {
        Object.fromId(pointer.cursor).msgSend(void, "set", .{});
    }
}

fn send(raw: Id, event: c.telar_gui_input) void {
    _ = Object.fromId(raw).msgSend(bool, "sendInput:", .{event});
}

fn arrow() void {
    objc.getClass("NSCursor").?.msgSend(Object, "arrowCursor", .{}).msgSend(void, "set", .{});
}

pub fn reset(raw: Id) void {
    const pointer = state(raw) orelse return;
    if (!pointer.inside) {
        return;
    }

    pointer.inside = false;
    pointer.last.code = @intFromEnum(Code.leave);
    pointer.last.mods = 0;
    send(raw, pointer.last);
    arrow();
}

fn contains(rect: appkit.c.CGRect, point: appkit.c.CGPoint) bool {
    return point.x >= rect.origin.x and point.y >= rect.origin.y and point.x < rect.origin.x + rect.size.width and point.y < rect.origin.y + rect.size.height;
}

fn atPoint(raw: Id, point: appkit.c.CGPoint) c.telar_gui_input {
    const view = Object.fromId(raw);
    const scale = appkit.double(view.msgSend(Object, "window", .{}), "backingScaleFactor");
    return std.mem.zeroInit(c.telar_gui_input, .{
        .kind = @intFromEnum(Kind.pointer),
        .code = @intFromEnum(Code.move),
        .phase = @intFromEnum(Phase.press),
        .x = point.x * scale,
        .y = (if (view.msgSend(bool, "isFlipped", .{})) point.y else view.msgSend(appkit.c.CGRect, "bounds", .{}).size.height - point.y) * scale,
    });
}

fn sendAt(raw: Id, event: c.telar_gui_input, point: appkit.c.CGPoint) void {
    const pointer = state(raw) orelse return;
    if (pointer.stopped) {
        return;
    }

    const was_inside = pointer.inside;
    pointer.inside = event.code != @intFromEnum(Code.leave) and contains(Object.fromId(raw).msgSend(appkit.c.CGRect, "bounds", .{}), point);
    pointer.last = event;
    if (was_inside and !pointer.inside) {
        arrow();
    }

    send(raw, event);
}

/// Focus notifications resample a stationary pointer; no timer or GPU frame is
/// required to restore hover after the window becomes key again.
pub fn restore(raw: Id) void {
    const pointer = state(raw) orelse return;
    const view = Object.fromId(raw);
    const window = view.msgSend(Object, "window", .{});
    if (pointer.stopped or !window.msgSend(bool, "isKeyWindow", .{})) {
        return;
    }

    const point = view.msgSend(appkit.c.CGPoint, "convertPoint:fromView:", .{ window.msgSend(appkit.c.CGPoint, "mouseLocationOutsideOfEventStream", .{}), @as(Id, null) });
    if (!contains(view.msgSend(appkit.c.CGRect, "bounds", .{}), point)) {
        reset(raw);
        return;
    }

    var event = atPoint(raw, point);
    event.mods = appkit.modifiers(objc.getClass("NSEvent").?.msgSend(usize, "modifierFlags", .{}));
    sendAt(raw, event, point);
}

fn sendPointer(raw: Id, native_event: Id, code: Code) void {
    const pointer = state(raw) orelse return;
    if (pointer.stopped) {
        return;
    }

    const view = Object.fromId(raw);
    const event = Object.fromId(native_event);
    const point = view.msgSend(appkit.c.CGPoint, "convertPoint:fromView:", .{ event.msgSend(appkit.c.CGPoint, "locationInWindow", .{}), @as(Id, null) });
    var input = atPoint(raw, point);
    input.code = @intFromEnum(code);
    const button: PointerEvent.Button = switch (@as(NativeButton, @enumFromInt(event.msgSend(isize, "buttonNumber", .{})))) {
        .right => .right,
        .middle => .middle,
        else => .left,
    };
    input.button = @intFromEnum(button);
    input.mods = appkit.modifiers(event.msgSend(usize, "modifierFlags", .{}));
    sendAt(raw, input, point);
}

fn flagsChanged(raw: Id, _: Sel, native_event: Id) callconv(.c) void {
    const pointer = state(raw) orelse return;
    if (!pointer.stopped and pointer.inside) {
        pointer.last.code = @intFromEnum(Code.move);
        pointer.last.button = @intFromEnum(PointerEvent.Button.left);
        pointer.last.mods = appkit.modifiers(Object.fromId(native_event).msgSend(usize, "modifierFlags", .{}));
        send(raw, pointer.last);
    }
}

fn mouseMoved(raw: Id, _: Sel, event: Id) callconv(.c) void {
    sendPointer(raw, event, .move);
}

fn mouseExited(raw: Id, _: Sel, event: Id) callconv(.c) void {
    sendPointer(raw, event, .leave);
}

fn cursorUpdate(raw: Id, _: Sel, _: Id) callconv(.c) void {
    refresh(raw);
}

fn mouseDown(raw: Id, _: Sel, event: Id) callconv(.c) void {
    const pointer = state(raw) orelse return;
    if (pointer.stopped) {
        return;
    }

    _ = Object.fromId(raw).msgSend(Object, "window", .{}).msgSend(bool, "makeFirstResponder:", .{raw});
    sendPointer(raw, event, .press);
}

fn mouseUp(raw: Id, _: Sel, event: Id) callconv(.c) void {
    sendPointer(raw, event, .release);
}

fn mouseDragged(raw: Id, _: Sel, event: Id) callconv(.c) void {
    sendPointer(raw, event, .drag);
}

fn scrollPhase(phase: usize) ScrollEvent.Phase {
    if (phase & @intFromEnum(NativePhase.cancelled) != 0) {
        return .cancel;
    }

    if (phase & @intFromEnum(NativePhase.ended) != 0) {
        return .end;
    }

    if (phase & (@intFromEnum(NativePhase.began) | @intFromEnum(NativePhase.may_begin)) != 0) {
        return .begin;
    }

    if (phase & (@intFromEnum(NativePhase.changed) | @intFromEnum(NativePhase.stationary)) != 0) {
        return .update;
    }

    return .none;
}

// AppKit supplies momentum itself. Precise deltas become device pixels; wheel
// deltas remain lines, with the same right/down sign convention as Wayland.
fn scrollWheel(raw: Id, _: Sel, native_event: Id) callconv(.c) void {
    const pointer = state(raw) orelse return;
    if (pointer.stopped) {
        return;
    }

    const view = Object.fromId(raw);
    const event = Object.fromId(native_event);
    const point = view.msgSend(appkit.c.CGPoint, "convertPoint:fromView:", .{ event.msgSend(appkit.c.CGPoint, "locationInWindow", .{}), @as(Id, null) });
    var input = atPoint(raw, point);
    input.kind = @intFromEnum(Kind.scroll);
    input.code = 0;
    input.mods = appkit.modifiers(event.msgSend(usize, "modifierFlags", .{}));
    input.precise = @intFromBool(event.msgSend(bool, "hasPreciseScrollingDeltas", .{}));
    const window = view.msgSend(Object, "window", .{});
    const scale = if (input.precise != 0 and window.value != null) appkit.double(window, "backingScaleFactor") else 1;
    input.delta_x = -appkit.double(event, "scrollingDeltaX") * scale;
    input.delta_y = -appkit.double(event, "scrollingDeltaY") * scale;
    input.scroll_phase = @intFromEnum(scrollPhase(event.msgSend(usize, "phase", .{})));
    input.momentum_phase = @intFromEnum(scrollPhase(event.msgSend(usize, "momentumPhase", .{})));
    send(raw, input);
}
