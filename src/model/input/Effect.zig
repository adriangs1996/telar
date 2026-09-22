const copy_mode = @import("copy_mode.zig");
/// What one handled key asks the client to do. Cursor, selection and
/// viewport changes already happened inside the state; the client only
/// projects them and, on exit, copies the selection.
const Effect = @This();

handled: bool = true,
exit: bool = false,
copy: bool = false,
/// Ask the client to open the search input in this direction.
search: ?copy_mode.Direction = null,
/// Ask the client to open the textual link under the copy cursor.
open_link: bool = false,
