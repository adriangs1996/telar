const std = @import("std");
const objc = @import("objc");
pub const ClipboardSource = @import("macos/ClipboardSource.zig");
const Appearance = @import("Appearance.zig");
const WindowAppearance = @import("macos/WindowAppearance.zig");
const Options = @import("Options.zig");
const event = @import("Event.zig");
pub const Event = event.Event;
const input = @import("input/Input.zig");
pub const Input = input.Input;
const native_input = @import("input/NativeInput.zig");
pub const NativeInput = native_input.NativeInput;
const MacosSurface = @import("MacosSurface.zig");
pub const Surface = MacosSurface;
pub const Viewport = @import("Viewport.zig");
const wake_pipe = @import("wake_pipe.zig");
const HostState = @import("HostState.zig");
const Clipboard = @import("macos/Clipboard.zig");
const pointer_cursor = @import("macos/pointer_cursor.zig");
const appkit = @import("macos/appkit.zig");
const canvas_view = @import("macos/canvas_view.zig");
const window_class = @import("macos/window_class.zig");

pub const TextContext = @FieldType(HostState, "text");
pub const HostRequest = @typeInfo(@FieldType(HostState, "request")).optional.child;
pub const AccessibilityTree = @FieldType(HostState, "tree");

const c = @cImport({
    @cInclude("CoreFoundation/CFFileDescriptor.h");
    @cInclude("CoreGraphics/CGGeometry.h");
});

const MacosWindow = @This();
const CloseNotification = objc.Block(struct { pending: *bool }, .{objc.c.id}, void);
const EventMask = enum(usize) { any = std.math.maxInt(usize) };
extern "c" var NSWindowWillCloseNotification: objc.c.id;
extern "c" var NSArgumentDomain: objc.c.id;
const ActivationPolicy = enum(isize) { regular = 0 };

const Style = enum(usize) {
    titled = 1,
    closable = 2,
    miniaturizable = 4,
    resizable = 8,

    fn allStyles() c_int {
        return @intFromEnum(Style.titled) | @intFromEnum(Style.closable) | @intFromEnum(Style.miniaturizable) | @intFromEnum(Style.resizable);
    }
};

const Backing = enum(usize) {
    buffered = 2,
};

const Tabbing = enum(isize) {
    disallowed = 2,
};

const initial_size: c.CGSize = .{ .width = 800, .height = 480 };
const minimum_size: c.CGSize = .{ .width = 320, .height = 200 };

// Borrowed from AppKit; the shared application outlives this window.
application: objc.Object,
window: objc.Object,
drawing_surface: MacosSurface,
wake_descriptor: c.CFFileDescriptorRef,
wake_source: c.CFRunLoopSourceRef,
// Stable callback storage even when the owning window value moves.
wake_pending: *bool,
close_pending: *bool,
close_observer: objc.Object,
started: bool = false,
host: *HostState,
input_view: objc.Object,
clipboard: *Clipboard,
appearance: *WindowAppearance,
pending_snapshots: struct { text: bool = false, accessibility: bool = false, pointer: bool = false } = .{},

