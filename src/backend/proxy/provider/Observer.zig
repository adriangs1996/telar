const types = @import("../../agent/types.zig");
const Decoder = @import("Decoder.zig");
const request_support = @import("request_support.zig");
/// Owns the body classifier for one candidate provider request.
const Observer = @This();

dialect: types.ApiDialect = .unknown,
claude_decoder: Decoder = .{},
active: bool = false,

/// Initializes one observer at its final memory address.
///
/// ```zig
/// var observer: Observer = .{};
/// observer.init(.anthropic_messages);
/// defer observer.deinit();
/// ```
pub fn init(self: *Observer, dialect: types.ApiDialect) void {
    self.* = .{ .dialect = dialect, .active = true };

    if (dialect == .anthropic_messages) {
        self.claude_decoder.init();
    }
}

/// Feeds one borrowed request-body fragment without retaining it.
///
/// ```zig
/// observer.feed(fragment.payload);
/// ```
pub fn feed(self: *Observer, input: []const u8) void {
    if (!self.active) {
        return;
    }

    switch (self.dialect) {
        .anthropic_messages => self.claude_decoder.feed(input),
        else => {},
    }
}

/// Validates the complete body and returns its semantic classification.
/// Unsupported and malformed request bodies fail closed as auxiliary.
///
/// ```zig
/// const classification = observer.finish();
/// ```
pub fn finish(self: *Observer) request_support.RequestClass {
    if (!self.active) {
        return .auxiliary;
    }

    return switch (self.dialect) {
        .anthropic_messages => if (self.claude_decoder.finish()) .inference else .auxiliary,
        else => .auxiliary,
    };
}

/// Reports whether this observer currently owns a candidate body.
///
/// ```zig
/// if (observer.isActive()) {
///     observer.feed(fragment);
/// }
/// ```
pub fn isActive(self: *const Observer) bool {
    return self.active;
}

/// Releases and erases all provider-specific parsing state.
///
/// ```zig
/// observer.deinit();
/// ```
pub fn deinit(self: *Observer) void {
    if (!self.active) {
        return;
    }

    if (self.dialect == .anthropic_messages) {
        self.claude_decoder.deinit();
    }

    self.dialect = .unknown;
    self.active = false;
}
