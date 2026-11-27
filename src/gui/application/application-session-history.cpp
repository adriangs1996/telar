module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.features.history;
import telar.gui.features.prompt;
import telar.config.client;
import telar.wire.history;

namespace telar::gui::application {

  Change Session::apply(const HistoryResults& message) {
    // The editor's suggestions read the commands people typed through the history too, and the
    // runtime ranks the one a line suggests.
    if (const auto change = prompt::receive(*this, message)) {
      return *change;
    }

    return history::receive(*this, message);
  }

  Change Session::apply(const HistoryOutput& message) {
    return history::receive(*this, message);
  }

  Change Session::apply(const HistoryCommandStats& message) {
    return history::receive(*this, message);
  }

  Change Session::apply(const HistoryPruned& message) {
    return history::receive(*this, message);
  }

  Change Session::apply(const HistoryChanged& message) {
    // The prompt's recall and suggestions, and the panel's page, each read the history anew.
    static_cast<void>(prompt::receive(*this, message));

    return history::receive(*this, message);
  }

}
