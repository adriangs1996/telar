//! Public entrypoint for telar-lua.

const vm_support = @import("vm_support.zig");
const sandbox = @import("sandbox.zig");
pub const Vm = @import("Vm.zig");
pub const default_callback_deadline_ns = vm_support.default_callback_deadline_ns;
pub const default_callback_instruction_limit = vm_support.default_callback_instruction_limit;
pub const open = sandbox.open;

test {
    _ = @import("sandbox.zig");
    _ = @import("vm_support.zig");
}
