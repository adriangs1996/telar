#include "objc_case.hpp"
#include <new>

import std;
import telar.testing;

namespace telar::gui::test {

  ObjcCase::ObjcCase(std::string_view name, void (*run)()) noexcept {
    static_assert(sizeof(telar::testing::Case) <= std::tuple_size_v<decltype(storage_)> && alignof(telar::testing::Case) <= alignof(ObjcCase));

    ::new (static_cast<void*>(storage_.data())) telar::testing::Case{name, run};
  }

  void fail(std::string_view what, std::source_location location) noexcept {
    telar::testing::fail(what, location);
  }

}
