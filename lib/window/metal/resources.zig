const objc = @import("objc");
const Object = objc.Object;
const objects = @import("objects.zig");
const PixelFormat = @import("PixelFormat.zig").PixelFormat;
const StorageMode = @import("StorageMode.zig").StorageMode;
const ResourceOptions = @import("ResourceOptions.zig").ResourceOptions;
const TextureUsage = @import("TextureUsage.zig").TextureUsage;
const Region = @import("Region.zig").Region;
const ResourceID = @import("ResourceID.zig").ResourceID;

/// Owned descriptor; release after use. Example: `const descriptor = try newTextureDescriptor();`.
pub fn newTextureDescriptor() !Object {
    return objects.create("MTLTextureDescriptor");
}

/// Owned descriptor; release after use. Example: `const descriptor = try newResidencyDescriptor();`.
pub fn newResidencyDescriptor() !Object {
    return objects.create("MTLResidencySetDescriptor");
}

/// Owned descriptor; release after use. Example: `const descriptor = try newArgumentDescriptor();`.
pub fn newArgumentDescriptor() !Object {
    return objects.create("MTL4ArgumentTableDescriptor");
}

/// Example: `resources.setPixelFormat(descriptor, value)`.
pub fn setPixelFormat(self: Object, value: PixelFormat) void {
    self.msgSend(void, "setPixelFormat:", .{@intFromEnum(value)});
}

/// Example: `resources.setStorageMode(descriptor, value)`.
pub fn setStorageMode(self: Object, value: StorageMode) void {
    self.msgSend(void, "setStorageMode:", .{@intFromEnum(value)});
}

/// Example: `resources.setTextureUsage(descriptor, value)`.
pub fn setTextureUsage(self: Object, value: TextureUsage) void {
    self.msgSend(void, "setUsage:", .{@as(usize, @bitCast(value))});
}

/// Example: `resources.setWidth(descriptor, value)`.
pub fn setWidth(self: Object, value: usize) void {
    self.msgSend(void, "setWidth:", .{value});
}

/// Example: `resources.setHeight(descriptor, value)`.
pub fn setHeight(self: Object, value: usize) void {
    self.msgSend(void, "setHeight:", .{value});
}

/// Example: `resources.setInitialCapacity(descriptor, value)`.
pub fn setInitialCapacity(self: Object, value: usize) void {
    self.msgSend(void, "setInitialCapacity:", .{value});
}

/// Example: `resources.setMaxBufferBindCount(descriptor, value)`.
pub fn setMaxBufferBindCount(self: Object, value: usize) void {
    self.msgSend(void, "setMaxBufferBindCount:", .{value});
}

/// Example: `resources.setMaxTextureBindCount(descriptor, value)`.
pub fn setMaxTextureBindCount(self: Object, value: usize) void {
    self.msgSend(void, "setMaxTextureBindCount:", .{value});
}

/// Owned texture. Example: `resources.newTexture(gpu, descriptor)`.
pub fn newTexture(self: Object, descriptor: Object) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newTextureWithDescriptor:", .{descriptor}));
}

/// Owned buffer. Example: `resources.newBuffer(gpu, bytes, .shared)`.
pub fn newBuffer(self: Object, byte_count: usize, options: ResourceOptions) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newBufferWithLength:options:", .{ byte_count, @intFromEnum(options) }));
}

/// Borrowed property. Example: `resources.contents(resource)`.
pub fn contents(self: Object) ?[*]u8 {
    return self.msgSend(?[*]u8, "contents", .{});
}

/// Borrowed property. Example: `resources.length(resource)`.
pub fn length(self: Object) usize {
    return self.msgSend(usize, "length", .{});
}

/// Borrowed property. Example: `resources.width(resource)`.
pub fn width(self: Object) usize {
    return self.msgSend(usize, "width", .{});
}

/// Borrowed property. Example: `resources.height(resource)`.
pub fn height(self: Object) usize {
    return self.msgSend(usize, "height", .{});
}

/// Borrowed property. Example: `resources.gpuAddress(resource)`.
pub fn gpuAddress(self: Object) u64 {
    return self.msgSend(u64, "gpuAddress", .{});
}

/// Borrowed property. Example: `resources.gpuResourceID(resource)`.
pub fn gpuResourceID(self: Object) ResourceID {
    return self.msgSend(ResourceID, "gpuResourceID", .{});
}

/// Caller validates source extent and synchronization. Example: `resources.replaceRegion(texture, region, 0, pixels.ptr, stride)`.
pub fn replaceRegion(self: Object, region: Region, level: usize, bytes: [*]const u8, stride: usize) void {
    self.msgSend(void, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, level, bytes, stride });
}

/// Example: `resources.addAllocation(self, allocation)`.
pub fn addAllocation(self: Object, allocation: Object) void {
    self.msgSend(void, "addAllocation:", .{allocation});
}

/// Example: `resources.removeAllocation(self, allocation)`.
pub fn removeAllocation(self: Object, allocation: Object) void {
    self.msgSend(void, "removeAllocation:", .{allocation});
}

/// Example: `resources.removeAllAllocations(self)`.
pub fn removeAllAllocations(self: Object) void {
    self.msgSend(void, "removeAllAllocations", .{});
}

/// Example: `resources.commitResidency(self)`.
pub fn commitResidency(self: Object) void {
    self.msgSend(void, "commit", .{});
}

/// Example: `resources.setAddress(self, address, index)`.
pub fn setAddress(self: Object, address: u64, index: usize) void {
    self.msgSend(void, "setAddress:atIndex:", .{ address, index });
}

/// Example: `resources.setTexture(self, resource, index)`.
pub fn setTexture(self: Object, resource: ResourceID, index: usize) void {
    self.msgSend(void, "setTexture:atIndex:", .{ resource, index });
}
