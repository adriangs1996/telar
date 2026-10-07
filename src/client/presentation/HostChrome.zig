/// Questions only the adapter's drawn chrome can answer: how far the
/// inspector scrolls under its layout. Everything the chrome draws, the
/// adapter reads from the model; pointer hit testing runs in the adapter's
/// own flow between the `pointer_routing` steps.
const HostChrome = @This();

context: *anyopaque,
inspection_scroll_limit_fn: *const fn (*anyopaque) ?u32,

/// The history inspector's scroll bound under the adapter's layout, when the
/// inspector is open and clamping is needed.
/// Example: `if (client.chrome.inspectionScrollLimit()) |limit| ...`
pub fn inspectionScrollLimit(self: HostChrome) ?u32 {
    return self.inspection_scroll_limit_fn(self.context);
}
