/// One grapheme cluster's extent.
const Measured = @This();

/// How many codepoints the cluster spans.
len: usize,
/// How many columns it occupies. Zero for a control character, which the
/// caller turns into a blank column - a zero width cell cannot be
/// addressed by a cursor.
width: u8,
