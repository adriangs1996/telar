//! Shared bounded Lua runtime used by disposable frontend and backend workers.

pub const sandbox = @import("sandbox.zig");
pub const vm = @import("vm.zig");

pub const Limits = vm.Limits;
pub const Meter = vm.Meter;
pub const Vm = vm.Vm;
pub const default_callback_deadline_ns = vm.default_callback_deadline_ns;
pub const default_callback_instruction_limit = vm.default_callback_instruction_limit;
pub const hook_instruction_interval = vm.hook_instruction_interval;

test {
    _ = sandbox;
    _ = vm;
}
