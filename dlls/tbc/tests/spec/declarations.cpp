#include "tbc/view.hpp"

#include <cstddef>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace declarations {
  void observe(std::string_view text) {
    static_cast<void>(text.size());
  }

  using static_text = tbc::view<std::string_view, tbc::lt::static_storage>;
  using text_a = tbc::view<std::string_view, tbc::lt::a>;

  // A limit named by literals, as a Rust struct of `&'static str` is.
  struct limit {
    static_text name;
    std::size_t value = 0;
  };

  // An allocator: its blocks stay valid whatever is allocated after them.
  class TBC_SHARED arena {
  public:
    char *allocate(std::size_t size) {
      blocks_.push_back(std::make_unique<char[]>(size));
      return blocks_.back().get();
    }

  private:
    std::vector<std::unique_ptr<char[]>> blocks_;
  };

  // The same pool without the promise: allocating may move what it handed out.
  class pool {
  public:
    char *allocate(std::size_t size) {
      bytes_.resize(bytes_.size() + size);
      return bytes_.data() + bytes_.size() - size;
    }

  private:
    std::vector<char> bytes_;
  };

  // A record that keeps its text and copies its number.
  struct entry {
    entry(text_a text, int number)
        : text(text),
          number(number) {}

    text_a text;
    int number;
  };

  // Builds its first template argument from the trailing arguments, as `Box::new(Value::new(..))`.
  template <typename Value, typename... Arguments>
  TBC_CONSTRUCTS std::unique_ptr<Value> make(arena &memory, Arguments &&...arguments) {
    static_cast<void>(memory);
    return std::make_unique<Value>(std::forward<Arguments>(arguments)...);
  }

  // A box keeps values of its own `T`; a callback it is handed is only called.
  template <typename T>
  class box {
  public:
    void push(T value) {
      values_.push_back(value);
    }

    template <typename Visitor>
    void visit(Visitor &&visitor) const {
      for (const auto &value : values_) {
        visitor(value);
      }
    }

  private:
    std::vector<T> values_;
  };

  // Keeps copies of the limits it is told about.
  class notices {
  public:
    void add(tbc::view<const limit &, tbc::lt::a> reached) {
      reached_ = reached;
    }

  private:
    tbc::view<limit, tbc::lt::a> reached_{};
  };

  // Keeps a view of the text it is given.
  class holder {
  public:
    void hold(tbc::view<const std::string &, tbc::lt::a> text) {
      text_ = text;
    }

    [[nodiscard]] std::size_t size() const {
      return text_.size();
    }

  private:
    text_a text_;
  };
} // namespace declarations

// CASE: declaration.static_literal
// PAIR: declaration.static_field
// SOURCE: dlls/telar-base/include/telar_base/diagnostics/limit_reach.hpp :: LimitReach
// STATUS: implemented
// CONTRACT: A field labeled `lt::static_storage` holds only storage that outlives every caller, so its object borrows nothing through it.
// SCENARIO: A limit named by a literal is kept after the function that built it returns; accept.
declarations::limit declarationStaticLiteral() {
  return {.name = "terminal.max_bytes", .value = 4096};
}

// END CASE

