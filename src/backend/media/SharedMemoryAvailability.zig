const FrameResource = @import("FrameResource.zig");
const media = @import("media.zig");
const shared_transfer = @import("shared_transfer.zig");
const SharedMemoryAvailability = @This();

pub fn available(_: SharedMemoryAvailability, resource: FrameResource) bool {
    return switch (resource.medium) {
        .shared => media.sharedFrameAvailable(resource),
        .file => resource.byte_len <= resource.limit and
            shared_transfer.validateChildFile(resource.encoded_name, resource.byte_len),
    };
}
