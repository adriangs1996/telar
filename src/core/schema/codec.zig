//! Shared validators, composite-value codecs, and the derived fixed-layout
//! serializer used by `messages.zig`.

const std = @import("std");
const wire = @import("wire.zig");
const id = @import("id.zig");
const types = @import("types.zig");

// -- validators -------------------------------------------------------------

pub fn validateRequestId(request_id: id.RequestId) !void {
    if (request_id == .none) return error.InvalidRequestId;
}

pub fn validatePaneId(pane_id: id.PaneId) !void {
    if (pane_id == .invalid) return error.InvalidPaneId;
}

pub fn validateBytes(bytes: []const u8, maximum: usize, empty_allowed: bool) !void {
    if ((!empty_allowed and bytes.len == 0) or bytes.len > maximum)
        return error.InvalidByteString;
    if (std.mem.findScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
}

pub fn validateEnvironmentEntry(entry: types.EnvironmentEntry) !void {
    try validateBytes(entry.name, std.math.maxInt(u16), false);
    try validateBytes(entry.value, std.math.maxInt(u32), true);
    if (std.mem.findScalar(u8, entry.name, '=') != null) return error.InvalidEnvironmentName;
}

pub fn validateErrorMessage(message: []const u8) !void {
    if (message.len > types.max_error_message_bytes) return error.ErrorMessageTooLarge;
    if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
}

pub fn validateTabLabel(label: []const u8, empty_allowed: bool) !void {
    try validateBytes(label, types.max_tab_label_bytes, empty_allowed);
    if (!std.unicode.utf8ValidateSlice(label)) return error.InvalidUtf8;
    for (label) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidTabLabel;
}

// -- composite values -------------------------------------------------------

pub fn encodeSize(encoder: *wire.Encoder, size: types.TerminalSize) !void {
    try encoder.writeInt(u16, size.cols);
    try encoder.writeInt(u16, size.rows);
    try encoder.writeInt(u16, size.cell_width_px);
    try encoder.writeInt(u16, size.cell_height_px);
}

pub fn decodeSize(decoder: *wire.Decoder) !types.TerminalSize {
    const size = types.TerminalSize{
        .cols = try decoder.readInt(u16),
        .rows = try decoder.readInt(u16),
        .cell_width_px = try decoder.readInt(u16),
        .cell_height_px = try decoder.readInt(u16),
    };
    try size.validate();
    return size;
}

pub fn encodeTabLocation(encoder: *wire.Encoder, location: types.TabLocation) !void {
    try encodeWorkspaceLocation(encoder, location.workspace);
    if (location.tab_id == .invalid) return error.InvalidTabId;
    try encoder.writeInt(u64, id.raw(location.tab_id));
}

pub fn encodeWorkspaceLocation(
    encoder: *wire.Encoder,
    location: types.WorkspaceLocation,
) !void {
    switch (location) {
        .workspace => |workspace_id| {
            if (workspace_id == .invalid) return error.InvalidWorkspaceId;
            try encoder.writeByte(0);
            try encoder.writeInt(u64, id.raw(workspace_id));
        },
        .worktree => |worktree_id| {
            if (worktree_id == .invalid) return error.InvalidWorktreeId;
            try encoder.writeByte(1);
            try encoder.writeInt(u64, id.raw(worktree_id));
        },
    }
}

pub fn decodeTabLocation(decoder: *wire.Decoder) !types.TabLocation {
    return .{
        .workspace = try decodeWorkspaceLocation(decoder),
        .tab_id = try id.tab(try decoder.readInt(u64)),
    };
}

pub fn decodeWorkspaceLocation(decoder: *wire.Decoder) !types.WorkspaceLocation {
    return switch (try decoder.readByte()) {
        0 => .{ .workspace = try id.workspace(try decoder.readInt(u64)) },
        1 => .{ .worktree = try id.worktree(try decoder.readInt(u64)) },
        else => error.InvalidWorkspaceLocation,
    };
}

// -- enums ------------------------------------------------------------------

pub fn decodeEnvironmentMode(value: u8) error{InvalidEnvironmentMode}!types.EnvironmentMode {
    return std.enums.fromInt(types.EnvironmentMode, value) orelse error.InvalidEnvironmentMode;
}

pub fn decodeExitKind(value: u8) error{InvalidExitKind}!types.ExitKind {
    return std.enums.fromInt(types.ExitKind, value) orelse error.InvalidExitKind;
}

pub fn decodePaneLifecycle(value: u8) error{InvalidPaneLifecycle}!types.PaneLifecycle {
    return std.enums.fromInt(types.PaneLifecycle, value) orelse error.InvalidPaneLifecycle;
}

pub fn decodeHistoryScope(value: u8) error{InvalidHistoryScope}!types.HistoryScope {
    return std.enums.fromInt(types.HistoryScope, value) orelse error.InvalidHistoryScope;
}

pub fn decodeHistoryStatus(value: u8) error{InvalidHistoryStatus}!types.HistoryStatus {
    return std.enums.fromInt(types.HistoryStatus, value) orelse error.InvalidHistoryStatus;
}

pub fn decodeFailureCode(value: u16) error{UnknownFailureCode}!types.FailureCode {
    return std.enums.fromInt(types.FailureCode, value) orelse error.UnknownFailureCode;
}

// -- derived fixed-layout serialization -------------------------------------
//
// Messages whose wire layout is exactly their declared field order get their
// encoder and decoder from the struct definition, so a field cannot exist in
// one direction and not the other. A message may declare
// `pub const wire_allow_zero_request_id = true` to permit `RequestId.none`,
// and `pub fn validateWire(message) !void` for rules beyond field types.
// Variable-length messages (views, iterators, raw tails) stay hand-written.

pub fn Derived(comptime T: type) type {
    const allow_zero_request_id =
        @hasDecl(T, "wire_allow_zero_request_id") and T.wire_allow_zero_request_id;
    return struct {
        pub fn encode(encoder: *wire.Encoder, message: T) !void {
            if (@hasDecl(T, "validateWire")) try message.validateWire();
            inline for (@typeInfo(T).@"struct".fields) |field| {
                try encodeField(field.type, encoder, @field(message, field.name));
            }
        }

        pub fn decode(decoder: *wire.Decoder) !T {
            var message: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                @field(message, field.name) = try decodeField(field.type, decoder);
            }
            if (@hasDecl(T, "validateWire")) try message.validateWire();
            return message;
        }

        fn encodeField(comptime F: type, encoder: *wire.Encoder, value: F) !void {
            switch (F) {
                id.RequestId => {
                    if (!allow_zero_request_id) try validateRequestId(value);
                    try encoder.writeInt(u64, id.raw(value));
                },
                id.PaneId => {
                    try validatePaneId(value);
                    try encoder.writeInt(u64, id.raw(value));
                },
                types.TabLocation => try encodeTabLocation(encoder, value),
                types.WorkspaceLocation => try encodeWorkspaceLocation(encoder, value),
                types.TerminalSize => {
                    try value.validate();
                    try encodeSize(encoder, value);
                },
                bool => try encoder.writeByte(@intFromBool(value)),
                u16, u32, u64, i32, i64 => try encoder.writeInt(F, value),
                types.ExitKind, types.TabMoveDirection => {
                    try encoder.writeByte(@intFromEnum(value));
                },
                else => @compileError("underivable field type " ++ @typeName(F)),
            }
        }

        fn decodeField(comptime F: type, decoder: *wire.Decoder) !F {
            return switch (F) {
                id.RequestId => if (allow_zero_request_id)
                    @enumFromInt(try decoder.readInt(u64))
                else
                    try id.request(try decoder.readInt(u64)),
                id.PaneId => try id.pane(try decoder.readInt(u64)),
                types.TabLocation => try decodeTabLocation(decoder),
                types.WorkspaceLocation => try decodeWorkspaceLocation(decoder),
                types.TerminalSize => try decodeSize(decoder),
                bool => try decoder.readBool(),
                u16, u32, u64, i32, i64 => try decoder.readInt(F),
                types.ExitKind => try decodeExitKind(try decoder.readByte()),
                types.TabMoveDirection => switch (try decoder.readByte()) {
                    0 => .previous,
                    1 => .next,
                    else => return error.InvalidTabMoveDirection,
                },
                else => @compileError("underivable field type " ++ @typeName(F)),
            };
        }
    };
}

pub fn encodeDerived(comptime tag: u8, comptime T: type, buffer: []u8, message: T) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(tag);
    try Derived(T).encode(&encoder, message);
    return encoder.finish();
}
