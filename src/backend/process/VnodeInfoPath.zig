//! `struct vnode_info_path` of `sys/proc_info.h`: a vnode and the tail of
//! its path. Declared by hand; see `darwin.zig`.
const std = @import("std");
const VnodeInfo = @import("VnodeInfo.zig").VnodeInfo;

/// `MAXPATHLEN` of `sys/syslimits.h`.
pub const max_path_len = 1024;

pub const VnodeInfoPath = extern struct {
    vip_vi: VnodeInfo,
    vip_path: [max_path_len]u8,
};

comptime {
    // `sizeof` and `offsetof` on the macOS 26 SDK.
    std.debug.assert(@sizeOf(VnodeInfoPath) == 1176);
    std.debug.assert(@offsetOf(VnodeInfoPath, "vip_path") == 152);
}
