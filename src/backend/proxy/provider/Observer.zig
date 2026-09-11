const types = @import("../../agent/types.zig");
const DecoderType = @import("Decoder.zig");
const request_support = @import("request_support.zig");
/// Owns the body classifier for one candidate provider request.
const Observer = @This();

dialect: types.ApiDialect = .unknown,
claude_decoder: DecoderType = .{},
active: bool = false,

/// Initializes one observer at its final memory address.
///
/// ```zig
/// var observer: Observer = .{};
/// observer.init(.anthropic_messages);
/// defer observer.deinit();
/// ```
pub fn init(observer: *Observer, dialect: types.ApiDialect) void {
    observer.* = .{ .dialect = dialect, .active = true };

    if (dialect == .anthropic_messages) {
        observer.claude_decoder.init();
    }
}

/// Feeds one borrowed request-body fragment without retaining it.
///
/// ```zig
/// observer.feed(fragment.payload);
/// ```
pub fn feed(observer: *Observer, input: []const u8) void {
    if (!observer.active) {
        return;
    }

    switch (observer.dialect) {
        .anthropic_messages => observer.claude_decoder.feed(input),
        else => {},
    }
}

/// Validates the complete body and returns its semantic classification.
/// Unsupported and malformed request bodies fail closed as auxiliary.
///
/// ```zig
/// const classification = observer.finish();
/// ```
pub fn finish(observer: *Observer) request_support.RequestClass {
    if (!observer.active) {
        return .auxiliary;
    }

    return switch (observer.dialect) {
        .anthropic_messages => if (observer.claude_decoder.finish()) .inference else .auxiliary,
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
pub fn isActive(observer: *const Observer) bool {
    return observer.active;
}

/// Releases and erases all provider-specific parsing state.
///
/// ```zig
/// observer.deinit();
/// ```
pub fn deinit(observer: *Observer) void {
    if (!observer.active) {
        return;
    }

    if (observer.dialect == .anthropic_messages) {
        observer.claude_decoder.deinit();
    }

    observer.dialect = .unknown;
    observer.active = false;
}
