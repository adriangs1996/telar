//! Public entrypoint for telar-lua.

const vm_support = @import("vm_support.zig");
const sandbox = @import("sandbox.zig");
pub const Vm = @import("Vm.zig");
pub const Limits = @import("Limits.zig");
pub const default_load_deadline_ns = vm_support.default_load_deadline_ns;
pub const default_load_instruction_limit = vm_support.default_load_instruction_limit;
pub const default_callback_deadline_ns = vm_support.default_callback_deadline_ns;
pub const default_callback_instruction_limit = vm_support.default_callback_instruction_limit;
pub const default_render_instruction_limit = vm_support.default_render_instruction_limit;
pub const default_render_deadline_ns = vm_support.default_render_deadline_ns;
pub const open = sandbox.open;
pub const json = @import("json.zig");

test {
    _ = @import("sandbox.zig");
    _ = @import("vm_support.zig");
    _ = @import("json.zig");
}
