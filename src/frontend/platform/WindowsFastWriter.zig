const FastWriter = @This();

/// Windows retains the single-flight blocking output actor.
/// Example: `const fast = FastWriter.open();`.
pub fn open() ?FastWriter {
    return null;
}

/// Example: `const count = try FastWriter.writeOpaque(context, bytes);`.
pub fn writeOpaque(_: *anyopaque, _: []const u8) !usize {
    return error.FastOutputUnavailable;
}

/// Example: `fast.deinit();`.
pub fn deinit(_: *FastWriter) void {}
