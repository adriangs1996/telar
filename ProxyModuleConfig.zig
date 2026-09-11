const ProxyModuleConfig = @This();
const std = @import("std");
const ProxyPrefixes = @import("ProxyPrefixes.zig");
target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
tls: *std.Build.Module,
vt: *std.Build.Module,
prefixes: ProxyPrefixes,
