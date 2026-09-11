const WireManifest = @This();

const Source = struct { url: []const u8, revision: []const u8 };

api_version: u16,
id: []const u8,
version: []const u8,
entry: []const u8,
source: Source,
actions: []const []const u8 = &.{},
capabilities: []const []const u8 = &.{},
