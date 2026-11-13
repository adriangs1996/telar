module;
#include "telar_client/protocol/editor.hpp"

export module telar.wire.editor;

// telar's prompt editor: suggestions, completions, command specs, the external
// editor and path search.
//
// The owned textual header stays in this global module fragment only; importers reach
// its names through these declarations.

// The schemas are specializations of `MessageSchema` in the global fragment. A reduced BMI
// drops the fragment declarations a module never names, so naming the template here keeps
// them reachable from importers.
export namespace telar {
  using telar::MessageSchema;
}

export namespace telar {
  using telar::CommandSpec;
  using telar::CommandSpecState;
  using telar::CommandSuggestion;
  using telar::CompleteWords;
  using telar::CompletionProvider;
  using telar::CompletionWords;
  using telar::EditorOpened;
  using telar::FindPaths;
  using telar::OpenEditor;
  using telar::PathResults;
  using telar::RequestCommandSpec;
  using telar::SuggestCommand;
}
