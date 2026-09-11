const std = @import("std");
const ProxyPrefixes = @import("ProxyPrefixes.zig");
const ProxyModuleConfig = @This();

target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
tls: *std.Build.Module,
vt: *std.Build.Module,
prefixes: ProxyPrefixes,
