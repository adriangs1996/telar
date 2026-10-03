//! The libproc call the lineage walk makes on macOS, declared by hand:
//! `libproc.h` pulls in `mach/message.h`, whose bit-field descriptors
//! translate-c can only make opaque, and the SDK's size assertions on them
//! then fail the import. The struct it fills is `ProcBsdShortInfo`.

/// The `proc_pidinfo` flavor that fills a `ProcBsdShortInfo`.
pub const PROC_PIDT_SHORTBSDINFO: c_int = 13;

pub extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
