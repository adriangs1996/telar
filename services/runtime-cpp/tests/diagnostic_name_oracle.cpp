#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>

import std;
import telar.runtime.diagnostics.runtime_telemetry;

extern "C" std::uint64_t classify_name(const char *bytes, std::size_t length) {
  const auto parsed = telar::runtime::diagnostics::LogName::parse({bytes, length});
  if (!parsed) {
    return 0;
  }

  return parsed->process | (static_cast<std::uint64_t>(parsed->role) << 32) | (static_cast<std::uint64_t>(parsed->rotated) << 33) | (std::uint64_t{1} << 34) | (static_cast<std::uint64_t>(parsed->endpoint.size()) << 35);
}
