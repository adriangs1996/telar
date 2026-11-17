module telar.gui.foundation.forms;

import std;

namespace telar::gui::inline foundation::inline forms {

  HistoryMatchHighlight::HistoryMatchHighlight(std::string_view query) noexcept
      : query_(query) {}

  std::size_t HistoryMatchHighlight::matched() const noexcept {
    return matched_;
  }

}
