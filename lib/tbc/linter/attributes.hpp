#ifndef TBC_LINTER_ATTRIBUTES_HPP
#define TBC_LINTER_ATTRIBUTES_HPP

namespace tbc_lint {
  // Anchors the static ParsedAttrInfo registrations in attributes.cpp so linkers never dead-strip
  // them when linking tbc-lint, tbc-plugin, or tbc-tidy-scope.
  void registerAttributes() noexcept;
}

#endif
