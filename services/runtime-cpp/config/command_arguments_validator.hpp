#pragma once

#include "../lua/value.hpp"

namespace telar::runtime::config {

class CommandArgumentsValidator {
public:
  static bool validate(const lua::Value &command) {
    const auto count = command.arraySize();
    if (count == 0 || count > maximum_arguments) {
      command.fail("must contain 1..32 arguments");
    }

    std::size_t bytes = 0;
    bool receives_choice = false;
    for (std::size_t index = 0; index < count; ++index) {
      const auto value = command.element(index + 1);
      const auto argument = value.string();
      bytes += argument.size();
      if ((index == 0 && argument.empty()) || argument.contains('\0') || bytes > maximum_bytes) {
        value.fail("is not a valid bounded command argument");
      }
      receives_choice |= index > 0 && argument == "{}";
    }
    return receives_choice;
  }

private:
  static constexpr std::size_t maximum_arguments = 32;
  static constexpr std::size_t maximum_bytes = 4096;
};

}
