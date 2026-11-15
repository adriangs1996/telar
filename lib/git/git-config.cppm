module;
#include "tbc/annotations.hpp"

export module telar.git:config;

import std;
import telar.base.memory.allocators;

// A strict reader of git's config syntax. It only reports variables: nothing
// it reads is executed, and include/includeIf are ordinary, ignored entries.

namespace telar::git {

  struct ConfigEntry {
    std::string_view section;    // as written; compare without case
    std::string_view subsection; // case preserved, except the legacy [section.sub] form
    std::string_view key;        // as written; compare without case
    std::optional<std::string_view> value;
  };

  bool parseConfigEntries(std::string_view text, String<Memory>& scratch, void* target, bool (*visit)(void*, const ConfigEntry&));

  // Visits each variable of `text` in order and returns false on the first
  // malformed line, as git refuses such a file. `scratch` holds the unescaped
  // subsection and value; it grows once to twice the file size.
  template <Allocator Memory, typename Visitor>
  TBC_GENERIC bool parseConfig(std::string_view text, String<Memory>& scratch, Visitor&& visit) {
    // Stays generic over the caller's visitor, which the parser calls through a function pointer.
    using Target = std::remove_reference_t<Visitor>;

    return parseConfigEntries(text, scratch, const_cast<std::remove_const_t<Target>*>(std::addressof(visit)), [](void* target, const ConfigEntry& entry) -> bool {
      return (*static_cast<Target*>(target))(entry);
    });
  }

  // git's boolean spellings; anything else is not a boolean.
  std::optional<bool> configBoolean(std::optional<std::string_view> value) noexcept;

}
