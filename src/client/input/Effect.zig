/// What one handled key asks the client to do. Cursor, selection and
/// viewport changes already happened inside the state; the client only
/// projects them and, on exit, copies the selection.
const Effect = @This();
const source_namespace = @import("copy_mode.zig");
handled: bool = true,
exit: bool = false,
copy: bool = false,
/// Ask the client to open the search input in this direction.
search: ?source_namespace.Direction = null,
/// Ask the client to open the textual link under the copy cursor.
open_link: bool = false,
