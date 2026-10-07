// NSRange counts UTF-16 code units when used with AppKit text APIs.
pub const Range = extern struct {
    location: usize = 0,
    length: usize = 0,
};
