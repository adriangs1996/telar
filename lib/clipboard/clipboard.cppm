module;
#include "telar_clipboard/clipboard.hpp"

export module telar.clipboard;

// The library's header stays in this global module fragment only, because Objective-C++
// shares it; importers reach its names through these declarations instead of including it.
// Every backend defines read outside this module, in the global module where the header
// declares it.
export namespace telar::clipboard {
  using telar::clipboard::byte;
  using telar::clipboard::Content;
  using telar::clipboard::default_maximum_bytes;
  using telar::clipboard::errorMessage;
  using telar::clipboard::read;
  using telar::clipboard::ReadError;
}
