const std = @import("std");
const Watch = @import("../Watch.zig");
const Job = @This();

io: std.Io,
watch: Watch
