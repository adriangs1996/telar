const Input = @This();
const source_namespace = @import("root.zig");
level: source_namespace.Level = .info,
title: []const u8,
message: []const u8,
target: source_namespace.Target = .none,
duration_ns: u64 = source_namespace.default_duration_ns,
