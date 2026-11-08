#include "system_library.hpp"

#include <span>
#include <string>
#include <string_view>
#include <vector>

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
// SOURCE: services/runtime-cpp/tls/interception.cppm :: selectAlpn
// STATUS: implemented
// CONTRACT: A compiled library function is outside the analysis and is not reported.
// SCENARIO: The result of a function without a visible body is used; accept.
void libraryCompiledFunction() {
  third_party::observe(library::describe(3));
}

// END CASE

// CASE: library.inline_function
// PAIR: library.function
// SOURCE: services/runtime-cpp/tls/interception.cppm :: selectAlpn
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
// SOURCE: dlls/telar-platform/include/telar_platform/trace.hpp :: trace::literal
// STATUS: implemented
// CONTRACT: A constant-evaluated result borrows exactly what its expression borrows.
// SCENARIO: An immediate function returns a literal-backed view; accept.
std::string_view libraryConstantExpression() {
  return third_party::name();
}

// END CASE

// CASE: library.constant_alongside_local
// PAIR: library.constant
// SOURCE: dlls/telar-platform/include/telar_platform/trace.hpp :: trace::literal
// STATUS: implemented
// CONTRACT: Unwrapping constant evaluation does not hide a borrow of local storage.
// SCENARIO: A view of a local string is returned next to a constant one.
std::string_view libraryConstantAlongsideLocal(bool constant) {
  const std::string local = "abc";
  return constant ? third_party::name() : std::string_view{local}; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: library.raw_stream_pointer
// PAIR: library.raw_stream
// SOURCE: services/runtime-cpp/exchange_capture/producer.cppm :: FlateDecoder::decode
// STATUS: implemented
// CONTRACT: A pointer field of a C struct a system header declares is a raw pointer, as Rust's `*const T` in an FFI struct, so storing a buffer in it keeps no borrow.
// SCENARIO: A decoder hands one call's buffers to its C stream; accept.
namespace third_party {
  class decoder {
  public:
    decoder() = default;
    decoder(const decoder &) = delete;
    int decode(std::string_view input, std::span<unsigned char> output) {
      stream_.next_in = reinterpret_cast<const unsigned char *>(input.data());
      stream_.avail_in = static_cast<unsigned>(input.size());
      stream_.next_out = output.data();
      stream_.avail_out = static_cast<unsigned>(output.size());
      return codec_pump(&stream_);
    }

  private:
    codec_stream stream_{};
  };
}

int libraryRawStreamPointer(third_party::decoder &decoder, std::string_view input, std::span<unsigned char> output) {
  return decoder.decode(input, output);
}

// END CASE

// CASE: library.project_stream_pointer
// PAIR: library.raw_stream
// SOURCE: services/runtime-cpp/exchange_capture/producer.cppm :: FlateDecoder::decode
// STATUS: implemented
// CONTRACT: A pointer field of a C struct a system header declares is a raw pointer, as Rust's `*const T` in an FFI struct, so storing a buffer in it keeps no borrow.
// SCENARIO: The same stream declared by the project keeps the borrow its declaration does not allow; reject the store.
namespace third_party {
  struct project_stream {
    const unsigned char *next_in;
  };

  class project_decoder {
  public:
    void decode(std::string_view input) {
      stream_.next_in = reinterpret_cast<const unsigned char *>(input.data()); // expected-error [tbc-contract-violation]
    }

  private:
    project_stream stream_{};
  };
}

void libraryProjectStreamPointer(third_party::project_decoder &decoder, std::string_view input) {
  decoder.decode(input);
}

// END CASE

// CASE: library.raw_struct_value
// PAIR: library.raw_struct
// SOURCE: services/runtime-cpp/proxy/runtime.cppm :: Http2EndpointConnection::Fields::add
// STATUS: implemented
// CONTRACT: A value of a C struct a system header declares holds raw pointers, as Rust's FFI structs do, so it carries no borrow of what they point at.
// SCENARIO: A header list keeps entries pointing at names it owns and at the caller's values; accept.
namespace third_party {
  class field_list {
  public:
    void add(const std::string &name, std::string_view value) {
      names_.push_back(name);
      const auto &stored = names_.back();
      fields_.push_back({reinterpret_cast<const unsigned char *>(stored.data()), reinterpret_cast<const unsigned char *>(value.data()), stored.size(), value.size()});
    }

  private:
    std::vector<std::string> names_;
    std::vector<codec_field> fields_;
  };
}

void libraryRawStructValue(third_party::field_list &list, std::string_view value) {
  list.add("content-type", value);
}

// END CASE

// CASE: library.project_struct_value
// PAIR: library.raw_struct
// SOURCE: services/runtime-cpp/proxy/runtime.cppm :: Http2EndpointConnection::Fields::add
// STATUS: implemented
// CONTRACT: A value of a C struct a system header declares holds raw pointers, as Rust's FFI structs do, so it carries no borrow of what they point at.
// SCENARIO: The same entry declared by the project keeps the caller's value its declaration does not allow; reject the store.
namespace third_party {
  struct project_field {
    std::string_view value;
  };

  class project_list {
  public:
    void add(std::string_view value) {
      fields_.push_back({value}); // expected-error [tbc-contract-violation]
    }

  private:
    std::vector<project_field> fields_;
  };
}

void libraryProjectStructValue(third_party::project_list &list, std::string_view value) {
  list.add(value);
}

// END CASE
