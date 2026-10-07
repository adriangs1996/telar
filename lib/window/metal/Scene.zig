//! Metal resources for the canvas's quad commands. Used only on its GPU worker.
const std = @import("std");
const metal = @import("metal");
const gfx = @import("gfx");
const Textures = @import("../canvas/Textures.zig");
const Images = @import("Images.zig");
const Scene = @This();
const Binding = enum(usize) { atlas, sprites, diagram_start, image = 2 + gfx.Quad.diagram_slot_count };
const Buffer = enum(usize) { quads, viewport };
const Vertices = enum(usize) { rectangle = 6 };

pipeline: metal.Object,
arguments: metal.Object,
residency: metal.Object,
viewport: metal.Object,
quads: ?metal.Object = null,
quad_count: u32 = 0,
atlas: ?metal.Object = null,
sprites: ?metal.Object = null,
diagrams: [gfx.Quad.diagram_slot_count]?metal.Object = @splat(null),
diagram_versions: [gfx.Quad.diagram_slot_count]u64 = @splat(0),
atlas_version: ?u32 = null,
sprites_version: ?u32 = null,

pub fn init(device: metal.Object, queue: metal.Object) !Scene {
    var failure: metal.Id = null;
    const compiler = try metal.createCompiler(device, &failure);
    defer compiler.release();
    const library = try metal.compileLibrary(compiler, @embedFile("../shaders/quad.metal"), &failure);
    defer library.release();
    const pipeline = try metal.createRenderPipeline(compiler, library, .{
        .vertex = "quad_vertex",
        .fragment = "quad_fragment",
        .format = .bgra8_unorm,
        .blend = .{ .source_rgb = .source_alpha, .destination_rgb = .one_minus_source_alpha, .source_alpha = .one, .destination_alpha = .one_minus_source_alpha },
    }, &failure);
    errdefer pipeline.release();
    const arguments = try metal.createArgumentTable(device, 2, @intFromEnum(Binding.image) + 1, &failure);
    errdefer arguments.release();
    const residency = try metal.createResidencySet(device, 5 + gfx.Quad.diagram_slot_count + gfx.ImageUpload.capacity, &failure);
    errdefer residency.release();
    const viewport = try metal.createBuffer(device, @sizeOf([2]f32), .shared);
    metal.addResidencySet(queue, residency);
    return .{ .pipeline = pipeline, .arguments = arguments, .residency = residency, .viewport = viewport };
}

pub fn deinit(self: *Scene, queue: metal.Object) void {
    metal.clearResidency(self.residency);
    metal.commitResidency(self.residency);
    metal.removeResidencySet(queue, self.residency);
    for (self.diagrams) |texture| {
        if (texture) |value| {
            value.release();
        }
    }

    if (self.atlas) |value| {
        value.release();
    }

    if (self.sprites) |value| {
        value.release();
    }

    if (self.quads) |value| {
        value.release();
    }

    self.viewport.release();
    self.residency.release();
    self.arguments.release();
    self.pipeline.release();
}

/// The prior GPU submission is complete. Retire its residency before replacing
/// pages so a resize does not retain both generations of texture allocations.
pub fn prepare(self: *Scene, device: metal.Object, quads: []const gfx.Quad.Quad, textures: Textures) !void {
    try gfx.DiagramTexture.DiagramTexture.validate(&textures.diagrams);
    metal.clearResidency(self.residency);
    metal.commitResidency(self.residency);
    if (textures.atlas) |pixels| {
        const replaced = try page(device, &self.atlas, textures.atlas_side, .r8_unorm);
        if (replaced) {
            self.atlas_version = null;
        }

        if (self.atlas_version == null or self.atlas_version.? != textures.atlas_version) {
            const partial = self.atlas_version != null and self.atlas_version.? == textures.atlas_dirty_base and textures.atlas_dirty_top < textures.atlas_dirty_bottom and textures.atlas_dirty_bottom <= textures.atlas_side;
            const top = if (partial) textures.atlas_dirty_top else 0;
            const bottom = if (partial) textures.atlas_dirty_bottom else textures.atlas_side;
            metal.uploadTexture(self.atlas.?, .{ .origin = .{ .y = top }, .size = .{ .width = textures.atlas_side, .height = bottom - top } }, 0, pixels + @as(usize, top) * textures.atlas_side, textures.atlas_side);
            self.atlas_version = textures.atlas_version;
        }
    }

    if (textures.sprites) |pixels| {
        if (try page(device, &self.sprites, textures.sprites_side, .rgba8_unorm)) {
            self.sprites_version = null;
        }

        if (self.sprites_version == null or self.sprites_version.? != textures.sprites_version) {
            metal.uploadTexture(self.sprites.?, .{ .size = .{ .width = textures.sprites_side, .height = textures.sprites_side } }, 0, pixels, @as(usize, textures.sprites_side) * 4);
            self.sprites_version = textures.sprites_version;
        }
    }

    for (textures.diagrams, 0..) |source, i| {
        if (self.diagrams[i]) |old| {
            const size = metal.textureSize(old);
            if (source.pixels == null or size.width != source.width or size.height != source.height) {
                old.release();
                self.diagrams[i] = null;
                self.diagram_versions[i] = 0;
            }
        }
    }

    for (textures.diagrams, 0..) |source, i| {
        const pixels = source.pixels orelse continue;
        if (self.diagrams[i] == null) {
            self.diagrams[i] = try metal.createTexture(device, .{ .size = .{ .width = source.width, .height = source.height }, .format = .rgba8_unorm, .storage = .shared, .usage = .{ .shader_read = true } });
        }

        if (self.diagram_versions[i] != source.version) {
            metal.uploadTexture(self.diagrams[i].?, .{ .size = .{ .width = source.width, .height = source.height } }, 0, pixels, @as(usize, source.width) * 4);
            self.diagram_versions[i] = source.version;
        }
    }

    self.quad_count = @intCast(quads.len);
    if (quads.len == 0) {
        return;
    }
    // Solid quads still need valid bindings for every declared shader slot.
    if (self.atlas == null) {
        _ = try page(device, &self.atlas, 1, .r8_unorm);
        metal.uploadTexture(self.atlas.?, .{ .size = .{ .width = 1, .height = 1 } }, 0, &.{255}, 1);
    }

    const bytes = std.mem.sliceAsBytes(quads);
    if (self.quads) |buffer| {
        if (metal.bufferBytes(buffer).?.len < bytes.len) {
            buffer.release();
            self.quads = null;
        }
    }

    if (self.quads == null) {
        self.quads = try metal.createBuffer(device, bytes.len, .shared);
    }

    @memcpy(metal.bufferBytes(self.quads.?).?[0..bytes.len], bytes);
}

