const data = @import("model");
const ViewInteractionCommandType = @import("../operations/input/ViewInteractionCommand.zig");
/// Questions only the adapter's drawn chrome can answer: what a pointer hit
/// and how far the inspector scrolls under its layout. Everything the chrome
/// draws, the adapter reads from the model.
const HostChrome = @This();

context: *anyopaque,
pointer_fn: *const fn (*anyopaque, data.Mouse) ViewInteractionCommandType,
inspection_scroll_limit_fn: *const fn (*anyopaque) ?u32,
link_pointer_fn: ?*const fn (*anyopaque, data.Mouse) bool = null,

/// Resolves one pointer event against the adapter's chrome hit map.
/// Example: `const interaction = client.chrome.pointer(event);`.
pub fn pointer(port: HostChrome, event: data.Mouse) ViewInteractionCommandType {
    return port.pointer_fn(port.context, event);
}

/// Lets an adapter own its native link gesture. Null retains shared routing.
/// Example: `if (client.chrome.linkPointer(event)) |consumed| return consumed;`
pub fn linkPointer(port: HostChrome, event: data.Mouse) ?bool {
    const callback = port.link_pointer_fn orelse return null;
    return callback(port.context, event);
}

/// The history inspector's scroll bound under the adapter's layout, when the
/// inspector is open and clamping is needed.
/// Example: `if (client.chrome.inspectionScrollLimit()) |limit| ...`
pub fn inspectionScrollLimit(port: HostChrome) ?u32 {
    return port.inspection_scroll_limit_fn(port.context);
}
