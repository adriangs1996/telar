module telar.gui.application;

import std;
import telar.wire.editor;

namespace telar::gui::application {

  Change Session::apply(const CommandSpec& message) {
    return prompt::receive(*this, message);
  }

  Change Session::apply(const CompletionWords& message) {
    return prompt::receive(*this, message);
  }

  Change Session::apply(const PathResults& message) {
    if (const auto change = prompt::receive(*this, message)) {
      return *change;
    }

    return paths::receive(*this, message);
  }

  Change Session::apply(const CommandSuggestion& message) {
    return palette::receive(*this, message);
  }

}
