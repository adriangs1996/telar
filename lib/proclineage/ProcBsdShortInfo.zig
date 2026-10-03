//! `struct proc_bsdshortinfo` of `sys/proc_info.h`, the answer to
//! `proc_pidinfo` with `PROC_PIDT_SHORTBSDINFO`. Declared by hand because
//! `libproc.h` pulls in `mach/message.h`, whose bit-field descriptors
//! translate-c can only make opaque, and the SDK's size assertions on them
//! then fail the import.
const std = @import("std");

/// `MAXCOMLEN` of `sys/param.h`.
pub const max_comm_len = 16;

pub const ProcBsdShortInfo = extern struct {
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

comptime {
    // `sizeof` and `offsetof` on the macOS 26 SDK.
    std.debug.assert(@sizeOf(ProcBsdShortInfo) == 64);
    std.debug.assert(@offsetOf(ProcBsdShortInfo, "pbsi_ppid") == 4);
}
