#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

// What a terminal needs to recognize a document without importing the
// renderers: textual control headers include this, modules re-export it.
//
// A program hands its pane a document with one OSC:
//
//   ESC ] 7780 ; begin ; <base64 of the encoding> ESC \
//
// On the alternate screen the document covers the pane until the program
// leaves that screen. On the primary screen it opens a zone at the cursor's
// row: the output that follows, up to ESC ] 7780 ; end ESC \, is the text
// the document stands for, and a client that can draw the document shows it
// in place of those rows.
namespace telar::render {

  inline constexpr unsigned sequence_number = 7780;
  inline constexpr std::string_view sequence_begin = "7780;begin;";
  inline constexpr std::string_view sequence_end = "7780;end";

  // Limit render.max_document_bytes: the largest encoded document a renderer
  // writes and a decoder accepts. Its sequence fits the 8 MiB a terminal
  // buffers for one OSC.
  inline constexpr std::size_t max_document_bytes = std::size_t{6000} * 1024;

  // Limits render.max_pane_documents and render.max_pane_document_bytes: the
  // documents a terminal keeps for one pane's scrollback. Past either, the
  // oldest goes and its rows show their text again.
  inline constexpr std::size_t max_pane_documents = 8;
  inline constexpr std::size_t max_pane_document_bytes = std::size_t{16} << 20;

  // The longest OSC body that can carry a document.
  inline constexpr std::size_t max_sequence_body = sequence_begin.size() + (max_document_bytes + 2) / 3 * 4;
  static_assert(max_sequence_body <= std::size_t{8} << 20);

}
