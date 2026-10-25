#pragma once

#include "../lua/value.hpp"

namespace telar::runtime::config {

class ClientDefinitions {
public:
  explicit ClientDefinitions(const lua::Value &client, const lua::Value *inherited = nullptr)
      : client_(client),
        inherited_(inherited) {}

  bool contains(const char *section, std::string_view name) const {
    const auto definitions = client_.field(section);
    if (definitions.present()) {
      return containsName(definitions, name);
    }
    if (inherited_ != nullptr && inherited_->present()) {
      return containsName(inherited_->field(section), name);
    }
    return false;
  }

private:
  static bool containsName(const lua::Value &definitions, std::string_view name) {
    if (!definitions.present()) {
      return false;
    }

    bool found = false;
    definitions.eachField([&](std::string_view candidate, const lua::Value &) { found |= candidate == name; });
    return found;
  }

  const lua::Value &client_;
  const lua::Value *inherited_;
};

}
