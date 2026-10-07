pub const RenderStages = packed struct(usize) {
    vertex: bool = false,
    fragment: bool = false,
    reserved: u62 = 0,
};
