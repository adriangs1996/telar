module telar.gui.foundation.actions;

import std;

import telar.config.client;

namespace telar::gui::inline foundation::inline actions {

  int compareChords(KeyChord left, KeyChord right) noexcept {
    const auto left_value = std::tie(left.key, left.character, left.modifiers);
    const auto right_value = std::tie(right.key, right.character, right.modifiers);

    if (left_value < right_value) {
      return -1;
    }

    return static_cast<int>(left_value > right_value);
  }

}
