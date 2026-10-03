//! `struct vnode_info` of `sys/proc_info.h`, the vnode inside a
//! `VnodeInfoPath`. Declared by hand; see `darwin.zig`.
const std = @import("std");
const VinfoStat = @import("VinfoStat.zig").VinfoStat;

pub const VnodeInfo = extern struct {
    vi_stat: VinfoStat,
    vi_type: c_int,
    vi_pad: c_int,
    vi_fsid: [2]i32,
};

comptime {
    // `sizeof` on the macOS 26 SDK.
    std.debug.assert(@sizeOf(VnodeInfo) == 152);
}
