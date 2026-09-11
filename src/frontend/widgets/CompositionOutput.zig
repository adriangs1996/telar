const Output = @This();
const sidebar_module = @import("sidebar.zig");
const context_mod = @import("context_support.zig");
sidebar: sidebar_module.Semantic,
cursor: ?context_mod.Cursor,
