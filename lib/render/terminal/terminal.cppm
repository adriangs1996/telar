export module telar.render.terminal;

import std;
export import telar.render.document;

// Draws a Document as styled terminal text wrapped to a width, for terminals
// that cannot show it natively. Only SGR sequences are written: document text
// never carries a control character to the terminal.
export namespace telar::render::terminal {

  inline constexpr std::uint16_t min_width = 20;

  template <Allocator Memory, Allocator Output>
  void render(const Document<Memory>& document, std::uint16_t width, String<Output>& output);

  extern template void render(const Document<Memory>& document, std::uint16_t width, String<Memory>& output);

}
