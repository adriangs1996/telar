export module telar.runtime.terminal.control;

import telar.ghostty.vt;

// The terminal's handles and kitty graphics name types of this interface: VtState tracks rows,
// and graphics queries borrow media budgets.
export import telar.runtime.terminal.ghostty;
export import telar.runtime.terminal.kitty;

export import :capabilities;
export import :classification;
export import :color_queries;
export import :color_value;
export import :cursor_report;
export import :graphics_header;
export import :graphics_payload;
export import :graphics_query;
export import :ordinary;
export import :parameters;
export import :parser;
export import :pty_response_queue;
export import :reply;
export import :reports;
export import :sequence;
export import :size_report;
export import :vt_state;

// The engine's ASCII fast path hands ghostty batches of this many codepoints.
static_assert(telar::runtime::control::ascii_detail::codepoint_capacity == GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT);
