/// Presentation values, already reduced by the transport layer. Memory is in
/// tenths of a GiB so formatting never touches floating point.
const Metrics = @This();

cpu_percent: u8,
memory_used_decigib: u16,
battery_percent: ?u8,
