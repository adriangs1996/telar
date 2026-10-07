//! Narrow GLib/ATK ABI used by the accessibility worker. Opaque handles stay on
//! that worker. GObject class registration and interface vtables live in C.
const native = @import("../native.zig");
const c = native.c;
pub const MainLoop = opaque {};
const Source = opaque {};
pub const source_continue: c_int = 1;
pub extern "c" fn g_main_loop_new(context: ?*anyopaque, running: c_int) ?*MainLoop;
pub extern "c" fn g_main_loop_unref(loop: *MainLoop) void;
pub extern "c" fn g_main_loop_run(loop: *MainLoop) void;
pub extern "c" fn g_main_loop_quit(loop: *MainLoop) void;
pub extern "c" fn g_unix_fd_source_new(fd: c_int, condition: c_int) *Source;
pub extern "c" fn g_source_set_callback(source: *Source, callback: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque, destroy: ?*const fn (?*anyopaque) callconv(.c) void) void;
pub extern "c" fn g_source_attach(source: *Source, context: ?*anyopaque) c_uint;
pub extern "c" fn g_source_destroy(source: *Source) void;
pub extern "c" fn g_source_unref(source: *Source) void;
pub extern "c" fn g_object_unref(object: ?*anyopaque) void;
pub extern "c" fn g_signal_emit_by_name(object: ?*anyopaque, signal: [*:0]const u8, ...) void;
pub extern "c" fn atk_object_get_parent(object: ?*c.AtkObject) ?*c.AtkObject;
pub extern "c" fn atk_object_get_n_accessible_children(object: ?*c.AtkObject) c_int;
pub extern "c" fn atk_object_ref_accessible_child(object: ?*c.AtkObject, index: c_int) ?*c.AtkObject;
pub extern "c" fn atk_bridge_adaptor_cleanup() void;
