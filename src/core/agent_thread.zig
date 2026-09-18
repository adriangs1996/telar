//! Provider-independent values for runtime-owned agent panes.

pub const max_items = 64;
pub const max_text_bytes = 48 * 1024;
pub const max_prompt_bytes = 8 * 1024;
pub const max_approval_bytes = 4096;
pub const max_models = 16;
pub const max_model_bytes = 128;
pub const max_model_label_bytes = 128;
pub const max_efforts = 8;
pub const max_effort_bytes = 32;
pub const max_metadata_bytes = 16 * 1024;
pub const max_item_title_bytes = 160;
pub const max_item_detail_bytes = 768;
pub const max_item_reference_bytes = 128;
pub const max_item_source_bytes = 128;
pub const max_item_source_turn_bytes = 128;

pub const Status = enum(u8) { starting, ready, working, blocked, failed };
pub const Role = enum(u8) { user, assistant, tool, system };
pub const ItemKind = enum(u8) { message, reasoning, plan, command, file_change, mcp, dynamic_tool, web_search, dispatch, subagent, system };
pub const ItemStatus = enum(u8) { pending, running, completed, failed, interrupted, declined, idle, closed };
pub const MessagePhase = enum(u8) { unknown, commentary, final_answer };
pub const ApprovalKind = enum(u8) { command, file_change };
pub const Access = enum(u8) { read_only, workspace, full_access };