/// Creates a hidden AppKit window and attaches its presentation layer on the main
/// thread. The caller owns wake_fd; the first getNextEvent call shows the window.
pub fn init(options: Options) !MacosWindow {
    if (!wake_pipe.isReadable(options.wake_fd)) {
        return error.InvalidWakeDescriptor;
    }

    if (!std.unicode.utf8ValidateSlice(std.mem.span(options.title))) {
        return error.InvalidTitle;
    }

    if (!(objc.getClass("NSThread") orelse return error.ClassUnavailable).msgSend(bool, "isMainThread", .{})) {
        return error.MainThreadRequired;
    }

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

    // Terminal repeat is a process-local preference, never a persistent change
    // to the user's defaults. Configure it before AppKit initializes text input.
    const preferences = objc.getClass("NSUserDefaults").?.msgSend(objc.Object, "standardUserDefaults", .{});
    const arguments = preferences.msgSend(objc.Object, "volatileDomainForName:", .{NSArgumentDomain}).msgSend(objc.Object, "mutableCopy", .{});
    defer arguments.release();
    const repeat_key = objc.getClass("NSString").?.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*:0]const u8, "ApplePressAndHoldEnabled")});
    const disabled = objc.getClass("NSNumber").?.msgSend(objc.Object, "numberWithBool:", .{false});
    arguments.msgSend(void, "setObject:forKey:", .{ disabled, repeat_key });
    preferences.msgSend(void, "setVolatileDomain:forName:", .{ arguments, NSArgumentDomain });

    const app = try object((objc.getClass("NSApplication") orelse return error.ClassUnavailable).msgSend(objc.c.id, "sharedApplication", .{}));
    _ = app.msgSend(bool, "setActivationPolicy:", .{@intFromEnum(ActivationPolicy.regular)});

    const allocated = try object((try window_class.register()).msgSend(objc.c.id, "alloc", .{}));

    const window = try object(allocated.msgSend(objc.c.id, "initWithContentRect:styleMask:backing:defer:", .{
        c.CGRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = initial_size,
        },
        Style.allStyles(),
        @intFromEnum(Backing.buffered),
        false,
    }));

    window.msgSend(void, "setReleasedWhenClosed:", .{false});
    errdefer {
        window.msgSend(void, "close", .{});
        window.release();
    }

    const title_allocated = try object((objc.getClass("NSString") orelse return error.ClassUnavailable).msgSend(objc.c.id, "alloc", .{}));
    const title = try object(title_allocated.msgSend(objc.c.id, "initWithUTF8String:", .{options.title}));
    defer title.release();

    window.msgSend(void, "setTitle:", .{title});
    window.msgSend(void, "setMinSize:", .{minimum_size});
    window.msgSend(void, "setTabbingMode:", .{@intFromEnum(Tabbing.disallowed)});
    window.msgSend(void, "center", .{});

    const pending = try std.heap.c_allocator.create(bool);
    errdefer std.heap.c_allocator.destroy(pending);
    pending.* = false;

    const closed = try std.heap.c_allocator.create(bool);
    errdefer std.heap.c_allocator.destroy(closed);
    closed.* = false;
    const center = (objc.getClass("NSNotificationCenter") orelse return error.ClassUnavailable).msgSend(objc.Object, "defaultCenter", .{});
    const block = CloseNotification.init(.{ .pending = closed }, &close);

    const observer = (try object(
        center.msgSend(
            objc.c.id,
            "addObserverForName:object:queue:usingBlock:",
            .{
                NSWindowWillCloseNotification,
                window,
                @as(objc.c.id, null),
                &block,
            },
        ),
    )).retain();

    errdefer {
        center.msgSend(void, "removeObserver:", .{observer});
        observer.release();
    }

    const host = try std.heap.c_allocator.create(HostState);
    errdefer std.heap.c_allocator.destroy(host);
    host.* = .{};
    const clipboard = try std.heap.c_allocator.create(Clipboard);
    errdefer std.heap.c_allocator.destroy(clipboard);
    clipboard.* = .{};
    const view = try canvas_view.create(host);
    errdefer {
        view.msgSend(void, "stop", .{});
        view.release();
    }

    view.msgSend(
        void,
        "setPointerCursor:",
        .{
            pointer_cursor.get(host.pointer),
        },
    );

    window.msgSend(
        void,
        "setContentView:",
        .{
            view,
        },
    );

    _ = window.msgSend(bool, "makeFirstResponder:", .{view});
    window.msgSend(
        void,
        "setAcceptsMouseMovedEvents:",
        .{
            true,
        },
    );

    const bounds = view.msgSend(c.CGRect, "bounds", .{});
    const pixels = view.msgSend(c.CGRect, "convertRectToBacking:", .{bounds});

    var drawing_surface = try MacosSurface.init(
        .{
            .width = @intFromFloat(pixels.size.width),
            .height = @intFromFloat(pixels.size.height),
        },
        pending,
    );

    errdefer drawing_surface.deinit();
    view.msgSend(void, "setLayer:", .{drawing_surface.layer});
    view.msgSend(void, "setWantsLayer:", .{true});

    const appearance = try WindowAppearance.init(window, view);
    errdefer appearance.deinit();

    var context: c.CFFileDescriptorContext = std.mem.zeroes(c.CFFileDescriptorContext);
    context.info = pending;
    const descriptor = c.CFFileDescriptorCreate(null, options.wake_fd, 0, wake, &context) orelse return error.WakeSourceFailed;
    errdefer {
        c.CFFileDescriptorInvalidate(descriptor);
        c.CFRelease(descriptor);
    }

    const source = c.CFFileDescriptorCreateRunLoopSource(null, descriptor, 0) orelse return error.WakeSourceFailed;
    c.CFRunLoopAddSource(c.CFRunLoopGetMain(), source, c.kCFRunLoopCommonModes);
    c.CFFileDescriptorEnableCallBacks(descriptor, c.kCFFileDescriptorReadCallBack);

    return .{
        .application = app,
        .window = window,
        .drawing_surface = drawing_surface,
        .wake_descriptor = descriptor,
        .wake_source = source,
        .wake_pending = pending,
        .close_pending = closed,
        .close_observer = observer,
        .host = host,
        .input_view = view,
        .clipboard = clipboard,
        .appearance = appearance,
    };
}

