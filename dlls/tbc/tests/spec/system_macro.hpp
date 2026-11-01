#ifndef TBC_TEST_SYSTEM_MACRO_HPP
#define TBC_TEST_SYSTEM_MACRO_HPP

// Treated like a third-party header, such as GoogleTest's assertion macros.
#pragma clang system_header

#include <string_view>

namespace system_macro {
  std::string_view opaque(std::string_view input);
  void consume(std::string_view input);
}

#define SYSTEM_MACRO_CHECK(input) ::system_macro::consume(::system_macro::opaque(input))
#define SYSTEM_MACRO_CONSUME(value) ::system_macro::consume(value)

#endif
