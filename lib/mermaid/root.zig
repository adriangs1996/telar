//! Mermaid diagrams rendered to bounded premultiplied RGBA by an isolated
//! helper process. The caller names the helper executables; the library owns
//! the request encoding, the deadline, process cleanup and output validation.

pub const Image = @import("Image.zig");
pub const Request = @import("Request.zig");
pub const Task = @import("Task.zig");
pub const Theme = @import("Theme.zig");
pub const protocol = @import("protocol.zig");
const render_module = @import("render.zig");

pub const render = render_module.render;
pub const renderTask = render_module.renderTask;

test {
    _ = @import("protocol.zig");
    _ = @import("render.zig");
}
