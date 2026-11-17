module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.features.history;
import telar.gui.features.prompt;
import telar.config.client;
import telar.config.runtime;
import telar.wire.history;
import telar.shell.syntax;

namespace telar::gui::application {

  Change Session::apply(const HistoryResults& message) {
    // The editor's suggestions read the commands people typed through the history too.
    if (features::prompt::receive(prompt_, message)) {
      return Change::none;
    }

    return history::receive(*this, message);
  }

  Change Session::apply(const HistoryOutput& message) {
    return history::receive(*this, message);
  }

  Change Session::apply(const HistoryPruned& message) {
    return history::receive(*this, message);
  }

}
