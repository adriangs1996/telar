//! Runtime ownership for trusted long-lived tap plugin workers.

const std = @import("std");
const plugins = @import("../../plugins/root.zig");

pub const Io = std.Io;

pub const Runtime = @import("PluginsRuntime.zig");
