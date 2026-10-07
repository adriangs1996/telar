//! The window's AppKit class: an `NSWindow` whose hidden title reserves no
//! layout or drag strip, so the content drawn under a transparent titlebar,
//! such as the tab strip, receives its own mouse drags.
const objc = @import("objc");
const appkit = @import("appkit.zig");
const StyleMask = @import("StyleMask.zig").StyleMask;

var registered: ?objc.Class = null;

/// Registers the class once and returns it.
///
/// ```zig
/// const window = (try window_class.register()).msgSend(objc.c.id, "alloc", .{});
/// ```
pub fn register() !objc.Class {
    if (registered) |class| {
        return class;
    }

    const class = objc.allocateClassPair(objc.getClass("NSWindow").?, "TelarWindow") orelse return error.NativeClassRegistrationFailed;
    errdefer objc.disposeClassPair(class);
    try appkit.method(class, "contentLayoutRect", contentLayoutRect);
    objc.registerClassPair(class);
    registered = class;
    return class;
}

// FullSizeContentView extends the content under the hidden title, but AppKit
// still insets this rectangle by the titlebar and drags the window from that
// strip. Fullscreen keeps AppKit's own geometry.
fn contentLayoutRect(raw: objc.c.id, _: objc.c.SEL) callconv(.c) appkit.c.CGRect {
    const window = objc.Object.fromId(raw);
    var rect = window.msgSendSuper(objc.getClass("NSWindow").?, appkit.c.CGRect, "contentLayoutRect", .{});
    const style = window.msgSend(usize, "styleMask", .{});
    if (style & @intFromEnum(StyleMask.full_content) != 0 and style & @intFromEnum(StyleMask.fullscreen) == 0) {
        const frame = window.msgSend(appkit.c.CGRect, "frame", .{});
        rect.origin.y = 0;
        rect.size.height = frame.size.height;
    }

    return rect;
}