/// Borrows the window's surface without allocating or transferring ownership.
/// Keep this window at a stable address and release renderer resources before
/// deinit; the returned reference must not be destroyed by its borrower.
pub fn surface(self: *MacosWindow) *MacosSurface {
    return &self.drawing_surface;
}

/// Pumps AppKit on the main thread and returns window and semantic input events.
/// The first call shows the window and publishes its initial geometry.
/// Between events, Core Foundation sleeps until a native source is handled;
/// runtime and canvas sources can therefore wake us without a synthetic NSEvent.
/// Input payloads remain valid until the next getNextEvent call or teardown.
pub fn getNextEvent(self: *MacosWindow) !Event {
    self.host.inputs.retire();
    if (self.close_pending.*) {
        return .close;
    }

    // A setter may have deferred a snapshot behind an input burst. Retry once
    // at the event boundary, never on every iteration of the native pump.
    self.publishSnapshots();

    if (!self.started) {
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        self.application.msgSend(void, "finishLaunching", .{});
        self.window.msgSend(void, "makeKeyAndOrderFront:", .{@as(objc.c.id, null)});
        self.started = true;
        self.host.wake_pending = true;
    }

    while (true) {
        if (self.close_pending.*) {
            return .close;
        }

        if (try self.host.next()) |pending| {
            if (pending == .resize) {
                self.drawing_surface.resize(pending.resize);
            }

            return pending;
        }

        // Reclaim AppKit's temporary objects on every iteration, even if no
        // application event is returned for a long time.
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        self.clipboard.poll(self.host);
        const past = objc.getClass("NSDate").?.msgSend(objc.Object, "distantPast", .{});

        const native = self.application.msgSend(objc.c.id, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
            @intFromEnum(EventMask.any),
            past,
            c.kCFRunLoopDefaultMode,
            true,
        });

        if (native != null) {
            self.application.msgSend(void, "sendEvent:", .{native});
            self.application.msgSend(void, "updateWindows", .{});
        }

        if (self.close_pending.*) {
            return .close;
        }

        if (self.host.inputs.len != 0 or self.host.resize_pending or self.host.interval_pending or self.host.wake_pending or self.host.inputs.failure != null) {
            continue;
        }

        const runtime_ready = try wake_pipe.take(c.CFFileDescriptorGetNativeDescriptor(self.wake_descriptor));

        if (runtime_ready or self.wake_pending.*) {
            self.wake_pending.* = false;
            c.CFFileDescriptorEnableCallBacks(self.wake_descriptor, c.kCFFileDescriptorReadCallBack);
            return .wake;
        }

        if (native == null) {
            const timeout = try self.host.timeout();
            const seconds: f64 = if (timeout < 0) std.math.floatMax(f64) else @as(f64, @floatFromInt(timeout)) / std.time.ms_per_s;
            _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, seconds, 1);
        }
    }
}

pub fn setTitle(self: *MacosWindow, title: []const u8) !void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const value = appkit.string(title.ptr, title.len);
    if (value == null) {
        return error.TitleCreationFailed;
    }
    defer objc.Object.fromId(value).release();
    self.window.msgSend(void, "setTitle:", .{value});
    self.appearance.set(self.appearance.value);
}

/// Returns an owned source for a media worker; the caller must deinit it after
/// reading, or immediately if worker admission fails.
pub fn clipboardSource(self: *MacosWindow) !ClipboardSource {
    _ = self;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const board = objc.getClass("NSPasteboard").?.msgSend(objc.Object, "generalPasteboard", .{});
    return .{ .board = board.retain(), .revision = board.msgSend(isize, "changeCount", .{}) };
}

/// Changes native composition without changing the opacity of rendered glyphs.
pub fn setAppearance(self: *MacosWindow, value: Appearance) !void {
    if (std.meta.eql(value, self.appearance.value)) {
        return;
    }
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    self.appearance.set(value);
}

/// Schedules one wake after a monotonic delay; zero cancels the pending deadline.
pub fn wakeAfter(self: *MacosWindow, delay_ms: u32) !void {
    try self.host.wakeAfter(delay_ms);
}

