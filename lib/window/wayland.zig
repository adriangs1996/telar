// Window, canvas and native input share one C type universe.
const native = @import("native.zig");
pub const c = native.c;
