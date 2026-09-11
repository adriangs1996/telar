//! Public entrypoint for telar-lua.

pub const Vm = @import("Vm.zig");
pub const default_callback_deadline_ns = @import("vm_support.zig").default_callback_deadline_ns;
pub const default_callback_instruction_limit = @import("vm_support.zig").default_callback_instruction_limit;
pub const open = @import("sandbox.zig").open;

test {
    _ = @import("sandbox.zig");
    _ = @import("vm_support.zig");
}
