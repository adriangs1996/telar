module telar.gui.application;

import std;
import telar.gui.foundation.core;
import telar.gui.features.history;
import telar.config.client;
import telar.config.runtime;
import telar.gui.prompt.layout;
import telar.wire.editor;
import telar.wire.history;
import telar.gui.prompt.routing;
import telar.gui.prompt.editor;
import telar.shell.syntax;

namespace telar::gui::application {

  Change Session::apply(const HistoryResults& message) {
    // The editor's suggestions read the commands people typed through the history too.
    if (message.request_id == prompt_history_request_ && prompt_history_request_ != 0) {
      prompt_history_request_ = 0;
      prompt_history_.clear();
      for (const auto& entry : message.entries) {
        if (!entry.command_truncated && !entry.command.empty()) {
          prompt_history_.emplace_back(entry.command);
        }
      }

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
