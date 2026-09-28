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

// IOKit power sources and the CoreFoundation calls that read them. Every
// `Copy` result is owned by the caller and released with `CFRelease`.
pub const CFTypeRef = ?*const anyopaque;
pub extern "c" fn IOPSCopyPowerSourcesInfo() CFTypeRef;
pub extern "c" fn IOPSCopyPowerSourcesList(blob: CFTypeRef) CFTypeRef;
pub extern "c" fn IOPSGetPowerSourceDescription(blob: CFTypeRef, source: CFTypeRef) CFTypeRef;
pub extern "c" fn CFArrayGetCount(array: CFTypeRef) isize;
pub extern "c" fn CFArrayGetValueAtIndex(array: CFTypeRef, index: isize) CFTypeRef;
pub extern "c" fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) CFTypeRef;
pub extern "c" fn CFNumberGetValue(number: CFTypeRef, number_type: isize, value: *anyopaque) u8;
/// The function behind `CFSTR`: a constant string that is never released.
pub extern "c" fn __CFStringMakeConstantString(c_string: [*:0]const u8) CFTypeRef;
pub extern "c" fn CFRelease(value: CFTypeRef) void;

pub const kCFNumberIntType: isize = 9;
pub const kIOPSCurrentCapacityKey = "Current Capacity";
pub const kIOPSMaxCapacityKey = "Max Capacity";
