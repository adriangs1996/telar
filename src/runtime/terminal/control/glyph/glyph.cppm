export module telar.runtime.terminal.control.glyph;

import std;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.text;
import telar.runtime.terminal.control;
import telar.base.ds;

export namespace telar::runtime::control {

  ds::Option<std::uint32_t> glyphCodepoint(std::string_view value) noexcept;

  tbc::view<ds::Option<std::string_view>, tbc::lt::a> glyphOption(tbc::view<std::string_view, tbc::lt::a> options, std::string_view key) noexcept;

  // The current C++ clients have no session-glyph renderer. Advertise an empty
  // format set and reject registrations, rather than claiming invisible glyphs.
  void glyph(std::string_view request, Reply<ConcurrentMemory>& reply);

}
