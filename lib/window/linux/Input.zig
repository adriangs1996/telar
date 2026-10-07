const std = @import("std");
const native = @import("../native.zig");
const c = native.c;
const HostState = @import("../HostState.zig");
const raw_input = @import("../input/NativeInput.zig");
const RawInput = raw_input.NativeInput;
const Pointer = @import("Pointer.zig");
const TextInput = @import("TextInput.zig");
const ClipboardReader = @import("ClipboardReader.zig");
const Input = @This();
const key_capacity = 256;
const offer_capacity = 16;
const keymap_capacity = 4 * 1024 * 1024;
const xkb_offset = 8;
const Phase = enum(u32) { press = 1, repeat = 2, release = 3 };
const ProtocolVersion = enum(u32) { initial = 1, seat = 8 };
const Offer = struct { handle: ?*c.wl_data_offer = null, utf8: bool = false, plain: bool = false, png: bool = false };

host: *HostState,
pointer: Pointer,
text_input: TextInput,
reader: ClipboardReader = .{},
clipboard: *c.telar_clipboard,
xkb: *c.xkb_context,
keymap: ?*c.xkb_keymap = null,
state: ?*c.xkb_state = null,
compose_table: ?*c.xkb_compose_table = null,
compose: ?*c.xkb_compose_state = null,
seat: ?*c.wl_seat = null,
keyboard: ?*c.wl_keyboard = null,
manager: ?*c.wl_data_device_manager = null,
device: ?*c.wl_data_device = null,
seat_global: u32 = 0,
manager_global: u32 = 0,
selection_serial: u32 = 0,
held: [key_capacity]?RawInput = @splat(null),
offers: [offer_capacity]Offer = @splat(.{}),
selection: ?*Offer = null,
read_target: u64 = 0,
read_generation: u64 = 0,
result: ?RawInput = null,
repeat_rate: i32 = 0,
repeat_delay: i32 = 0,
repeat_key: u32 = 0,
repeat_at: i64 = 0,
fullscreen_requested: bool = false,

pub fn init(host: *HostState, outputs: *c.telar_outputs) !Input {
    var pointer = try Pointer.init(host, outputs);
    errdefer pointer.deinit();
    const clipboard = c.telar_clipboard_create() orelse return error.ClipboardInitializationFailed;
    errdefer c.telar_clipboard_destroy(clipboard);
    const xkb = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.KeyboardInitializationFailed;
    var self: Input = .{
        .host = host,
        .pointer = pointer,
        .text_input = .{ .host = host },
        .clipboard = clipboard,
        .xkb = xkb,
    };
    var locale: [*c]const u8 = "C.UTF-8";
    for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        const value = c.getenv(name);
        if (value != null and value[0] != 0) {
            locale = value;
            break;
        }
    }
    self.compose_table = c.xkb_compose_table_new_from_locale(xkb, locale, c.XKB_COMPOSE_COMPILE_NO_FLAGS);
    if (self.compose_table) |table| {
        self.compose = c.xkb_compose_state_new(table, c.XKB_COMPOSE_STATE_NO_FLAGS);
    }
    return self;
}

pub fn now() i64 {
    // SAFETY: clock_gettime fills time on success; the failure branch returns before reading it.
    var time: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &time) != 0) {
        return 0;
    }
    return time.tv_sec * std.time.ms_per_s + @divTrunc(time.tv_nsec, std.time.ns_per_ms);
}

fn emit(self: *Input, value: RawInput) bool {
    return self.host.receive(@bitCast(value));
}

fn emitKey(self: *Input, key: u32, value: RawInput) void {
    var event = value;
    event.physical = if (key < key_capacity) key + 1 else 0;
    if (self.emit(event) and event.physical != 0) {
        self.held[key] = event;
    }
}

fn modifiers(self: *const Input) u32 {
    var value: u32 = 0;
    const names = [_][*:0]const u8{ c.XKB_MOD_NAME_SHIFT, c.XKB_MOD_NAME_ALT, c.XKB_MOD_NAME_CTRL, c.XKB_MOD_NAME_LOGO };
    for (names, 0..) |name, index| {
        if (c.xkb_state_mod_name_is_active(self.state, name, c.XKB_STATE_MODS_EFFECTIVE) > 0) {
            value |= @as(u32, 1) << @intCast(index);
        }
    }
    return value;
}

