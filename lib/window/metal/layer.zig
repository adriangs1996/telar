const objc = @import("objc");
const Object = objc.Object;
const objects = @import("objects.zig");
const PixelFormat = @import("PixelFormat.zig").PixelFormat;
const DrawableSize = @import("DrawableSize.zig").DrawableSize;

/// Example: `layer.setDevice(surface, value)`.
pub fn setDevice(self: Object, value: Object) void {
    self.msgSend(void, "setDevice:", .{value});
}

/// Example: `layer.setPixelFormat(surface, value)`.
pub fn setPixelFormat(self: Object, value: PixelFormat) void {
    self.msgSend(void, "setPixelFormat:", .{@intFromEnum(value)});
}

/// Example: `layer.setDrawableSize(surface, value)`.
pub fn setDrawableSize(self: Object, value: DrawableSize) void {
    self.msgSend(void, "setDrawableSize:", .{value});
}

/// Example: `layer.setFramebufferOnly(surface, value)`.
pub fn setFramebufferOnly(self: Object, value: bool) void {
    self.msgSend(void, "setFramebufferOnly:", .{value});
}

/// Example: `layer.setDisplaySyncEnabled(surface, value)`.
pub fn setDisplaySyncEnabled(self: Object, value: bool) void {
    self.msgSend(void, "setDisplaySyncEnabled:", .{value});
}

/// Borrowed drawable; may block or return null. Retain through GPU consumption. Example: `layer.nextDrawable(surface)`.
pub fn nextDrawable(self: Object) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "nextDrawable", .{}));
}

/// Borrowed drawable texture. Example: `layer.texture(drawable)`.
pub fn texture(self: Object) Object {
    return self.msgSend(Object, "texture", .{});
}

/// Example: `layer.present(drawable)`.
pub fn present(self: Object) void {
    self.msgSend(void, "present", .{});
}
