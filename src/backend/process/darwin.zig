//! The libproc and sysctl calls process observation makes on macOS,
//! declared by hand: `libproc.h` pulls in `mach/message.h`, whose bit-field
//! descriptors translate-c can only make opaque, and the SDK's size
//! assertions on them then fail the import. The structs the calls fill are
//! `ProcBsdInfo` and `ProcVnodePathInfo`, each checked against the SDK.

/// The `proc_pidinfo` flavors that fill a `ProcVnodePathInfo` and a
/// `ProcBsdInfo`, and the `proc_listpids` type that lists one process group.
pub const PROC_PIDVNODEPATHINFO: c_int = 9;
pub const PROC_PIDTBSDINFO: c_int = 3;
pub const PROC_PGRP_ONLY: u32 = 2;
/// `CTL_KERN` and `KERN_PROCARGS2` of `sys/sysctl.h`.
pub const CTL_KERN: c_int = 1;
pub const KERN_PROCARGS2: c_int = 49;

pub extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
pub extern "c" fn proc_listpids(kind: u32, typeinfo: u32, buffer: ?*anyopaque, buffersize: c_int) c_int;
pub extern "c" fn sysctl(name: [*]const c_int, namelen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
