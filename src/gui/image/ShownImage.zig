//! One distinct image the resolved placements show: the generation a
//! placement names and the texture row it draws, if any.
const client = @import("telar-client");

identity: client.ImageIdentity,
texture: ?usize,
