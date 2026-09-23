const core = @import("telar-core");
const vt = @import("ghostty-vt");
const LiveImages = @This();

storage: *const vt.kitty.graphics.ImageStorage,

pub fn holds(self: LiveImages, image_key: core.ImageKey) bool {
    const image = self.storage.imageById(image_key.image_id) orelse return false;
    return image.generation == image_key.generation;
}

pub fn holdsImage(self: LiveImages, image_id: u32) bool {
    return self.storage.imageById(image_id) != null;
}
