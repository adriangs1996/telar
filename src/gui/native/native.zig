//! Native backends borrow frame bytes only through their submission. Completion
//! runs on the window thread after the GPU stops consuming that submission.
pub const TextContext = @import("TextContext.zig").TextContext;
pub const HostRequest = @import("HostRequest.zig").HostRequest;
pub const WindowTitle = @import("WindowTitle.zig").WindowTitle;
pub const AccessibilityNode = @import("AccessibilityNode.zig").AccessibilityNode;
pub const AccessibilityTree = @import("AccessibilityTree.zig").AccessibilityTree;

pub extern fn telar_gui_pipe(fds: *[2]c_int) c_int;
pub extern fn telar_gui_wake(fd: c_int) void;
pub extern fn telar_gui_drain(fd: c_int) void;
pub extern fn telar_gui_close_pipe(fds: *[2]c_int) void;
