const vt = @import("ghostty-vt");
const ImageKeyType = @import("telar-core").ImageKey;
const LiveImages = @This();

storage: *const vt.kitty.graphics.ImageStorage,

pub fn holds(alive: LiveImages, image_key: ImageKeyType) bool {
    const image = alive.storage.imageById(image_key.image_id) orelse return false;
    return image.generation == image_key.generation;
}

pub fn holdsImage(alive: LiveImages, image_id: u32) bool {
    return alive.storage.imageById(image_id) != null;
}
