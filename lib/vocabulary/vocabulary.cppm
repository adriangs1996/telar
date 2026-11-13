module;
#include "telar_vocabulary/vocabulary.hpp"

export module telar.vocabulary;

// Owned textual header stays in this global module fragment only; importers reach its names
// through these declarations instead of including it.
export namespace telar {
  using telar::Byte;
  using telar::EnvironmentEntry;
  using telar::EnvironmentMode;
  using telar::FailureCode;
  using telar::Launch;
  using telar::TerminalSize;
}

export namespace telar::runtime {
  using telar::runtime::RequestError;
}
