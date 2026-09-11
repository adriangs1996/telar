const EncoderType = @import("Encoder.zig");
const DecoderType = @import("Decoder.zig");
const id = @import("id.zig");
const codec = @import("codec.zig");
const TabLocationType = @import("TabLocation.zig");
const types = @import("types.zig");
const TerminalSizeType = @import("TerminalSize.zig");
const std = @import("std");

pub fn Type(comptime T: type) type {
    const allow_zero_request_id =
        @hasDecl(T, "wire_allow_zero_request_id") and T.wire_allow_zero_request_id;
    return struct {
        pub fn encode(encoder: *EncoderType, message: T) !void {
            if (@hasDecl(T, "validateWire")) {
                try message.validateWire();
            }
            inline for (@typeInfo(T).@"struct".fields) |field| {
                try encodeField(field.type, encoder, @field(message, field.name));
            }
        }

        pub fn decode(decoder: *DecoderType) !T {
            var message: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                @field(message, field.name) = try decodeField(field.type, decoder);
            }
            if (@hasDecl(T, "validateWire")) {
                try message.validateWire();
            }
            return message;
        }

        fn encodeField(comptime F: type, encoder: *EncoderType, value: F) !void {
            switch (F) {
                id.RequestId => {
                    if (!allow_zero_request_id) {
                        try codec.validateRequestId(value);
                    }
                    try encoder.writeInt(u64, id.raw(value));
                },
                id.PaneId => {
                    try codec.validatePaneId(value);
                    try encoder.writeInt(u64, id.raw(value));
                },
                ?id.WorkspaceId => {
                    try encoder.writeByte(@intFromBool(value != null));
                    if (value) |workspace_id| {
                        if (workspace_id == .invalid) {
                            return error.InvalidWorkspaceId;
                        }
                        try encoder.writeInt(u64, id.raw(workspace_id));
                    }
                },
                TabLocationType => try codec.encodeTabLocation(encoder, value),
                types.WorkspaceLocation => try codec.encodeWorkspaceLocation(encoder, value),
                TerminalSizeType => {
                    try value.validate();
                    try codec.encodeSize(encoder, value);
                },
                bool => try encoder.writeByte(@intFromBool(value)),
                u8 => try encoder.writeByte(value),
                u16, u32, u64, i32, i64 => try encoder.writeInt(F, value),
                types.ExitKind, types.TabMoveDirection, types.PaneTextSource, types.PaneTextMode, types.ProxyScope => {
                    try encoder.writeByte(@intFromEnum(value));
                },
                else => @compileError("underivable field type " ++ @typeName(F)),
            }
        }

        fn decodeField(comptime F: type, decoder: *DecoderType) !F {
            return switch (F) {
                id.RequestId => if (allow_zero_request_id)
                    @enumFromInt(try decoder.readInt(u64))
                else
                    try id.request(try decoder.readInt(u64)),
                id.PaneId => try id.pane(try decoder.readInt(u64)),
                ?id.WorkspaceId => if (try decoder.readBool())
                    try id.workspace(try decoder.readInt(u64))
                else
                    null,
                TabLocationType => try codec.decodeTabLocation(decoder),
                types.WorkspaceLocation => try codec.decodeWorkspaceLocation(decoder),
                TerminalSizeType => try codec.decodeSize(decoder),
                bool => try decoder.readBool(),
                u8 => try decoder.readByte(),
                u16, u32, u64, i32, i64 => try decoder.readInt(F),
                types.ExitKind => try codec.decodeExitKind(try decoder.readByte()),
                types.TabMoveDirection => switch (try decoder.readByte()) {
                    0 => .previous,
                    1 => .next,
                    else => return error.InvalidTabMoveDirection,
                },
                types.PaneTextSource => std.enums.fromInt(types.PaneTextSource, try decoder.readByte()) orelse
                    return error.InvalidPaneTextSource,
                types.PaneTextMode => std.enums.fromInt(types.PaneTextMode, try decoder.readByte()) orelse
                    return error.InvalidPaneTextMode,
                types.ProxyScope => try codec.decodeProxyScope(try decoder.readByte()),
                else => @compileError("underivable field type " ++ @typeName(F)),
            };
        }
    };
}