/// Releases use the accepted press identity. Compose text stays provisional
/// until xkb completes it; fullscreen is recorded for the owning window to consume.
fn sendKey(self: *Input, key: u32, phase: Phase) void {
    if (self.state == null or key > std.math.maxInt(u32) - xkb_offset) {
        return;
    }
    if (phase == .release) {
        if (key < key_capacity) {
            if (self.held[key]) |pressed| {
                var released = pressed;
                released.phase = @intFromEnum(phase);
                if (self.emit(released)) {
                    self.held[key] = null;
                }
            }
        }
        return;
    }
    const sym = c.xkb_state_key_get_one_sym(self.state, key + xkb_offset);
    const mods = self.modifiers();
    if (sym == c.XKB_KEY_F11 and mods == 0) {
        if (phase == .press) {
            self.fullscreen_requested = true;
        }
        return;
    }
    const code: u32 = switch (sym) {
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => 1,
        c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab => 2,
        c.XKB_KEY_BackSpace => 3,
        c.XKB_KEY_Escape => 4,
        c.XKB_KEY_Up => 5,
        c.XKB_KEY_Down => 6,
        c.XKB_KEY_Left => 7,
        c.XKB_KEY_Right => 8,
        c.XKB_KEY_Home => 9,
        c.XKB_KEY_End => 10,
        c.XKB_KEY_Delete => 11,
        c.XKB_KEY_Page_Up => 12,
        c.XKB_KEY_Page_Down => 13,
        else => 0,
    };
    if (code != 0) {
        self.emitKey(key, .{ .kind = 3, .code = code, .mods = mods, .phase = @intFromEnum(phase) });
        return;
    }
    const shortcut_modifiers = 2 | 4 | 8;
    if (mods & shortcut_modifiers != 0) {
        const scalar = c.xkb_keysym_to_utf32(sym);
        if (scalar >= ' ') {
            self.emitKey(key, .{ .kind = 4, .code = scalar, .mods = mods, .phase = @intFromEnum(phase) });
        }
        return;
    }
    var text: [128]u8 = undefined;
    var len: c_int = 0;
    var composed = false;
    if (self.compose) |compose| {
        _ = c.xkb_compose_state_feed(compose, sym);
        switch (c.xkb_compose_state_get_status(compose)) {
            c.XKB_COMPOSE_COMPOSING => return,
            c.XKB_COMPOSE_COMPOSED => {
                composed = true;
                len = c.xkb_compose_state_get_utf8(compose, &text, text.len);
                c.xkb_compose_state_reset(compose);
            },
            c.XKB_COMPOSE_CANCELLED => {
                c.xkb_compose_state_reset(compose);
                return;
            },
            else => {},
        }
    }
    if (len == 0) {
        len = c.xkb_state_key_get_utf8(self.state, key + xkb_offset, &text, text.len);
    }
    if (len > 0 and len < text.len) {
        const physical = if (!composed and key < key_capacity) key + 1 else 0;
        if (self.emit(.{ .kind = 1, .phase = @intFromEnum(phase), .text = &text, .len = @intCast(len), .physical = physical }) and physical != 0) {
            self.held[key] = .{ .kind = 4, .code = c.xkb_keysym_to_utf32(sym), .physical = physical };
        }
    }
}

fn from(data: ?*anyopaque) *Input {
    return @ptrCast(@alignCast(data.?));
}

/// Wayland lends a keymap file descriptor. Bound the mapping and validate its
/// terminator before replacing xkb state; every path closes the descriptor.
fn keyboardKeymap(data: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, fd: c_int, size: u32) callconv(.c) void {
    defer _ = c.close(fd);
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 or size == 0 or size > keymap_capacity) {
        return;
    }
    // SAFETY: fstat fills metadata on success; short-circuit evaluation skips st_size when fstat fails.
    var metadata: c.struct_stat = undefined;
    if (c.fstat(fd, &metadata) != 0 or metadata.st_size < size) {
        return;
    }
    const mapping = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
    if (mapping == c.MAP_FAILED) {
        return;
    }
    defer _ = c.munmap(mapping, size);
    const bytes: [*]const u8 = @ptrCast(mapping.?);
    if (bytes[size - 1] != 0) {
        return;
    }
    const self = from(data);
    const replacement = c.xkb_keymap_new_from_string(self.xkb, @ptrCast(bytes), c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return;
    const state = c.xkb_state_new(replacement) orelse {
        c.xkb_keymap_unref(replacement);
        return;
    };
    c.xkb_state_unref(self.state);
    c.xkb_keymap_unref(self.keymap);
    self.keymap = replacement;
    self.state = state;
}

