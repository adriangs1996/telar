//! The libproc and sysctl calls process observation makes on macOS,
//! declared by hand: `libproc.h` pulls in `mach/message.h`, whose bit-field
//! descriptors translate-c can only make opaque, and the SDK's size
//! assertions on them then fail the import. The layouts mirror
//! `sys/proc_info.h` and are checked against it below.
const std = @import("std");

pub const c = struct {
    /// `MAXPATHLEN` of `sys/syslimits.h`.
    pub const max_path_len = 1024;
    /// The `proc_pidinfo` flavors that fill a `struct_proc_vnodepathinfo`
    /// and a `proc_bsdinfo`, and the `proc_listpids` type that lists one
    /// process group.
    pub const PROC_PIDVNODEPATHINFO: c_int = 9;
    pub const PROC_PIDTBSDINFO: c_int = 3;
    pub const PROC_PGRP_ONLY: u32 = 2;
    /// `MAXCOMLEN` of `sys/param.h`.
    pub const max_comm_len = 16;
    /// `CTL_KERN` and `KERN_PROCARGS2` of `sys/sysctl.h`.
    pub const CTL_KERN: c_int = 1;
    pub const KERN_PROCARGS2: c_int = 49;

    /// `struct proc_bsdinfo` of `sys/proc_info.h`.
    pub const proc_bsdinfo = extern struct {
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

    /// `struct vinfo_stat` of `sys/proc_info.h`.
    pub const struct_vinfo_stat = extern struct {
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

    /// `struct vnode_info` of `sys/proc_info.h`.
    pub const struct_vnode_info = extern struct {
        vi_stat: struct_vinfo_stat,
        vi_type: c_int,
        vi_pad: c_int,
        vi_fsid: [2]i32,
    };

    /// `struct vnode_info_path` of `sys/proc_info.h`.
    pub const struct_vnode_info_path = extern struct {
        vip_vi: struct_vnode_info,
        vip_path: [max_path_len]u8,
    };

    /// `struct proc_vnodepathinfo` of `sys/proc_info.h`.
    pub const struct_proc_vnodepathinfo = extern struct {
        pvi_cdir: struct_vnode_info_path,
        pvi_rdir: struct_vnode_info_path,
    };

    pub extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
    pub extern "c" fn proc_listpids(kind: u32, typeinfo: u32, buffer: ?*anyopaque, buffersize: c_int) c_int;
    pub extern "c" fn sysctl(name: [*]const c_int, namelen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
};

comptime {
    // `sizeof` and `offsetof` of these structs on the macOS 26 SDK.
    std.debug.assert(@sizeOf(c.struct_vinfo_stat) == 136);
    std.debug.assert(@sizeOf(c.struct_vnode_info) == 152);
    std.debug.assert(@sizeOf(c.struct_vnode_info_path) == 1176);
    std.debug.assert(@sizeOf(c.struct_proc_vnodepathinfo) == 2352);
    std.debug.assert(@offsetOf(c.struct_vnode_info_path, "vip_path") == 152);
    std.debug.assert(@sizeOf(c.proc_bsdinfo) == 136);
    std.debug.assert(@offsetOf(c.proc_bsdinfo, "pbi_comm") == 48);
    std.debug.assert(@offsetOf(c.proc_bsdinfo, "pbi_start_tvsec") == 120);
}
