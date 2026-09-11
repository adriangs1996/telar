//! config command grammar.

const std = @import("std");
const core = @import("telar-core");
const backend = @import("telar-backend");
const frontend = @import("telar-frontend");
const pty = backend.pty;
const Cursor = @import("cursor_support.zig").Cursor;

pub const ConfigCheckOptions = @import("ConfigCheckOptions.zig");
