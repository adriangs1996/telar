//! One change to `machines.json` the window's picker made, written off the
//! event loop. The edit's slices point into the client's own storage, which
//! no other change reuses until this one finishes.
const std = @import("std");
const MachineEdit = @import("MachineEdit.zig");
const MachineEditJob = @This();

edit: MachineEdit,
environ: std.process.Environ,
