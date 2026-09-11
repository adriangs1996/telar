const wire = @import("wire.zig");
const id = @import("id.zig");
const source_namespace = @import("codec.zig");
const types = @import("types.zig");
const std = @import("std");
pub fn Type(comptime T: type) type {
    const allow_zero_request_id =
        @hasDecl(T, "wire_allow_zero_request_id") and T.wire_allow_zero_request_id;
    return struct {
        pub fn encode(encoder: *wire.Encoder, message: T) !void {
            if (@hasDecl(T, "validateWire")) {
                try message.validateWire();
            }
            inline for (@typeInfo(T).@"struct".fields) |field| {
                try encodeField(field.type, encoder, @field(message, field.name));
            }
        }

        pub fn decode(decoder: *wire.Decoder) !T {
            var message: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                @field(message, field.name) = try decodeField(field.type, decoder);
            }
            if (@hasDecl(T, "validateWire")) {
                try message.validateWire();
            }
            return message;
        }

        fn encodeField(comptime F: type, encoder: *wire.Encoder, value: F) !void {
            switch (F) {
                id.RequestId => {
                    if (!allow_zero_request_id) {
                        try source_namespace.validateRequestId(value);
                    }
                    try encoder.writeInt(u64, id.raw(value));
                },
                id.PaneId => {
                    try source_namespace.validatePaneId(value);
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
                types.TabLocation => try source_namespace.encodeTabLocation(encoder, value),
                types.WorkspaceLocation => try source_namespace.encodeWorkspaceLocation(encoder, value),
                types.TerminalSize => {
                    try value.validate();
                    try source_namespace.encodeSize(encoder, value);
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

        fn decodeField(comptime F: type, decoder: *wire.Decoder) !F {
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
                types.TabLocation => try source_namespace.decodeTabLocation(decoder),
                types.WorkspaceLocation => try source_namespace.decodeWorkspaceLocation(decoder),
                types.TerminalSize => try source_namespace.decodeSize(decoder),
                bool => try decoder.readBool(),
                u8 => try decoder.readByte(),
                u16, u32, u64, i32, i64 => try decoder.readInt(F),
                types.ExitKind => try source_namespace.decodeExitKind(try decoder.readByte()),
                types.TabMoveDirection => switch (try decoder.readByte()) {
                    0 => .previous,
                    1 => .next,
                    else => return error.InvalidTabMoveDirection,
                },
                types.PaneTextSource => std.enums.fromInt(types.PaneTextSource, try decoder.readByte()) orelse
                    return error.InvalidPaneTextSource,
                types.PaneTextMode => std.enums.fromInt(types.PaneTextMode, try decoder.readByte()) orelse
                    return error.InvalidPaneTextMode,
                types.ProxyScope => try source_namespace.decodeProxyScope(try decoder.readByte()),
                else => @compileError("underivable field type " ++ @typeName(F)),
            };
        }
    };
}