fn keyboardEnter(data: ?*anyopaque, _: ?*c.wl_keyboard, serial: u32, _: ?*c.wl_surface, _: [*c]c.wl_array) callconv(.c) void {
    const self = from(data);
    self.selection_serial = serial;
    _ = self.emit(.{ .kind = 5, .code = 1 });
}

fn keyboardLeave(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    const self = from(data);
    self.repeat_at = 0;
    for (0..key_capacity) |key| {
        self.sendKey(@intCast(key), .release);
    }
    self.pointer.modifiers(0);
    if (self.state != null) {
        _ = c.xkb_state_update_mask(self.state, 0, 0, 0, 0, 0, 0);
    }
    self.selection_serial = 0;
    self.reader.cancel();
    _ = self.emit(.{ .kind = 5, .code = 0 });
    if (self.compose) |compose| {
        c.xkb_compose_state_reset(compose);
    }
}

// Wayland fixes this listener signature; its protocol arguments cannot be grouped.
// codestyle: allow(maximum-parameter-count)
fn keyboardKey(data: ?*anyopaque, _: ?*c.wl_keyboard, serial: u32, _: u32, key: u32, state: u32) callconv(.c) void {
    const self = from(data);
    if (key > std.math.maxInt(u32) - xkb_offset) {
        return;
    }
    self.selection_serial = serial;
    const pressed = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
    self.sendKey(key, if (pressed) .press else .release);
    if (pressed and self.keymap != null and self.repeat_rate > 0 and c.xkb_keymap_key_repeats(self.keymap, key + xkb_offset) != 0) {
        self.repeat_key = key;
        self.repeat_at = now() + self.repeat_delay;
    } else if (self.repeat_key == key) {
        self.repeat_at = 0;
    }
}

// Wayland fixes this listener signature; its protocol arguments cannot be grouped.
// codestyle: allow(maximum-parameter-count)
fn keyboardModifiers(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
    const self = from(data);
    if (self.state != null) {
        _ = c.xkb_state_update_mask(self.state, depressed, latched, locked, 0, 0, group);
        self.pointer.modifiers(self.modifiers());
    }
}

fn repeatInfo(data: ?*anyopaque, _: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    const self = from(data);
    self.repeat_rate = std.math.clamp(rate, 0, std.time.ms_per_s);
    self.repeat_delay = @max(0, delay);
    if (self.repeat_rate == 0) {
        self.repeat_at = 0;
    }
}

const keyboard_listener: c.wl_keyboard_listener = .{
    .keymap = keyboardKeymap,
    .enter = keyboardEnter,
    .leave = keyboardLeave,
    .key = keyboardKey,
    .modifiers = keyboardModifiers,
    .repeat_info = repeatInfo,
};

fn capabilities(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.c) void {
    const self = from(data);
    self.pointer.attach(seat, caps & c.WL_SEAT_CAPABILITY_POINTER != 0);
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard == null) {
        self.keyboard = c.wl_seat_get_keyboard(seat);
        if (self.keyboard) |keyboard| {
            _ = c.wl_keyboard_add_listener(keyboard, &keyboard_listener, self);
        }
    } else if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD == 0) {
        if (self.keyboard) |keyboard| {
            keyboardLeave(self, keyboard, 0, null);
            if (c.wl_keyboard_get_version(keyboard) >= c.WL_KEYBOARD_RELEASE_SINCE_VERSION) {
                c.wl_keyboard_release(keyboard);
            } else {
                c.wl_keyboard_destroy(keyboard);
            }
            self.keyboard = null;
        }
    }
}

fn seatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}
const seat_listener: c.wl_seat_listener = .{ .capabilities = capabilities, .name = seatName };

fn offered(data: ?*anyopaque, _: ?*c.wl_data_offer, mime: [*c]const u8) callconv(.c) void {
    const offer: *Offer = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, std.mem.span(mime), "image/png")) {
        offer.png = true;
    }
    if (std.mem.eql(u8, std.mem.span(mime), "text/plain;charset=utf-8")) {
        offer.utf8 = true;
    }
    if (std.mem.eql(u8, std.mem.span(mime), "text/plain")) {
        offer.plain = true;
    }
}
const offer_listener = std.mem.zeroInit(c.wl_data_offer_listener, .{ .offer = offered });

