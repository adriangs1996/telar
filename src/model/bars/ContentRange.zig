//! A byte range inside a component list's text or sample storage.
const ContentRange = @This();

offset: u16 = 0,
len: u16 = 0,

pub fn isEmpty(self: ContentRange) bool {
    return self.len == 0;
}
