const objc = @import("objc");
const Object = objc.Object;
const objects = @import("objects.zig");
const GPUFamily = @import("GPUFamily.zig").GPUFamily;

extern "Metal" fn MTLCreateSystemDefaultDevice() objc.c.id;

/// Owned default device, or null without a GPU. Example: `const gpu = device.create() orelse return error.NoDevice;`.
pub fn create() ?Object {
    const raw = MTLCreateSystemDefaultDevice();
    if (raw == null) {
        return null;
    }

    return Object.fromId(raw);
}

/// Example: `device.supportsFamily(gpu, .metal4)`.
pub fn supportsFamily(self: Object, family: GPUFamily) bool {
    return self.msgSend(bool, "supportsFamily:", .{@intFromEnum(family)});
}

/// Owned result. Example: `const value = device.newCommandQueue(gpu) orelse return error.CreationFailed;`.
pub fn newCommandQueue(self: Object) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newMTL4CommandQueue", .{}));
}

/// Owned result. Example: `const value = device.newCommandBuffer(gpu) orelse return error.CreationFailed;`.
pub fn newCommandBuffer(self: Object) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newCommandBuffer", .{}));
}

/// Owned result. Example: `const value = device.newCommandAllocator(gpu) orelse return error.CreationFailed;`.
pub fn newCommandAllocator(self: Object) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newCommandAllocator", .{}));
}

/// Owned result; NSError is borrowed. Example: `device.newCompiler(gpu, descriptor, &failure)`.
pub fn newCompiler(self: Object, descriptor: Object, failure: *objc.c.id) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newCompilerWithDescriptor:error:", .{ descriptor, failure }));
}

/// Owned result; NSError is borrowed. Example: `device.newResidencySet(gpu, descriptor, &failure)`.
pub fn newResidencySet(self: Object, descriptor: Object, failure: *objc.c.id) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newResidencySetWithDescriptor:error:", .{ descriptor, failure }));
}

/// Owned result; NSError is borrowed. Example: `device.newArgumentTable(gpu, descriptor, &failure)`.
pub fn newArgumentTable(self: Object, descriptor: Object, failure: *objc.c.id) ?Object {
    return objects.optional(self.msgSend(objc.c.id, "newArgumentTableWithDescriptor:error:", .{ descriptor, failure }));
}
