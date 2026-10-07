const objc = @import("objc");
const native = @import("../native.zig");
pub const c = @cImport({
    @cInclude("CoreFoundation/CFString.h");
    @cInclude("CoreGraphics/CGGeometry.h");
});
const input_receiver = @import("InputReceiver.zig");
const InputReceiver = input_receiver.InputReceiver;
const Encoding = enum(usize) { utf8 = 4 };

pub extern "c" fn objc_storeWeak(location: *objc.c.id, value: objc.c.id) objc.c.id;
pub extern "c" fn objc_loadWeak(location: *objc.c.id) objc.c.id;
pub extern "c" fn objc_destroyWeak(location: *objc.c.id) void;
pub extern "c" fn NSBeep() void;

// Each native instance owns one Zig allocation. Cache the ivar offset at class
// registration; event dispatch then reaches storage without runtime name lookup.
pub fn storage(comptime T: type, raw: objc.c.id, offset: usize) *?*T {
    return @ptrFromInt(@intFromPtr(raw) + offset);
}

pub fn addStorage(class: objc.Class, name: [:0]const u8) !usize {
    if (objc.c.class_addIvar(class.value, name.ptr, @sizeOf(usize), @ctz(@as(usize, @alignOf(usize))), "^v") == 0) {
        return error.NativeClassRegistrationFailed;
    }

    return @intCast(objc.c.ivar_getOffset(objc.c.class_getInstanceVariable(class.value, name.ptr)));
}

pub fn method(class: objc.Class, comptime selector: [:0]const u8, implementation: anytype) !void {
    const signature = comptime signature: {
        @setEvalBranchQuota(20000);
        break :signature encoding(@TypeOf(implementation));
    };
    if (objc.c.class_addMethod(class.value, objc.sel(selector).value, @ptrCast(&implementation), signature.ptr) == 0) {
        return error.NativeClassRegistrationFailed;
    }
}

pub fn length(raw: objc.c.id) usize {
    return objc.Object.fromId(raw).msgSend(usize, "length", .{});
}

pub fn string(source: [*c]const u8, count: usize) objc.c.id {
    return objc.getClass("NSString").?.msgSend(objc.Object, "alloc", .{}).msgSend(objc.c.id, "initWithBytes:length:encoding:", .{ source, count, @intFromEnum(Encoding.utf8) });
}

pub fn bytes(raw: objc.c.id) objc.Object {
    return objc.Object.fromId(raw).msgSend(objc.Object, "dataUsingEncoding:", .{@intFromEnum(Encoding.utf8)});
}

pub fn byteLength(raw: objc.c.id) usize {
    return objc.Object.fromId(raw).msgSend(usize, "lengthOfBytesUsingEncoding:", .{@intFromEnum(Encoding.utf8)});
}

pub fn autorelease(raw: objc.c.id) objc.c.id {
    return objc.Object.fromId(raw).msgSend(objc.c.id, "autorelease", .{});
}

// Replace an owned reference with another owned reference (no implicit retain).
pub fn replace(destination: *objc.c.id, value: objc.c.id) void {
    const previous = destination.*;
    destination.* = value;
    objc.Object.fromId(previous).release();
}

pub fn send(receiver: ?InputReceiver, event: native.c.telar_gui_input) bool {
    const target = receiver orelse return false;
    return target.receive(target.context, event);
}

// CGFloat uses ordinary objc_msgSend on both supported architectures. The
// binding's floating return path uses fpret on x86_64, intended for long double.
pub fn double(object: objc.Object, selector: [:0]const u8) f64 {
    const call: *const fn (objc.c.id, objc.c.SEL) callconv(.c) f64 = @ptrCast(&objc.c.objc_msgSend);
    return call(object.value, objc.sel(selector).value);
}

// zig-objc's encoder does not support usize/isize (including size_t fields in
// imported C structs). Handle those recursively and use its primitive encodings.
fn encoding(comptime T: type) [:0]const u8 {
    if (T == usize) {
        return &objc.comptimeEncode(c_ulong);
    }

    if (T == isize) {
        return &objc.comptimeEncode(c_long);
    }

    if (T == objc.c.id or T == objc.c.SEL or T == objc.c.Class) {
        return &objc.comptimeEncode(T);
    }

    switch (@typeInfo(T)) {
        .@"fn" => |function| {
            comptime var result: [:0]const u8 = encoding(function.return_type.?);
            inline for (function.params) |parameter| {
                result = result ++ encoding(parameter.type.?);
            }

            return result;
        },
        .@"struct" => |structure| {
            comptime var result: [:0]const u8 = "{" ++ @typeName(T) ++ "=";
            inline for (structure.fields) |field| {
                result = result ++ encoding(field.type);
            }

            return result ++ "}";
        },
        .pointer => |pointer| return if (@typeInfo(pointer.child) == .@"fn") "^?" else "^" ++ encoding(pointer.child),
        .optional => |optional| return encoding(optional.child),
        else => return &objc.comptimeEncode(T),
    }
}

// AppKit modifier bits are shared by keyboard, pointer and scroll events.
pub fn modifiers(flags: usize) u32 {
    const Native = enum(usize) {
        shift = 1 << 17,
        alt = 1 << 19,
        control = 1 << 18,
        command = 1 << 20,
    };

    const Semantic = enum(u32) {
        shift = 1,
        alt = 2,
        control = 4,
        command = 8,
    };

    var result: u32 = 0;

    inline for (.{ "shift", "alt", "control", "command" }) |name| {
        if (flags & @intFromEnum(@field(Native, name)) != 0) {
            result |= @intFromEnum(@field(Semantic, name));
        }
    }

    return result;
}
