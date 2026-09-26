const bytecodec = @import("bytecodec");
const std = @import("std");
const OpenEditor = @import("OpenEditor.zig");
const EditorOpened = @import("EditorOpened.zig");
const Encoder = bytecodec.Encoder;
const Decoder = bytecodec.Decoder;
const tags = @import("tags.zig");
const id = @import("../id.zig");

pub fn encodeOpenEditor(buffer: []u8, message: OpenEditor) ![]const u8 {
    try message.validateWire();
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ClientTag.open_editor));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    try encoder.writeSized16(message.editor);
    try encoder.writeSized16(message.path);
    try encoder.writeInt(u32, message.line);
    try encoder.writeInt(u32, message.column);
    return encoder.finish();
}

pub fn decodeOpenEditor(decoder: *Decoder) !OpenEditor {
    const message: OpenEditor = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .pane_id = try id.pane(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
        .editor = try decoder.readSized16(),
        .path = try decoder.readSized16(),
        .line = try decoder.readInt(u32),
        .column = try decoder.readInt(u32),
    };
    try message.validateWire();
    return message;
}

pub fn encodeEditorOpened(buffer: []u8, message: EditorOpened) ![]const u8 {
    try message.validateWire();
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.editor_opened));
    try encoder.writeInt(u64, id.raw(message.request_id));
    try encoder.writeByte(@intFromEnum(message.outcome));
    try encoder.writeInt(u64, id.raw(message.pane_id));
    try encoder.writeInt(u64, message.pane_generation);
    return encoder.finish();
}

pub fn decodeEditorOpened(decoder: *Decoder) !EditorOpened {
    const message: EditorOpened = .{
        .request_id = try id.request(try decoder.readInt(u64)),
        .outcome = std.enums.fromInt(EditorOpened.Outcome, try decoder.readByte()) orelse return error.InvalidEditorOutcome,
        .pane_id = @enumFromInt(try decoder.readInt(u64)),
        .pane_generation = try decoder.readInt(u64),
    };
    try message.validateWire();
    return message;
}
