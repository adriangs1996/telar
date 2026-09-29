//! One cell of the RGBA sprite page: a slot and the size inside it. The page
//! turns it into texture coordinates; nothing else reads the slot.
const SpriteSize = @import("SpriteSize.zig").SpriteSize;
const Sprite = @This();

index: u16,
size: SpriteSize = .large,
