// A case of telar::testing for an Objective-C++ test, which cannot import a module: the .mm
// defines one at namespace scope and fails it with check, as a C++ test does:
//
//   const telar::gui::test::ObjcCase case_phases{"native_scroll_input.phases", phases};
//
// objc_case.cpp, a C++ unit of the same program, defines both with telar.testing.
#pragma once

#include <cstddef>
#include <iterator>
#include <source_location>
#include <string_view>

namespace telar::gui::test {

  class ObjcCase {
  public:
    ObjcCase(std::string_view name, void (*run)()) noexcept;

    // From a literal without string_view's constructor from a pointer, which may throw before main.
    template <std::size_t Size>
    ObjcCase(const char (&name)[Size], void (*run)()) noexcept // NOLINT(cppcoreguidelines-avoid-c-arrays,modernize-avoid-c-arrays): a string literal binds only to an array reference.
        : ObjcCase(std::string_view(std::data(name), Size - 1), run) {}

    ObjcCase(const ObjcCase&) = delete;
    ObjcCase& operator=(const ObjcCase&) = delete;
    ObjcCase(ObjcCase&&) = delete;
    ObjcCase& operator=(ObjcCase&&) = delete;
    ~ObjcCase() = default;

  private:
    // The telar::testing::Case it registers, built in place: a name, a function and a link.
    struct Storage {
      alignas(void*) std::byte bytes[4 * sizeof(void*)]; // NOLINT(cppcoreguidelines-avoid-c-arrays,modernize-avoid-c-arrays): Objective-C++ cannot import telar.base.ds.
    };

    Storage storage_{};
  };

  // telar::testing::fail: writes where the check failed and aborts the process.
  [[noreturn]] void fail(std::string_view what, std::source_location location) noexcept;

  inline void check(bool condition, std::string_view what, std::source_location location = std::source_location::current()) noexcept {
    if (!condition) [[unlikely]] {
      fail(what, location);
    }
  }

}
