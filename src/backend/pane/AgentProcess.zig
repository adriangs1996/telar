const std = @import("std");
io: std.Io,
session: *@import("../agent_panes/Session.zig"),
metadata_revision: u64 = 0,
