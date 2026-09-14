//! A frame-local heterogeneous list of concrete Zig values. The union passed
//! to Type supplies draw(Canvas); no native adapter knows its variants.
const Canvas = @import("Canvas.zig");

/// The storage is bounded at compile time; appending and drawing allocate
/// nothing. Borrowed model/text fields remain valid until draw returns.
/// Example: `const WidgetList = GenericWidgetList(Widget, 16);`
pub fn Type(comptime Widget: type, comptime capacity: usize) type {
    return struct {
        const List = @This();

        storage: [capacity]Widget = undefined,
        len: usize = 0,

        /// Copies one widget into the frame, rejecting overflow explicitly.
        /// A widget may borrow the projection, but never a shorter-lived local.
        /// Example: `try widgets.append(.{ .button = button });`
        pub fn append(list: *List, widget: Widget) !void {
            if (list.len == list.storage.len) {
                return error.WidgetCapacityExceeded;
            }

            list.storage[list.len] = widget;
            list.len += 1;
        }

        /// Dispatches in declaration order. Only quads and owned hit records
        /// may survive; the host must never retain a widget or projection.
        /// Example: `try widgets.draw(canvas);`
        pub fn draw(list: *const List, canvas: *Canvas) !void {
            for (list.storage[0..list.len]) |widget| {
                try widget.draw(canvas);
            }
        }
    };
}
