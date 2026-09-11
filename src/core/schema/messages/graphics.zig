//! Tagged Kitty-graphics messages. The bodies live in `schema/graphics.zig`;
//! this file only adds the wire tag and the client-side flow control.

const wire = @import("../wire.zig");
const id = @import("../id.zig");
const codec = @import("../codec.zig");
const bodies = @import("../graphics.zig");
const tags = @import("tags.zig");

const ClientTag = tags.ClientTag;
const ServerTag = tags.ServerTag;
pub const PaneId = id.PaneId;
const encodeDerived = codec.encodeDerived;

pub const RequestGraphicsSnapshot = @import("RequestGraphicsSnapshot.zig");

pub const GraphicsCredit = @import("GraphicsCredit.zig");

pub const ConfigureGraphics = @import("ConfigureGraphics.zig");

pub fn encodeRequestGraphicsSnapshot(buffer: []u8, message: RequestGraphicsSnapshot) ![]const u8 {
    return encodeDerived(
        @intFromEnum(ClientTag.request_graphics_snapshot),
        buffer,
        message,
    );
}

pub fn encodeGraphicsCredit(buffer: []u8, message: GraphicsCredit) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.graphics_credit), buffer, message);
}

pub fn encodeConfigureGraphics(buffer: []u8, message: ConfigureGraphics) ![]const u8 {
    return encodeDerived(@intFromEnum(ClientTag.configure_graphics), buffer, message);
}

pub fn encodeGraphicsSnapshot(buffer: []u8, message: bodies.Snapshot) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_snapshot));
    try bodies.encodeSnapshot(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsImage(buffer: []u8, message: bodies.Image) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_image));
    try bodies.encodeImage(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsSharedImage(buffer: []u8, message: bodies.SharedImage) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_shared_image));
    try bodies.encodeSharedImage(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsImageChunk(buffer: []u8, message: bodies.ImageChunk) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_image_chunk));
    try bodies.encodeImageChunk(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsPlacement(buffer: []u8, message: bodies.Placement) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_placement));
    try bodies.encodePlacement(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsDeleteImage(buffer: []u8, message: bodies.DeleteImage) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_delete_image));
    try bodies.encodeDeleteImage(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsDeletePlacement(buffer: []u8, message: bodies.DeletePlacement) ![]const u8 {
    var encoder = wire.Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(ServerTag.graphics_delete_placement));
    try bodies.encodeDeletePlacement(&encoder, message);
    return encoder.finish();
}
