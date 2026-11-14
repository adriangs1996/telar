module telar.wire.editor;

import std;
import telar.wire.vocabulary;

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar {

  void OpenEditor::validate() const {
    if (pane_generation == 0 || editor.empty() || editor.front() == '-' || path.empty() ||
        path.front() != '/' || (column != 0 && line == 0)) {
      throw EncodingError{"Invalid editor target"};
    }
  }

  void FindPaths::validate() const {
    if (root.empty() || root.front() != '/') {
      throw EncodingError{"Invalid path root"};
    }
  }

  void CommandSuggestion::validate() const {
    if (status != SuggestionStatus::ready && !text.empty()) {
      throw EncodingError{"Unexpected suggestion text"};
    }
  }

  void CommandSpec::validate() const {
    if ((state == CommandSpecState::available) == source.empty()) {
      throw EncodingError{"Command spec source does not match its state"};
    }
  }

  void EditorOpened::validate() const {
    if (outcome == EditorOutcome::opened && (pane_id == 0 || pane_generation == 0)) {
      throw EncodingError{"Missing editor pane identity"};
    }
  }

  void PathResults::validate() const {
    if (root.empty() || root.front() != '/') {
      throw EncodingError{"Invalid path root"};
    }
  }

}
}
