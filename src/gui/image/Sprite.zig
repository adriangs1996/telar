//! One cell of the RGBA sprite page, addressed by index. The page turns it
//! into texture coordinates; nothing else reads the index.
const Sprite = @This();

index: u16,
