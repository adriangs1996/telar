/// Terminal-browser publishes complete shared-memory replacements inside one
/// synchronized-output envelope. A busy media actor only needs the newest
/// replacement for each placement; mapping older frames would spend the pane
/// quota and then overwrite the result. Bytes outside this exact shape remain
/// untouched and therefore keep Ghostty as the sole terminal emulator.
const FilterStats = @This();

discarded: u64 = 0,
unavailable: u64 = 0,
forwarded: u64 = 0,
/// The subset of `forwarded` the sink loaded without the parser.
direct: u64 = 0,
/// The subset of `direct` whose pixels came from a child file.
file: u64 = 0,
