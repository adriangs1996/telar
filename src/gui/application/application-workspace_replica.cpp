module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.tbc;
import telar.gui.features.terminal.graphics;
import telar.wire.vocabulary;
import telar.base.memory.allocators;

namespace telar::gui::application {

  template <Allocator Memory>
  Pane<Memory>::Pane(Memory& memory, std::uint64_t identity, features::terminal::graphics::GraphicsBudget& budget)
      : id(identity),
        screen(memory),
        rows(memory),
        graphics(memory, budget),
        title(memory),
        cwd(memory),
        foreground(memory),
        document(memory),
        document_parts(memory) {}

  template <Allocator Memory>
  Pane<Memory>::InlineDocument::InlineDocument(Memory& memory, std::uint64_t identity)
      : id(identity),
        document(memory),
        parts(memory) {}

  template <Allocator Memory>
  tbc::view<std::string_view, tbc::lt::a> tabApplicationName(tbc::view<const Tab<Memory>&, tbc::lt::a> tab, tbc::view<std::type_identity_t<const Pane<Memory>*>, tbc::lt::a> pane) noexcept {
    constexpr std::string_view fallback = "shell";

    if (pane != nullptr) {
      if (!pane->foreground.empty()) {
        return pane->foreground;
      }

      if (pane->id != tab.foreground_pane) {
        return fallback;
      }
    }

    return tab.foreground.empty() ? fallback : std::string_view{tab.foreground};
  }

  template struct Pane<Memory>;
  template std::string_view tabApplicationName<Memory>(const Tab<Memory>& tab, const Pane<Memory>* pane) noexcept;

}
