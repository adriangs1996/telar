#pragma once

#include "telar_config/ui_value_constraints.hpp"

namespace telar::runtime::config {

class NamedDefinitionsValidator {
public:
  template <typename Validator>
  static void validate(const lua::Value &table, LimitReach reach, LimitNotices &limits, Validator &&validate_definition) {
    if (!table.present()) {
      return;
    }

    std::array<std::string_view, maximum_definitions> names;
    std::size_t kept = 0;
    std::size_t total = 0;
    table.eachField([&](std::string_view name, const lua::Value &) {
      ++total;
      const auto end = names.begin() + kept;
      const auto insertion = std::lower_bound(names.begin(), end, name);
      if (kept == names.size() && insertion == end) {
        return;
      }

      const auto last = kept < names.size() ? end : end - 1;
      std::move_backward(insertion, last, last + 1);
      *insertion = name;
      kept = std::min(kept + 1, names.size());
    });
    if (total > kept) {
      reach.requested = total;
      limits.add(reach);
    }

    for (const auto name : std::span{names}.first(kept)) {
      const auto definition = table.entry(name);
      validate_definition(name, definition);
    }
  }

  static void heading(std::string_view name, const lua::Value &definition, LimitNotices &limits) {
    if (name.empty() || name.size() > maximum_name_bytes || !std::ranges::all_of(name, [](unsigned char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-'; })) {
      definition.fail("has an invalid name");
    }

    const auto title = definition.field("title");
    const auto text = title.present() ? title.string() : name;
    printableUiText(title, fittedUiText(text, {"panels.title_bytes", "title bytes", maximum_title_bytes, {}, {}}, limits));
  }

  static constexpr std::size_t maximum_definitions = 16;

private:
  static constexpr std::size_t maximum_name_bytes = 32;
  static constexpr std::size_t maximum_title_bytes = 128;
};

}
