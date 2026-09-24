const keyinput = @import("keyinput");
const ViewInteractionCommand = @import("../input/ViewInteractionCommand.zig");
/// Questions only the adapter's drawn chrome can answer: what a pointer hit
/// and how far the inspector scrolls under its layout. Everything the chrome
/// draws, the adapter reads from the model.
const HostChrome = @This();

context: *anyopaque,
pointer_fn: *const fn (*anyopaque, keyinput.Mouse) ViewInteractionCommand,
inspection_scroll_limit_fn: *const fn (*anyopaque) ?u32,
link_pointer_fn: ?*const fn (*anyopaque, keyinput.Mouse) bool = null,

/// Resolves one pointer event against the adapter's chrome hit map.
/// Example: `const interaction = client.chrome.pointer(event);`.
pub fn pointer(self: HostChrome, event: keyinput.Mouse) ViewInteractionCommand {
    return self.pointer_fn(self.context, event);
}

/// Lets an adapter own its native link gesture. Null retains shared routing.
/// Example: `if (client.chrome.linkPointer(event)) |consumed| return consumed;`
pub fn linkPointer(self: HostChrome, event: keyinput.Mouse) ?bool {
    const callback = self.link_pointer_fn orelse return null;
    return callback(self.context, event);
}

/// The history inspector's scroll bound under the adapter's layout, when the
/// inspector is open and clamping is needed.
/// Example: `if (client.chrome.inspectionScrollLimit()) |limit| ...`
pub fn inspectionScrollLimit(self: HostChrome) ?u32 {
    return self.inspection_scroll_limit_fn(self.context);
}
