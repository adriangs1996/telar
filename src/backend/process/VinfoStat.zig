//! `struct vinfo_stat` of `sys/proc_info.h`, the stat block inside a
//! `VnodeInfo`. Declared by hand because `libproc.h` cannot come through
//! translate-c on the macOS 26 SDK (see `darwin.zig`).
const std = @import("std");

pub const VinfoStat = extern struct {
    vst_dev: u32,
    vst_mode: u16,
    vst_nlink: u16,
    vst_ino: u64,
    vst_uid: u32,
    vst_gid: u32,
    vst_atime: i64,
    vst_atimensec: i64,
    vst_mtime: i64,
    vst_mtimensec: i64,
    vst_ctime: i64,
    vst_ctimensec: i64,
    vst_birthtime: i64,
    vst_birthtimensec: i64,
    vst_size: i64,
    vst_blocks: i64,
    vst_blksize: i32,
    vst_flags: u32,
    vst_gen: u32,
    vst_rdev: u32,
    vst_qspare: [2]i64,
};

comptime {
    // `sizeof` on the macOS 26 SDK.
    std.debug.assert(@sizeOf(VinfoStat) == 136);
}
