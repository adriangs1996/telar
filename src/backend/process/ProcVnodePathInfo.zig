//! `struct proc_vnodepathinfo` of `sys/proc_info.h`, the answer to
//! `proc_pidinfo` with `PROC_PIDVNODEPATHINFO`: a process's current and
//! root directories. Declared by hand; see `darwin.zig`.
const std = @import("std");
const VnodeInfoPath = @import("VnodeInfoPath.zig").VnodeInfoPath;

pub const ProcVnodePathInfo = extern struct {
    pvi_cdir: VnodeInfoPath,
    pvi_rdir: VnodeInfoPath,
};

comptime {
    // `sizeof` on the macOS 26 SDK.
    std.debug.assert(@sizeOf(ProcVnodePathInfo) == 2352);
}