/// Publishes the editing snapshot after the caller updates its model. If input
/// remains undelivered, retain only the newest snapshot until that burst drains;
/// replacing the native optimistic IME mirror earlier could cancel composition.
pub fn setTextContext(self: *MacosWindow, value: TextContext) !void {
    try self.host.setTextContext(value);
    self.pending_snapshots.text = true;
    self.publishSnapshots();
}

/// Copies one clipboard request for native services; its result returns as
/// input.clipboard. A full pending slot returns HostRequestsFull for caller retry.
pub fn requestHost(self: *MacosWindow, value: HostRequest) !void {
    try self.host.requestHost(value);
}

/// Copies the semantic tree used by native accessibility queries. Actions from
/// assistive clients return through getNextEvent with the snapshot identity.
pub fn setAccessibility(self: *MacosWindow, value: AccessibilityTree) !void {
    try self.host.setAccessibility(value);
    self.pending_snapshots.accessibility = true;
    self.publishSnapshots();
}

pub fn setPointerShape(self: *MacosWindow, shape: u32) !void {
    if (shape > 33) {
        return error.InvalidPointerShape;
    }

    if (self.host.pointer == shape) {
        return;
    }

    self.host.pointer = shape;
    self.pending_snapshots.pointer = true;
    self.publishSnapshots();
}

// Setters publish immediately after application updates. The last returned input
// is still borrowed for payload lifetime, but has already reached the caller;
// only events behind it delay publication. Deferred snapshots coalesce in HostState.
fn publishSnapshots(self: *MacosWindow) void {
    const pending = self.pending_snapshots;
    if ((!pending.text and !pending.accessibility and !pending.pointer) or self.host.inputs.len > @as(usize, @intFromBool(self.host.inputs.borrowed))) {
        return;
    }

    self.pending_snapshots = .{};
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    if (pending.text) {
        self.input_view.msgSend(void, "setTextContext:", .{self.host.text});
    }

    if (pending.accessibility) {
        self.input_view.msgSend(void, "setAccessibilityTree:", .{self.host.tree});
    }

    if (pending.pointer) {
        self.input_view.msgSend(void, "setPointerCursor:", .{pointer_cursor.get(self.host.pointer)});
    }
}

/// Removes the wake source and closes the window on the main thread.
pub fn deinit(self: *MacosWindow) void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    self.appearance.deinit();
    self.input_view.msgSend(void, "stop", .{});
    self.input_view.release();
    const center = objc.getClass("NSNotificationCenter").?.msgSend(objc.Object, "defaultCenter", .{});
    center.msgSend(void, "removeObserver:", .{self.close_observer});
    self.close_observer.release();
    std.heap.c_allocator.destroy(self.close_pending);
    c.CFRunLoopRemoveSource(c.CFRunLoopGetMain(), self.wake_source, c.kCFRunLoopCommonModes);
    c.CFFileDescriptorInvalidate(self.wake_descriptor);
    c.CFRelease(self.wake_source);
    c.CFRelease(self.wake_descriptor);
    const view = self.input_view;
    view.msgSend(void, "setLayer:", .{@as(objc.c.id, null)});
    view.msgSend(void, "setWantsLayer:", .{false});
    self.drawing_surface.deinit();
    std.heap.c_allocator.destroy(self.wake_pending);
    std.heap.c_allocator.destroy(self.host);
    std.heap.c_allocator.destroy(self.clipboard);
    self.window.msgSend(void, "close", .{});
    self.window.release();
    self.* = undefined;
}

fn object(raw: objc.c.id) !objc.Object {
    if (raw == null) {
        return error.ObjectCreationFailed;
    }

    return objc.Object.fromId(raw);
}

/// NSNotificationCenter invokes this synchronously on the window thread when
/// this window closes. It copies the registered block, which borrows the stable
/// flag until deinit removes the observer. Stop also releases getNextEvent if
/// close originated in a run-loop timer rather than an AppKit event.
fn close(block: *const CloseNotification.Context, notification: objc.c.id) callconv(.c) void {
    _ = notification;
    block.pending.* = true;
    c.CFRunLoopStop(c.CFRunLoopGetMain());
}

// Core Foundation disables this source after delivery. getNextEvent consumes
// the flag, reads the borrowed pipe and rearms the source.
fn wake(descriptor: c.CFFileDescriptorRef, reasons: c.CFOptionFlags, context: ?*anyopaque) callconv(.c) void {
    _ = descriptor;
    _ = reasons;
    const pending: *bool = @ptrCast(@alignCast(context.?));
    pending.* = true;
}
