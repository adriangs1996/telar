module;
#include "terminal/control/ascii_ordinary.hpp"
#include "terminal/control/capabilities.hpp"
#include "terminal/control/classification.hpp"
#include "terminal/control/color_queries.hpp"
#include "terminal/control/cursor_report.hpp"
#include "terminal/control/graphics_query.hpp"
#include "terminal/control/parser.hpp"
#include "terminal/control/reply.hpp"
#include "terminal/control/reports.hpp"
#include "terminal/control/size_report.hpp"
#include "terminal/control/styled_ordinary.hpp"
#include "terminal/control/vt_state.hpp"
#include "terminal/ghostty_allocator.hpp"

export module telar.runtime.terminal.control;

// The engine's ASCII fast path hands ghostty batches of this many codepoints.
static_assert(telar::runtime::control::ascii_detail::codepoint_capacity == GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT);

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::runtime {
  using telar::runtime::checkGhostty;
  using telar::runtime::FormatterHandle;
  using telar::runtime::GhosttyAllocatorBridge;
  using telar::runtime::GhosttyHandle;
  using telar::runtime::ghosttySized;
  using telar::runtime::GraphicsCursor;
  using telar::runtime::GraphicsQueryResources;
  using telar::runtime::MediaAllocator;
  using telar::runtime::PtyResponseQueue;
  using telar::runtime::RenderStateHandle;
  using telar::runtime::RowCellsHandle;
  using telar::runtime::RowIteratorHandle;
  using telar::runtime::TerminalError;
  using telar::runtime::TerminalHandle;
  using telar::runtime::TrackedRow;
}

export namespace telar::render {
  using telar::render::max_document_bytes;
  using telar::render::max_pane_document_bytes;
  using telar::render::max_pane_documents;
  using telar::render::max_sequence_body;
  using telar::render::sequence_begin;
  using telar::render::sequence_end;
  using telar::render::sequence_number;
}

export namespace telar::runtime::control {
  using telar::runtime::control::capabilities;
  using telar::runtime::control::Capability;
  using telar::runtime::control::capability;
  using telar::runtime::control::ClientFacts;
  using telar::runtime::control::ColorQueries;
  using telar::runtime::control::colorValue;
  using telar::runtime::control::completeAsciiApc;
  using telar::runtime::control::cursorReport;
  using telar::runtime::control::decimal;
  using telar::runtime::control::decodeGraphicsBlock;
  using telar::runtime::control::decodeGraphicsPayload;
  using telar::runtime::control::decodeGraphicsWideBlock;
  using telar::runtime::control::desktop_modes;
  using telar::runtime::control::encodeCapabilities;
  using telar::runtime::control::encoded_capabilities;
  using telar::runtime::control::EncodedCapability;
  using telar::runtime::control::Ending;
  using telar::runtime::control::forwardPrivateMode;
  using telar::runtime::control::graphics_base64_block_input;
  using telar::runtime::control::graphics_base64_block_output;
  using telar::runtime::control::graphics_base64_digits;
  using telar::runtime::control::graphics_base64_tables;
  using telar::runtime::control::graphics_base64_wide_input;
  using telar::runtime::control::graphics_base64_wide_output;
  using telar::runtime::control::GraphicsBase64Lanes;
  using telar::runtime::control::graphicsBase64Lanes;
  using telar::runtime::control::GraphicsBase64Tables;
  using telar::runtime::control::GraphicsHeader;
  using telar::runtime::control::GraphicsQueries;
  using telar::runtime::control::GraphicsQuery;
  using telar::runtime::control::graphicsQuery;
  using telar::runtime::control::hexadecimalColorChannel;
  using telar::runtime::control::intensityColorChannel;
  using telar::runtime::control::Kind;
  using telar::runtime::control::Margins;
  using telar::runtime::control::named_colors;
  using telar::runtime::control::nativeOsc;
  using telar::runtime::control::oscOperation;
  using telar::runtime::control::Parameters;
  using telar::runtime::control::Parser;
  using telar::runtime::control::Position;
  using telar::runtime::control::query;
  using telar::runtime::control::Reply;
  using telar::runtime::control::Report;
  using telar::runtime::control::Reports;
  using telar::runtime::control::Sequence;
  using telar::runtime::control::SizeReport;
  using telar::runtime::control::sizeReport;
  using telar::runtime::control::streamable;
  using telar::runtime::control::styledOrdinaryLength;
  using telar::runtime::control::takeField;
  using telar::runtime::control::VtState;
}

export namespace telar::runtime::control::ascii_detail {
  using telar::runtime::control::ascii_detail::ByteVector;
  using telar::runtime::control::ascii_detail::codepoint_capacity;
  using telar::runtime::control::ascii_detail::eligible;
  using telar::runtime::control::ascii_detail::gate_bytes;
  using telar::runtime::control::ascii_detail::load;
  using telar::runtime::control::ascii_detail::match_bits;
  using telar::runtime::control::ascii_detail::non_ascii_first;
  using telar::runtime::control::ascii_detail::stopMask;
  using telar::runtime::control::ascii_detail::widen;
  using telar::runtime::control::ascii_detail::widenBlock;
}

export namespace telar::runtime::control::styled_detail {
  using telar::runtime::control::styled_detail::Control;
  using telar::runtime::control::styled_detail::ControlScanner;
  using telar::runtime::control::styled_detail::enquiry;
  using telar::runtime::control::styled_detail::escape;
  using telar::runtime::control::styled_detail::numericSgrByte;
  using telar::runtime::control::styled_detail::ShortSgrBlockCache;
  using telar::runtime::control::styled_detail::vector_bytes;
}
