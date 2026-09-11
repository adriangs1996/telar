const std = @import("std");

// These declarations must match the Darwin C ABI exactly.
pub extern "c" fn mach_host_self() std.c.mach_port_t;
pub extern "c" fn host_statistics64(host: std.c.mach_port_t, flavor: c_int, info: [*]u32, count: *u32) c_int;
pub extern "c" fn getpagesize() c_int;

pub const HOST_CPU_LOAD_INFO: c_int = 3;
pub const HOST_VM_INFO64: c_int = 4;
pub const cpu_load_words = 4;
pub const vm_info_words = 38;
// Word offsets into `vm_statistics64`: four natural_t counters first,
// u64 fields take two words each. Only the ones used below are named.
pub const vm_active_word = 1;
pub const vm_wire_word = 3;
pub const vm_compressor_word = 32;