fn page(device: metal.Object, texture: *?metal.Object, side: u32, format: @FieldType(metal.TextureOptions, "format")) !bool {
    if (side == 0) {
        return error.InvalidTextureSize;
    }

    if (texture.*) |old| {
        if (metal.textureSize(old).width == side) {
            return false;
        }
        old.release();
        texture.* = null;
    }
    texture.* = try metal.createTexture(device, .{ .size = .{ .width = side, .height = side }, .format = format, .storage = .shared, .usage = .{ .shader_read = true } });
    return true;
}

pub fn encode(self: *Scene, encoder: metal.Object, target: metal.Object, draws: []const gfx.ImageDraw.ImageDraw, images: *Images) void {
    const size = metal.textureSize(target);
    const viewport = [2]f32{ @floatFromInt(size.width), @floatFromInt(size.height) };
    @memcpy(metal.bufferBytes(self.viewport).?, std.mem.asBytes(&viewport));
    metal.setRenderPipeline(encoder, self.pipeline);
    metal.bindBuffer(self.arguments, self.quads.?, @intFromEnum(Buffer.quads));
    metal.bindBuffer(self.arguments, self.viewport, @intFromEnum(Buffer.viewport));
    const atlas = self.atlas.?;
    metal.bindTexture(self.arguments, atlas, @intFromEnum(Binding.atlas));
    metal.bindTexture(self.arguments, self.sprites orelse atlas, @intFromEnum(Binding.sprites));
    metal.bindTexture(self.arguments, atlas, @intFromEnum(Binding.image));
    metal.addAllocation(self.residency, self.viewport);
    metal.addAllocation(self.residency, self.quads.?);
    metal.addAllocation(self.residency, target);
    metal.addAllocation(self.residency, atlas);
    if (self.sprites) |value| {
        metal.addAllocation(self.residency, value);
    }

    for (self.diagrams, 0..) |texture, i| {
        metal.bindTexture(self.arguments, texture orelse atlas, @intFromEnum(Binding.diagram_start) + i);
        if (texture) |value| {
            metal.addAllocation(self.residency, value);
        }
    }

    metal.setArgumentTable(encoder, self.arguments, .{ .vertex = true, .fragment = true });
    const count = self.quad_count;
    var next: u32 = 0;
    for (draws) |draw| {
        if (draw.quad < next or draw.quad >= count) {
            continue;
        }
        run(encoder, next, draw.quad);
        next = draw.quad + 1;
        const image = images.get(draw.handle) orelse continue;
        metal.addAllocation(self.residency, image);
        metal.bindTexture(self.arguments, image, @intFromEnum(Binding.image));
        metal.setArgumentTable(encoder, self.arguments, .{ .vertex = true, .fragment = true });
        run(encoder, draw.quad, next);
    }
    run(encoder, next, count);
    metal.commitResidency(self.residency);
}

fn run(encoder: metal.Object, first: u32, end: u32) void {
    if (first < end) {
        metal.draw(encoder, .{ .vertex_count = @intFromEnum(Vertices.rectangle), .instance_count = end - first, .base_instance = first });
    }
}
