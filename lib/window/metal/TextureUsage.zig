pub const TextureUsage = packed struct(usize) {
    shader_read: bool = false,
    shader_write: bool = false,
    render_target: bool = false,
    reserved: u61 = 0,
};
