/// The newest lines of a pane's text, and whether older lines were dropped
/// before the first one.
const TextTail = @This();

text: []const u8,
truncated: bool,