// CASE: declaration.static_local
// PAIR: declaration.static_field
// SOURCE: dlls/telar-base/include/telar_base/diagnostics/limit_reach.hpp :: LimitReach
// STATUS: implemented
// CONTRACT: A field labeled `lt::static_storage` holds only storage that outlives every caller, so its object borrows nothing through it.
// SCENARIO: A local string's view is written to the static field; reject where it is written.
declarations::limit declarationStaticLocal() {
  const std::string name = "terminal.max_bytes";
  return {.name = name, .value = 4096}; // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: declaration.shared_allocator
// PAIR: declaration.shared_type
// SOURCE: dlls/telar-base/include/telar_base/memory/allocator.hpp :: SynchronizedAllocator
// STATUS: implemented
// CONTRACT: A call through a TBC_SHARED type invalidates nothing, as a Rust type with interior mutability through `&self`.
// SCENARIO: A block is read after the allocator hands out another one; accept.
char declarationSharedAllocator(declarations::arena &memory) {
  char *first = memory.allocate(8);
  memory.allocate(8);
  return *first;
}

// END CASE

// CASE: declaration.unshared_pool
// PAIR: declaration.shared_type
// SOURCE: dlls/telar-base/include/telar_base/memory/allocator.hpp :: SynchronizedAllocator
// STATUS: implemented
// CONTRACT: A call through a TBC_SHARED type invalidates nothing, as a Rust type with interior mutability through `&self`.
// SCENARIO: Without the mark, a second allocation may move the first block; reject at the call.
char declarationUnsharedPool(declarations::pool &memory) {
  char *first = memory.allocate(8);
  memory.allocate(8); // expected-error [tbc-invalidated-borrow]
  return *first;
}

// END CASE

// CASE: declaration.constructed_copy
// PAIR: declaration.constructs
// SOURCE: dlls/telar-base/include/telar_base/memory/allocator.hpp :: makeOwned
// STATUS: implemented
// CONTRACT: A TBC_CONSTRUCTS factory keeps what the constructor it forwards to keeps.
// SCENARIO: The entry copies a local number and keeps a view of a live string; accept.
std::size_t declarationConstructedCopy(declarations::arena &memory, const std::string &text) {
  std::unique_ptr<declarations::entry> made;
  {
    const int number = 7;
    made = declarations::make<declarations::entry>(memory, text, number);
  }
  return made->text.size();
}

// END CASE

// CASE: declaration.constructed_view
// PAIR: declaration.constructs
// SOURCE: dlls/telar-base/include/telar_base/memory/allocator.hpp :: makeOwned
// STATUS: implemented
// CONTRACT: A TBC_CONSTRUCTS factory keeps what the constructor it forwards to keeps.
// SCENARIO: The entry keeps a view of a local string that dies before it is read.
std::size_t declarationConstructedView(declarations::arena &memory) {
  std::unique_ptr<declarations::entry> made;
  {
    const std::string text = "local";
    made = declarations::make<declarations::entry>(memory, text, 7);
  } // expected-error [tbc-invalidated-borrow]
  return made->text.size();
}

// END CASE

// CASE: declaration.class_parameter_callback
// PAIR: declaration.class_parameter
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: PaneService::sendText
// STATUS: implemented
// CONTRACT: An object keeps only arguments its class template's own parameters spell, as a Rust struct keeps a `T` only in a field of type `T`.
// SCENARIO: A callback capturing a local is only called, so the box is read after the local dies; accept.
std::size_t declarationClassParameterCallback(declarations::box<int> &values) {
  {
    std::size_t total = 0;
    values.visit([&total](int value) { total += static_cast<std::size_t>(value); });
  }
  values.push(1);
  return 1;
}

// END CASE

// CASE: declaration.class_parameter_kept
// PAIR: declaration.class_parameter
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: PaneService::sendText
// STATUS: implemented
// CONTRACT: An object keeps only arguments its class template's own parameters spell, as a Rust struct keeps a `T` only in a field of type `T`.
// SCENARIO: The box keeps a view of a local string of its own `T`, and is used after it dies.
void declarationClassParameterKept() {
  declarations::box<std::string_view> values;
  {
    const std::string text = "local";
    values.push(text);
  } // expected-error [tbc-invalidated-borrow]
  values.visit([](std::string_view value) { declarations::observe(value); });
}

// END CASE

// CASE: declaration.retained_copy
// PAIR: declaration.retained_argument
// SOURCE: dlls/telar-config/include/telar_config/config.cppm :: LimitNotices::add
// STATUS: implemented
// CONTRACT: A labeled reference parameter retained into fields that hold values keeps what the argument holds, not the argument.
// SCENARIO: A temporary limit is copied into the notices, which are used after it dies; accept.
void declarationRetainedCopy(declarations::notices &kept) {
  kept.add({.name = "terminal.max_bytes", .value = 1});
  kept.add({.name = "terminal.max_rows", .value = 2});
}

// END CASE

// CASE: declaration.retained_reference
// PAIR: declaration.retained_argument
// SOURCE: dlls/telar-config/include/telar_config/config.cppm :: LimitNotices::add
// STATUS: implemented
// CONTRACT: A labeled reference parameter retained into fields that hold values keeps what the argument holds, not the argument.
// SCENARIO: A holder whose region keeps a view retains the temporary string itself; reject where it dies.
std::size_t declarationRetainedReference(declarations::holder &kept) {
  kept.hold(std::string{"temporary"}); // expected-error [tbc-dangling-borrow]
  return kept.size();
}

// END CASE
