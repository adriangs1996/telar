pid: u32,
path: []const u8,
/// The line to place the cursor on; zero leaves the editor's choice.
line: u32 = 0,
/// The column on `line`; zero means its start.
column: u32 = 0,
tty: []const u8 = "",
hostname: []const u8 = "",
