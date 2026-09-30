const Tokens = @import("Tokens.zig");
const SyncInput = @This();

template: []const u8,
tokens: Tokens,
/// Printable text the adapter appends after the rendered template, such
/// as the limit a window's frame stopped at; the template gives way to it.
suffix: []const u8 = "",
