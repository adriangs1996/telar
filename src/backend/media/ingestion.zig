//! Media ingestion protocol over borrowed emulator, quota and response resources.
const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("telar-core");
const media_mod = @import("root.zig");
const shared_transfer = @import("shared_transfer.zig");
const allocation = @import("allocator.zig");
const KittyFramingCounter = @import("../history/root.zig").escape.KittyFramingCounter;
pub const schema = core.schema;
pub const Io = std.Io;

pub const Responses = @import("Responses.zig");

pub const State = @import("State.zig");

pub const Processor = @import("Processor.zig");
