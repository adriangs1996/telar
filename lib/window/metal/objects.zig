const objc = @import("objc");

/// Returns an owned object; caller releases it. Example: `try create("MTLCompileOptions")`.
pub fn create(comptime name: [:0]const u8) !objc.Object {
    const class = objc.getClass(name) orelse return error.ClassUnavailable;
    return optional(class.msgSend(objc.c.id, "new", .{})) orelse error.ObjectCreationFailed;
}

/// Returns an owned UTF-8 NSString. Example: `const name = try string("vertex_main");`.
pub fn string(bytes: []const u8) !objc.Object {
    const class = objc.getClass("NSString") orelse return error.ClassUnavailable;
    const allocated = optional(class.msgSend(objc.c.id, "alloc", .{})) orelse return error.ObjectCreationFailed;
    const Encoding = enum(usize) { utf8 = 4 };
    return optional(allocated.msgSend(objc.c.id, "initWithBytes:length:encoding:", .{ bytes.ptr, bytes.len, @intFromEnum(Encoding.utf8) })) orelse error.InvalidUtf8;
}

/// Convert nullable native ids without giving an optional Zig struct to the C ABI.
/// Example: `const texture = optional(raw);`.
pub fn optional(raw: objc.c.id) ?objc.Object {
    return if (raw != null) objc.Object.fromId(raw) else null;
}

/// Both arm64 and x86_64 return double through ordinary objc_msgSend.
/// The pinned zig-objc selects fpret on x86_64, which is for long double there.
/// Example: `const seconds = double(feedback, "GPUStartTime");`.
pub fn double(self: objc.Object, comptime selector: [:0]const u8) f64 {
    const send: *const fn (objc.c.id, objc.c.SEL) callconv(.c) f64 = @ptrCast(&objc.c.objc_msgSend);
    return send(self.value, objc.sel(selector).value);
}
