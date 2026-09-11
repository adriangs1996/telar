/// A `a=q,t=f` capability query the pane answers itself, since the emulator
/// never opens child paths. `bytes` is the whole APC command.
///
/// ```zig
/// pub fn observeFileQuery(sink: *Sink, query: FileQueryView) bool
/// ```
const FileQueryView = @This();

bytes: []const u8,
encoded_path: []const u8,
image_id: u32,
byte_len: usize,
