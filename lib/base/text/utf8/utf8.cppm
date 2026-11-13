module;
#include "telar_base/text/utf8.hpp"

export module telar.base.text.utf8;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar {
  using telar::EncodingError;
  using telar::inspectUtf8;
  using telar::Utf8Validation;
  using telar::validateUtf8;
}

export namespace telar::runtime {
  using telar::runtime::utf8Prefix;
}