fn dataOffer(data: ?*anyopaque, _: ?*c.wl_data_device, handle: ?*c.wl_data_offer) callconv(.c) void {
    for (&from(data).offers) |*offer| {
        if (offer.handle == null) {
            offer.* = .{ .handle = handle };
            _ = c.wl_data_offer_add_listener(handle, &offer_listener, offer);
            return;
        }
    }
    c.wl_data_offer_destroy(handle);
}

fn selectOffer(data: ?*anyopaque, _: ?*c.wl_data_device, handle: ?*c.wl_data_offer) callconv(.c) void {
    const self = from(data);
    self.selection = null;
    for (&self.offers) |*offer| {
        if (offer.handle == handle and handle != null) {
            self.selection = offer;
        } else if (offer.handle != null) {
            c.wl_data_offer_destroy(offer.handle);
            offer.* = .{};
        }
    }
}

// Telar currently accepts clipboard selections, not drag-and-drop offers. The
// listener slots are required by wl_data_device even when these gestures are ignored.
// Wayland fixes this listener signature; its protocol arguments cannot be grouped.
// codestyle: allow(maximum-parameter-count)
fn dragEnter(_: ?*anyopaque, _: ?*c.wl_data_device, _: u32, _: ?*c.wl_surface, _: c.wl_fixed_t, _: c.wl_fixed_t, _: ?*c.wl_data_offer) callconv(.c) void {}
fn dragLeave(_: ?*anyopaque, _: ?*c.wl_data_device) callconv(.c) void {}
fn dragMotion(_: ?*anyopaque, _: ?*c.wl_data_device, _: u32, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}
fn dragDrop(_: ?*anyopaque, _: ?*c.wl_data_device) callconv(.c) void {}
const data_listener: c.wl_data_device_listener = .{
    .data_offer = dataOffer,
    .enter = dragEnter,
    .leave = dragLeave,
    .motion = dragMotion,
    .drop = dragDrop,
    .selection = selectOffer,
};

pub fn global(self: *Input, value: *const c.telar_registry_global) void {
    self.text_input.global(value);
    c.telar_cursor_global(self.pointer.cursor, value);
    const interface = std.mem.span(value.interface);
    if (std.mem.eql(u8, interface, "wl_seat") and self.seat == null) {
        self.seat = @ptrCast(c.wl_registry_bind(value.registry, value.name, &c.wl_seat_interface, @min(value.version, @intFromEnum(ProtocolVersion.seat))));
        self.seat_global = value.name;
        _ = c.wl_seat_add_listener(self.seat, &seat_listener, self);
        self.text_input.setSeat(self.seat);
    } else if (std.mem.eql(u8, interface, "wl_data_device_manager") and self.manager == null) {
        self.manager = @ptrCast(c.wl_registry_bind(value.registry, value.name, &c.wl_data_device_manager_interface, @intFromEnum(ProtocolVersion.initial)));
        self.manager_global = value.name;
    }
    if (self.seat != null and self.manager != null and self.device == null) {
        self.device = c.wl_data_device_manager_get_data_device(self.manager, self.seat);
        _ = c.wl_data_device_add_listener(self.device, &data_listener, self);
    }
}

pub fn remove(self: *Input, name: u32) void {
    self.text_input.remove(name);
    c.telar_cursor_remove(self.pointer.cursor, name);
    const seat_removed = self.seat != null and self.seat_global == name;
    const manager_removed = self.manager != null and self.manager_global == name;
    if (!seat_removed and !manager_removed) {
        return;
    }
    if (self.device) |device| {
        c.wl_data_device_destroy(device);
        self.device = null;
    }
    selectOffer(self, null, null);
    self.reader.cancel();
    if (seat_removed) {
        self.text_input.setSeat(null);
        capabilities(self, self.seat, 0);
        self.selection_serial = 0;
        if (c.wl_seat_get_version(self.seat) >= c.WL_SEAT_RELEASE_SINCE_VERSION) {
            c.wl_seat_release(self.seat);
        } else {
            c.wl_seat_destroy(self.seat);
        }
        self.seat = null;
    }
    if (manager_removed) {
        c.wl_data_device_manager_destroy(self.manager);
        self.manager = null;
    }
}

