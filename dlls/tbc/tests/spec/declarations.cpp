#include "tbc/view.hpp"

#include <cstddef>
#include <memory>
#include <optional>
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
  // Hands out blocks of an arena it shares with the object that holds both.
  class lender {
  public:
    explicit lender(arena &memory)
        : memory_(memory) {}

    char *take() {
      return memory_.allocate(8);
    }

  private:
    arena &memory_;
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

// CASE: declaration.receiver_shared
// PAIR: declaration.receiver_fields
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: Runtime::handle
// STATUS: implemented
// CONTRACT: A method called on `this` borrows every field of the object, as a Rust method takes `&self` or `&mut self` whole.
// SCENARIO: A const method reads a field passed to it, so both borrows are shared; accept.
namespace declarations {
  class reader {
  public:
    [[nodiscard]] std::size_t total() const {
      return measure(items_);
    }

  private:
    [[nodiscard]] std::size_t measure(const std::vector<int> &items) const {
      return items.size();
    }

    std::vector<int> items_;
  };
}

std::size_t declarationReceiverShared(const declarations::reader &counted) {
  return counted.total();
}

// END CASE

// CASE: declaration.receiver_exclusive
// PAIR: declaration.receiver_fields
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: Runtime::handle
// STATUS: implemented
// CONTRACT: A method called on `this` borrows every field of the object, as a Rust method takes `&self` or `&mut self` whole.
// SCENARIO: A mutating method is passed one of the fields it may change; reject at that argument.
namespace declarations {
  class writer {
  public:
    void grow() {
      append(items_); // expected-error [tbc-invalidated-borrow]
    }

  private:
    void append(std::vector<int> &items) {
      items.push_back(static_cast<int>(items.size()));
    }

    std::vector<int> items_;
  };
}

void declarationReceiverExclusive(declarations::writer &counted) {
  counted.grow();
}

// END CASE

// CASE: declaration.shared_sibling_pinned
// PAIR: declaration.shared_sibling
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: Runtime (limits_ kept by its services)
// STATUS: implemented
// CONTRACT: A field may keep a TBC_SHARED sibling only while their object can be neither copied nor moved, as Rust shares through `Pin`.
// SCENARIO: A lender keeps the arena beside it in a pinned object; accept.
namespace declarations {
  class pinned_pool {
  public:
    pinned_pool()
        : lender_(memory_) {}

    pinned_pool(const pinned_pool &) = delete;
    pinned_pool &operator=(const pinned_pool &) = delete;

  private:
    arena memory_;
    lender lender_;
  };
}

void declarationSharedSiblingPinned() {
  const declarations::pinned_pool pool;
  static_cast<void>(&pool);
}

// END CASE

// CASE: declaration.shared_sibling_copied
// PAIR: declaration.shared_sibling
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: Runtime (limits_ kept by its services)
// STATUS: implemented
// CONTRACT: A field may keep a TBC_SHARED sibling only while their object can be neither copied nor moved, as Rust shares through `Pin`.
// SCENARIO: The object holding the lender and its arena can be copied; reject where the constructor lends the arena.
namespace declarations {
  class copied_pool {
  public:
    copied_pool()
        : lender_(memory_) {} // expected-error [tbc-dangling-borrow]

  private:
    arena memory_;
    lender lender_;
  };
}

void declarationSharedSiblingCopied() {
  const declarations::copied_pool pool;
  static_cast<void>(&pool);
}

// END CASE

// CASE: declaration.lending_output_live
// PAIR: declaration.lending_output
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: AgentService::authorize
// STATUS: implemented
// CONTRACT: A labeled reference to a table that holds borrows lends to a result of its region, as `fn f<'a>(store: &'a mut Store) -> &'a Entry` lends the store.
// SCENARIO: The entry found in a live table is read; accept.
namespace declarations {
  tbc::view<entry &, tbc::lt::a> firstEntry(tbc::view<std::vector<entry> &, tbc::lt::a> entries);
}

std::size_t declarationLendingOutputLive(std::vector<declarations::entry> &entries) {
  const auto &found = declarations::firstEntry(entries);
  return found.text.size();
}

// END CASE

// CASE: declaration.lending_output_dead
// PAIR: declaration.lending_output
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: AgentService::authorize
// STATUS: implemented
// CONTRACT: A labeled reference to a table that holds borrows lends to a result of its region, as `fn f<'a>(store: &'a mut Store) -> &'a Entry` lends the store.
// SCENARIO: The table dies while the entry found in it is still read; reject where it dies.
std::size_t declarationLendingOutputDead(const std::string &text) {
  const declarations::entry *found = nullptr;
  {
    std::vector<declarations::entry> entries;
    entries.emplace_back(text, 1);
    found = &declarations::firstEntry(entries);
  } // expected-error [tbc-invalidated-borrow]
  return found->text.size();
}

// END CASE

// CASE: declaration.value_parameter_copy
// PAIR: declaration.parameter_write
// SOURCE: services/cli-cpp/window.cpp :: plugins
// STATUS: implemented
// CONTRACT: Only a parameter that designates the caller's object hands a write back to the caller; a parameter passed by value is the callee's own copy.
// SCENARIO: A view passed by value is pointed at another argument and read before the function returns; accept.
std::size_t declarationValueParameterCopy(std::string_view text, const std::string &other) {
  text = other;
  return text.size();
}

// END CASE

// CASE: declaration.reference_parameter_kept
// PAIR: declaration.parameter_write
// SOURCE: services/cli-cpp/window.cpp :: plugins
// STATUS: implemented
// CONTRACT: Only a parameter that designates the caller's object hands a write back to the caller; a parameter passed by value is the callee's own copy.
// SCENARIO: A view passed by reference is pointed at another argument the declaration does not let it keep; reject the write.
void declarationReferenceParameterKept(std::string_view &text, const std::string &other) {
  text = other; // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: declaration.shared_reached
// PAIR: declaration.shared_reach
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: Runtime (session_.configure)
// STATUS: implemented
// CONTRACT: An object of a TBC_SHARED type is never invalidated, whatever a call does to the inputs that keep it, as a Rust type with interior mutability keeps every borrow it lent valid.
// SCENARIO: A store builds a pass over a model that keeps the shared arena and mutates the model; the model, keeping the arena too, stays valid; accept.
namespace declarations {
  struct shared_model {
    explicit shared_model(arena &memory) : memory(memory) {}
    arena &memory;
    std::vector<int> items;
  };

  class shared_pass {
  public:
    shared_pass(arena &memory, shared_model &target) : memory_(memory), target_(target) {}
    void apply() { target_.items.push_back(1); }

  private:
    arena &memory_;
    shared_model &target_;
  };

  class shared_store {
  public:
    explicit shared_store(arena &memory) : memory_(memory) {}
    template <typename Model>
    void configure(Model &target) {
      shared_pass pass{memory_, target};
      pass.apply();
    }

  private:
    arena &memory_;
  };

  class shared_owner {
  public:
    explicit shared_owner(arena &memory) : model_(memory), store_(memory) {
      store_.configure(model_);
    }
    shared_owner(const shared_owner &) = delete;

  private:
    shared_model model_;
    shared_store store_;
  };
}

void declarationSharedReached(declarations::arena &memory) {
  const declarations::shared_owner made{memory};
  static_cast<void>(&made);
}

// END CASE

// CASE: declaration.unshared_reached
// PAIR: declaration.shared_reach
// SOURCE: services/runtime-cpp/runtime/runtime.cppm :: Runtime (session_.configure)
// STATUS: implemented
// CONTRACT: An object of a TBC_SHARED type is never invalidated, whatever a call does to the inputs that keep it, as a Rust type with interior mutability keeps every borrow it lent valid.
// SCENARIO: The same store over a pool without the mark may invalidate the pool its argument keeps; reject at the argument.
namespace declarations {
  struct pooled_model {
    explicit pooled_model(pool &memory) : memory(memory) {}
    pool &memory;
    std::vector<int> items;
  };

  class pooled_pass {
  public:
    pooled_pass(pool &memory, pooled_model &target) : memory_(memory), target_(target) {}
    void apply() { target_.items.push_back(1); }

  private:
    pool &memory_;
    pooled_model &target_;
  };

  class pooled_store {
  public:
    explicit pooled_store(pool &memory) : memory_(memory) {}
    template <typename Model>
    void configure(Model &target) {
      pooled_pass pass{memory_, target};
      pass.apply();
    }

  private:
    pool &memory_;
  };

  class pooled_owner {
  public:
    explicit pooled_owner(pool &memory) : model_(memory), store_(memory) {
      store_.configure(model_); // expected-error [tbc-invalidated-borrow]
    }
    pooled_owner(const pooled_owner &) = delete;

  private:
    pooled_model model_;
    pooled_store store_;
  };
}

void declarationUnsharedReached(declarations::pool &memory) {
  const declarations::pooled_owner made{memory};
  static_cast<void>(&made);
}

// END CASE

// CASE: declaration.self_field_elided
// PAIR: declaration.self_field_lifetimes
// SOURCE: services/runtime-cpp/terminal/text_reader.cppm :: Terminal (response_outbox_)
// STATUS: implemented
// CONTRACT: A field labeled lt::self or lt::static_storage declares no lifetime of its class, so a constructor of a class whose other fields carry no label still keeps every argument that lends.
// SCENARIO: A pinned recorder keeps a view of its own buffer and the caller's name, and is read while the name lives; accept.
namespace declarations {
  class recorder {
  public:
    explicit recorder(std::string_view name)
        : name_(name),
          cursor_(buffer_.data()) {}

    recorder(const recorder &) = delete;
    recorder &operator=(const recorder &) = delete;

    [[nodiscard]] std::size_t size() const {
      return name_.size();
    }

  private:
    std::string_view name_;
    std::string buffer_{"buffer"};
    tbc::view<const char *, tbc::lt::self> cursor_;
  };
}

std::size_t declarationSelfFieldElided(const std::string &name) {
  const declarations::recorder kept{name};
  return kept.size();
}

// END CASE

// CASE: declaration.self_field_elided_dangling
// PAIR: declaration.self_field_lifetimes
// SOURCE: services/runtime-cpp/terminal/text_reader.cppm :: Terminal (response_outbox_)
// STATUS: implemented
// CONTRACT: A field labeled lt::self or lt::static_storage declares no lifetime of its class, so a constructor of a class whose other fields carry no label still keeps every argument that lends.
// SCENARIO: The recorder outlives the name it was built from; reject where the name dies.
std::size_t declarationSelfFieldElidedDangling(declarations::arena &memory) {
  std::unique_ptr<declarations::recorder> kept;
  {
    const std::string name = "local";
    kept = declarations::make<declarations::recorder>(memory, name);
  } // expected-error [tbc-invalidated-borrow]
  return kept->size();
}

// END CASE

// CASE: declaration.shared_kept
// PAIR: declaration.shared_kept
// SOURCE: services/runtime-cpp/config/loader.cppm :: Loader::load (lua::JsonDecoder::install)
// STATUS: implemented
// CONTRACT: An object of a TBC_SHARED type is never invalidated, also when it is reached through an object that keeps it, as a Rust type with interior mutability keeps every borrow it lent valid.
// SCENARIO: A machine keeps the loader's arena and is passed with that arena to a call that may mutate the machine; accept.
namespace declarations {
  template <typename Memory>
  class machine {
  public:
    explicit machine(Memory &memory) : memory_(memory) {}
    machine(const machine &) = delete;
    machine &operator=(const machine &) = delete;

    [[nodiscard]] int *slot() const {
      return slot_;
    }

  private:
    Memory &memory_;
    int *slot_ = nullptr;
  };

  template <typename Memory>
  void install(int *slot, Memory &memory) {
    static_cast<void>(memory);
    static_cast<void>(slot);
  }

  template <typename Memory>
  class machine_loader {
  public:
    explicit machine_loader(Memory &memory) : memory_(memory) {}

    void load() {
      const machine<Memory> running{memory_};
      install(running.slot(), memory_);
      static_cast<void>(running.slot());
    }

  private:
    Memory &memory_;
  };
}

void declarationSharedKept(declarations::arena &memory) {
  declarations::machine_loader<declarations::arena>{memory}.load();
}

// END CASE

// CASE: declaration.unshared_kept
// PAIR: declaration.shared_kept
// SOURCE: services/runtime-cpp/config/loader.cppm :: Loader::load (lua::JsonDecoder::install)
// STATUS: implemented
// CONTRACT: An object of a TBC_SHARED type is never invalidated, also when it is reached through an object that keeps it, as a Rust type with interior mutability keeps every borrow it lent valid.
// SCENARIO: The same loader over a pool without the mark lets the call invalidate the pool the machine keeps; reject at the call.
namespace declarations {
  class pooled_loader {
  public:
    explicit pooled_loader(pool &memory) : memory_(memory) {}

    void load() {
      const machine<pool> running{memory_};
      install(running.slot(), memory_); // expected-error [tbc-invalidated-borrow]
      static_cast<void>(running.slot());
    }

  private:
    pool &memory_;
  };
}

void declarationUnsharedKept(declarations::pool &memory) {
  declarations::pooled_loader{memory}.load();
}

// END CASE
