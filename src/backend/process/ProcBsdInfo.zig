//! `struct proc_bsdinfo` of `sys/proc_info.h`, the answer to `proc_pidinfo`
//! with `PROC_PIDTBSDINFO`. Declared by hand; see `darwin.zig`.
const std = @import("std");

/// `MAXCOMLEN` of `sys/param.h`.
pub const max_comm_len = 16;

pub const ProcBsdInfo = extern struct {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [max_comm_len]u8,
    pbi_name: [2 * max_comm_len]u8,
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
};

comptime {
    // `sizeof` and `offsetof` on the macOS 26 SDK.
    std.debug.assert(@sizeOf(ProcBsdInfo) == 136);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_comm") == 48);
    std.debug.assert(@offsetOf(ProcBsdInfo, "pbi_start_tvsec") == 120);
}
