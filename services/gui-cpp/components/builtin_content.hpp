#pragma once

#include "content.hpp"
#include "source.hpp"
#include <array>
#include <cstdint>

namespace telar::gui::components {

inline constexpr std::uint8_t builtin_priority = 40;

inline bool builtinSource(SourceKind kind) noexcept {
  return kind == SourceKind::metrics || kind == SourceKind::machines;
}

inline BarContent builtinContent(SourceKind kind) {
  BarContent content;
  Input input{};
  input.node.priority = builtin_priority;
  if (kind == SourceKind::metrics) {
    input.node.kind = Kind::group;
    const auto group = content.append(input);
    input.node.kind = Kind::metric;
    input.node.parent = group;
    for (const auto metric : std::array{BarMetric::cpu, BarMetric::memory, BarMetric::battery}) {
      input.node.metric = metric;
      content.append(input);
    }
  } else if (kind == SourceKind::machines) {
    input.node.kind = Kind::machines;
    content.append(input);
  }

  return content;
}

}
