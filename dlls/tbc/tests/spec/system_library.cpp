#include "system_library.hpp"

#include <string>
#include <string_view>

namespace third_party {
  void observe(const char *text) {
    static_cast<void>(text);
  }

  consteval std::string_view name() {
    return "constant";
  }
}

// CASE: library.view_of_local
// PAIR: library.view
// SOURCE: services/gui-cpp/qt/application.cpp :: Application
// STATUS: implemented
// CONTRACT: A library type with a trivial destructor views the object it is built from.
// SCENARIO: A library view of a local library string is returned.
library::string_view libraryViewOfLocal() {
  const library::string owner{"x"};
  return library::string_view{owner}; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: library.view_of_parameter
// PAIR: library.view
// SOURCE: services/gui-cpp/qt/application.cpp :: Application
// STATUS: implemented
// CONTRACT: A library view of a caller's object may outlive the call.
// SCENARIO: The viewed string belongs to the caller; accept.
library::string_view libraryViewOfParameter(const library::string &owner) {
  return library::string_view{owner};
}

// END CASE

// CASE: library.element_reference_escape
// PAIR: library.element
// SOURCE: services/gui-cpp/tests/quick_test.cpp :: terminalIn
// STATUS: implemented
// CONTRACT: A reference returned by a library container points into its storage.
// SCENARIO: A reference into a local library container is returned.
const int &libraryElementReferenceEscape() {
  const library::list<int> items;
  return items.at(0); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: library.element_copy
// PAIR: library.element
// SOURCE: services/gui-cpp/tests/quick_test.cpp :: terminalIn
// STATUS: implemented
// CONTRACT: An element returned by value is a copy, not a view of the container.
// SCENARIO: A pointer element copied out of a local container outlives it; accept.
int *libraryElementCopy() {
  const library::list<int *> items;
  return items.value(0);
}

// END CASE

// CASE: library.container_storage_escape
// PAIR: library.owner_pointer
// SOURCE: services/gui-cpp/qt/configuration_source.cpp :: optionalText
// STATUS: implemented
// CONTRACT: A pointer returned by a library container designates its storage.
// SCENARIO: The data of a local library container is returned.
const int *libraryContainerStorageEscape() {
  const library::list<int> items;
  return items.data(); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: library.non_container_pointer
// PAIR: library.owner_pointer
// SOURCE: services/gui-cpp/qt/curve_scene.cpp :: QQuickWindow::createTextureFromImage
// STATUS: implemented
// CONTRACT: A pointer from a library owner that is not a container has no inferable relation to it and is not reported.
// SCENARIO: A created object outlives the local component that created it; accept.
int *libraryNonContainerPointer() {
  library::component factory;
  return factory.create();
}

// END CASE

// CASE: library.views_in_owner_dead
// PAIR: library.views_in_owner
// SOURCE: services/gui-cpp/qt/application.cpp :: Application
// STATUS: implemented
// CONTRACT: A library container of views keeps the borrows of the views appended to it.
// SCENARIO: The appended view's string dies before the container is read.
void libraryViewsInOwnerDead() {
  library::list<library::string_view> views;
  {
    const library::string owner{"x"};
    views.append(library::string_view{owner});
  } // expected-error [tbc-invalidated-borrow]
  third_party::observe(views.at(0).data());
}

// END CASE

// CASE: library.views_in_owner_live
// PAIR: library.views_in_owner
// SOURCE: services/gui-cpp/qt/application.cpp :: Application
// STATUS: implemented
// CONTRACT: Views stored in a library container may be read while their source is alive.
// SCENARIO: The string outlives the read; accept.
void libraryViewsInOwnerLive(const library::string &owner) {
  library::list<library::string_view> views;
  views.append(library::string_view{owner});
  third_party::observe(views.at(0).data());
}

// END CASE

// CASE: library.compiled_function
// PAIR: library.function
// SOURCE: services/runtime-cpp/tls/alpn_selection.hpp :: selectAlpn
// STATUS: implemented
// CONTRACT: A compiled library function is outside the analysis and is not reported.
// SCENARIO: The result of a function without a visible body is used; accept.
void libraryCompiledFunction() {
  third_party::observe(library::describe(3));
}

// END CASE

// CASE: library.inline_function
// PAIR: library.function
// SOURCE: services/runtime-cpp/tls/alpn_selection.hpp :: selectAlpn
// STATUS: implemented
// CONTRACT: A library function with a visible body is inferred from the shape of its arguments.
// SCENARIO: The pointer passed through the library function views a local buffer and is returned.
const char *libraryInlineFunction() {
  const std::string buffer = "abc";
  return library::pass(buffer.data()); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: library.constant_expression
// PAIR: library.constant
// SOURCE: services/runtime-cpp/diagnostics/trace.hpp :: trace::literal
// STATUS: implemented
// CONTRACT: A constant-evaluated result borrows exactly what its expression borrows.
// SCENARIO: An immediate function returns a literal-backed view; accept.
std::string_view libraryConstantExpression() {
  return third_party::name();
}

// END CASE

// CASE: library.constant_alongside_local
// PAIR: library.constant
// SOURCE: services/runtime-cpp/diagnostics/trace.hpp :: trace::literal
// STATUS: implemented
// CONTRACT: Unwrapping constant evaluation does not hide a borrow of local storage.
// SCENARIO: A view of a local string is returned next to a constant one.
std::string_view libraryConstantAlongsideLocal(bool constant) {
  const std::string local = "abc";
  return constant ? third_party::name() : std::string_view{local}; // expected-error [tbc-dangling-borrow]
}

// END CASE