fn beginRead(self: *Input, request: c.telar_gui_host_request) bool {
    const offer = self.selection orelse return false;
    if (self.reader.pending) {
        return false;
    }
    const mime: [*:0]const u8 = if (offer.utf8) "text/plain;charset=utf-8" else if (offer.plain) "text/plain" else return false;
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) {
        return false;
    }
    defer _ = c.close(fds[1]);
    if (!self.reader.begin(fds[0], request.request_id, now())) {
        _ = c.close(fds[0]);
        return false;
    }
    c.wl_data_offer_receive(offer.handle, mime, fds[1]);
    self.read_target = request.target_id;
    self.read_generation = request.generation;
    return true;
}

pub fn writeClipboard(self: *Input, bytes: []const u8) bool {
    const offer: c.telar_clipboard_offer = .{
        .manager = self.manager,
        .device = self.device,
        .serial = self.selection_serial,
        .bytes = bytes.ptr,
        .len = bytes.len,
    };
    return c.telar_clipboard_publish(self.clipboard, &offer);
}

fn deliverRead(self: *Input) void {
    if (!self.reader.ready) {
        return;
    }
    const legacy = self.reader.request_id == 0;
    if ((legacy and self.reader.status != .success) or self.emit(.{
        .kind = if (legacy) 2 else 9,
        .code = @intFromEnum(self.reader.status),
        .text = &self.reader.bytes,
        .len = self.reader.len,
        .request_id = self.reader.request_id,
        .target_id = self.read_target,
        .generation = self.read_generation,
    })) {
        self.reader.release();
    }
}

/// Advances bounded work on the window thread. Native services read owned
/// snapshots and emit into the window queue directly, without a GUI callback table.
pub fn poll(self: *Input, time: i64) void {
    if (self.repeat_at != 0 and time >= self.repeat_at) {
        self.sendKey(self.repeat_key, .repeat);
        self.repeat_at = time + @divTrunc(std.time.ms_per_s, self.repeat_rate);
    }
    self.reader.read(time);
    self.deliverRead();
    if (self.result) |result| {
        if (!self.emit(result)) {
            return;
        }
        self.result = null;
    }
    if (self.host.request) |request| {
        self.host.request = null;
        if (request.kind == 1 and self.beginRead(request)) {
            return;
        }
        const result: RawInput = .{
            .kind = 9,
            .code = if (request.kind == 2 and self.writeClipboard(if (request.len == 0) "" else request.text[0..request.len])) 0 else 1,
            .request_id = request.request_id,
            .target_id = request.target_id,
            .generation = request.generation,
        };
        if (!self.emit(result)) {
            self.result = result;
        }
    }
}

pub fn timeout(self: *const Input, time: i64) c_int {
    const read_wait = self.reader.timeout(time);
    if (self.repeat_at == 0) {
        return read_wait;
    }
    const repeat_wait: c_int = @intCast(std.math.clamp(self.repeat_at - time, 0, std.math.maxInt(c_int)));
    return if (read_wait < 0) repeat_wait else @min(read_wait, repeat_wait);
}

pub fn deinit(self: *Input) void {
    self.reader.release();
    self.text_input.deinit();
    selectOffer(self, null, null);
    c.telar_clipboard_destroy(self.clipboard);
    if (self.device) |device| {
        c.wl_data_device_destroy(device);
    }
    if (self.manager) |manager| {
        c.wl_data_device_manager_destroy(manager);
    }
    self.pointer.deinit();
    if (self.keyboard) |keyboard| {
        c.wl_keyboard_destroy(keyboard);
    }
    if (self.seat) |seat| {
        c.wl_seat_destroy(seat);
    }
    c.xkb_compose_state_unref(self.compose);
    c.xkb_compose_table_unref(self.compose_table);
    c.xkb_state_unref(self.state);
    c.xkb_keymap_unref(self.keymap);
    c.xkb_context_unref(self.xkb);
}

/// Starts the current selection's binary transfer before returning to the loop.
/// No UTF-8 conversion or image decoding runs in the native input pump.
pub fn imageSource(self: *Input, display: *c.wl_display) !c_int {
    const offer = self.selection orelse return error.NoImageOnClipboard;
    if (!offer.png) {
        return error.NoImageOnClipboard;
    }
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) {
        return error.ClipboardReadFailed;
    }
    errdefer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    if (c.fcntl(fds[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) != 0) {
        return error.ClipboardReadFailed;
    }
    c.wl_data_offer_receive(offer.handle, "image/png", fds[1]);
    if (c.wl_display_flush(display) < 0 and c.__errno_location().* != c.EAGAIN) {
        return error.ClipboardReadFailed;
    }
    return fds[0];
}
