const SharedMemoryAvailability = @This();
const FrameResource = @import("FrameResource.zig");
const source_namespace = @import("root.zig");
const shared_transfer = @import("shared_transfer.zig");
pub fn available(_: SharedMemoryAvailability, resource: FrameResource) bool {
    return switch (resource.medium) {
        .shared => source_namespace.sharedFrameAvailable(resource),
        .file => resource.byte_len <= resource.limit and
            shared_transfer.validateChildFile(resource.encoded_name, resource.byte_len),
    };
}
