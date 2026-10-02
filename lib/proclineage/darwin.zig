//! The libproc calls the lineage walk makes on macOS, declared by hand:
//! `libproc.h` pulls in `mach/message.h`, whose bit-field descriptors
//! translate-c can only make opaque, and the SDK's size assertions on them
//! then fail the import. The layouts mirror `sys/proc_info.h` and are
//! checked against it below.
const std = @import("std");

pub const c = struct {
    /// `MAXCOMLEN` of `sys/param.h`.
    pub const max_comm_len = 16;
    /// The `proc_pidinfo` flavor that fills a `proc_bsdshortinfo`.
    pub const PROC_PIDT_SHORTBSDINFO: c_int = 13;

    /// `struct proc_bsdshortinfo` of `sys/proc_info.h`.
    pub const proc_bsdshortinfo = extern struct {
        pbsi_pid: u32,
        pbsi_ppid: u32,
        pbsi_pgid: u32,
        pbsi_status: u32,
        pbsi_comm: [max_comm_len]u8,
        pbsi_flags: u32,
        pbsi_uid: u32,
        pbsi_gid: u32,
        pbsi_ruid: u32,
        pbsi_rgid: u32,
        pbsi_svuid: u32,
        pbsi_svgid: u32,
        pbsi_rfu: u32,
    };

    pub extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
};

comptime {
    // `sizeof(struct proc_bsdshortinfo)` and `offsetof(..., pbsi_ppid)`
    // on the macOS 26 SDK.
    std.debug.assert(@sizeOf(c.proc_bsdshortinfo) == 64);
    std.debug.assert(@offsetOf(c.proc_bsdshortinfo, "pbsi_ppid") == 4);
}
