module telar.gui.features.components;

import std;

import telar.tbc;
import telar.gui.foundation.core;

namespace telar::gui::features::components {

  tbc::view<Icon, tbc::lt::static_storage> Icon::find(std::string_view name) noexcept {
    const auto* const found = std::ranges::find(values, name, &Icon::name);

    return found == values.end() ? Icon{.name = {}, .glyph = {}} : *found;
  }

}
