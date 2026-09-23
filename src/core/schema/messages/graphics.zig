//! Tagged Kitty-graphics messages. The bodies live in `schema/graphics.zig`;
//! this file only adds the wire tag and the client-side flow control.

const RequestGraphicsSnapshot = @import("RequestGraphicsSnapshot.zig");
const codec = @import("../codec.zig");
const tags = @import("tags.zig");
const GraphicsCredit = @import("GraphicsCredit.zig");
const ConfigureGraphics = @import("ConfigureGraphics.zig");
const Snapshot = @import("../Snapshot.zig");
const Encoder = @import("../Encoder.zig");
const bodies = @import("../graphics.zig");
const Image = @import("../Image.zig");
const SharedImage = @import("../SharedImage.zig");
const ImageChunk = @import("../ImageChunk.zig");
const Placement = @import("../Placement.zig");
const DeleteImage = @import("../DeleteImage.zig");
const DeletePlacement = @import("../DeletePlacement.zig");

pub fn encodeRequestGraphicsSnapshot(buffer: []u8, message: RequestGraphicsSnapshot) ![]const u8 {
    return codec.encodeDerived(
        @intFromEnum(tags.ClientTag.request_graphics_snapshot),
        buffer,
        message,
    );
}

pub fn encodeGraphicsCredit(buffer: []u8, message: GraphicsCredit) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.graphics_credit), buffer, message);
}

pub fn encodeConfigureGraphics(buffer: []u8, message: ConfigureGraphics) ![]const u8 {
    return codec.encodeDerived(@intFromEnum(tags.ClientTag.configure_graphics), buffer, message);
}

pub fn encodeGraphicsSnapshot(buffer: []u8, message: Snapshot) ![]const u8 {
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.graphics_snapshot));
    try bodies.encodeSnapshot(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsImage(buffer: []u8, message: Image) ![]const u8 {
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.graphics_image));
    try bodies.encodeImage(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsSharedImage(buffer: []u8, message: SharedImage) ![]const u8 {
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.graphics_shared_image));
    try bodies.encodeSharedImage(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsImageChunk(buffer: []u8, message: ImageChunk) ![]const u8 {
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.graphics_image_chunk));
    try bodies.encodeImageChunk(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsPlacement(buffer: []u8, message: Placement) ![]const u8 {
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.graphics_placement));
    try bodies.encodePlacement(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsDeleteImage(buffer: []u8, message: DeleteImage) ![]const u8 {
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.graphics_delete_image));
    try bodies.encodeDeleteImage(&encoder, message);
    return encoder.finish();
}

pub fn encodeGraphicsDeletePlacement(buffer: []u8, message: DeletePlacement) ![]const u8 {
    var encoder = Encoder.init(buffer);
    try encoder.writeByte(@intFromEnum(tags.ServerTag.graphics_delete_placement));
    try bodies.encodeDeletePlacement(&encoder, message);
    return encoder.finish();
}
