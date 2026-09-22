const RepeatPolicy = @This();

interval_ns: u64,
/// An owner token, such as the focused pane ID. A changed token cancels hold.
context: u64,
