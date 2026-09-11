const AttachmentsTypesMax_items = @import("telar-client").max_attachments;
const State = @This();

supported: bool = false,
cell_width: u16 = 0,
cell_height: u16 = 0,
next_host_id: u32 = 1,
partial: ?u8 = null,
abort_pending: bool = false,
delete_ids: [AttachmentsTypesMax_items * 2]u32 = undefined,
delete_count: u8 = 0,
delete_all_pending: bool = false,
