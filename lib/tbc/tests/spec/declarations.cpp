#include "tbc/view.hpp"

#include <array>
#include <cstddef>
#include <memory>
#include <new>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
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
    char* allocate(std::size_t size) {
      blocks_.push_back(std::make_unique<char[]>(size));
      return blocks_.back().get();
    }

  private:
    std::vector<std::unique_ptr<char[]>> blocks_;
  };

  // The same pool without the promise: allocating may move what it handed out.
  class pool {
  public:
    char* allocate(std::size_t size) {
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
  TBC_CONSTRUCTS std::unique_ptr<Value> make(arena& memory, Arguments&&... arguments) {
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
    void visit(Visitor&& visitor) const {
      for (const auto& value : values_) {
        visitor(value);
      }
    }

  private:
    std::vector<T> values_;
  };

  // Keeps copies of the limits it is told about.
  class notices {
  public:
    void add(tbc::view<const limit&, tbc::lt::a> reached) {
      reached_ = reached;
    }

  private:
    tbc::view<limit, tbc::lt::a> reached_{};
  };

  // Keeps a view of the text it is given.
  class holder {
  public:
    void hold(tbc::view<const std::string&, tbc::lt::a> text) {
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
    explicit lender(arena& memory)
        : memory_(memory) {}

    char* take() {
      return memory_.allocate(8);
    }

  private:
    arena& memory_;
  };
} // namespace declarations

// CASE: declaration.static_literal
// PAIR: declaration.static_field
// SOURCE: lib/base/include/telar_base/diagnostics/limit_reach.hpp :: LimitReach
// STATUS: implemented
// CONTRACT: A field labeled `lt::static_storage` holds only storage that outlives every caller, so its object borrows nothing through it.
// SCENARIO: A limit named by a literal is kept after the function that built it returns; accept.
declarations::limit declarationStaticLiteral() {
  return {.name = "terminal.max_bytes", .value = 4096};
}

// END CASE

// CASE: declaration.static_local
// PAIR: declaration.static_field
// SOURCE: lib/base/include/telar_base/diagnostics/limit_reach.hpp :: LimitReach
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
// SOURCE: lib/base/include/telar_base/memory/allocator.hpp :: SynchronizedAllocator
// STATUS: implemented
// CONTRACT: A call through a TBC_SHARED type invalidates nothing, as a Rust type with interior mutability through `&self`.
// SCENARIO: A block is read after the allocator hands out another one; accept.
char declarationSharedAllocator(declarations::arena& memory) {
  char* first = memory.allocate(8);
  memory.allocate(8);
  return *first;
}

// END CASE

// CASE: declaration.unshared_pool
// PAIR: declaration.shared_type
// SOURCE: lib/base/include/telar_base/memory/allocator.hpp :: SynchronizedAllocator
// STATUS: implemented
// CONTRACT: A call through a TBC_SHARED type invalidates nothing, as a Rust type with interior mutability through `&self`.
// SCENARIO: Without the mark, a second allocation may move the first block; reject at the call.
char declarationUnsharedPool(declarations::pool& memory) {
  char* first = memory.allocate(8);
  memory.allocate(8); // expected-error [tbc-invalidated-borrow]
  return *first;
}

// END CASE

// CASE: declaration.constructed_copy
// PAIR: declaration.constructs
// SOURCE: lib/base/include/telar_base/memory/allocator.hpp :: makeOwned
// STATUS: implemented
// CONTRACT: A TBC_CONSTRUCTS factory keeps what the constructor it forwards to keeps.
// SCENARIO: The entry copies a local number and keeps a view of a live string; accept.
std::size_t declarationConstructedCopy(declarations::arena& memory, const std::string& text) {
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
// SOURCE: lib/base/include/telar_base/memory/allocator.hpp :: makeOwned
// STATUS: implemented
// CONTRACT: A TBC_CONSTRUCTS factory keeps what the constructor it forwards to keeps.
// SCENARIO: The entry keeps a view of a local string that dies before it is read.
std::size_t declarationConstructedView(declarations::arena& memory) {
  std::unique_ptr<declarations::entry> made;
  {
    const std::string text = "local";
    made = declarations::make<declarations::entry>(memory, text, 7);
  } // expected-error [tbc-invalidated-borrow]
  return made->text.size();
}

// END CASE

// CASE: declaration.constructed_in_place_copy
// PAIR: declaration.constructs_in_place
// SOURCE: lib/base/ds/ds.cppm :: Option
// STATUS: implemented
// CONTRACT: A constructor marked TBC_CONSTRUCTS builds its class's first template argument in place from its trailing pack, and keeps what that type's constructor keeps of it.
// SCENARIO: An optional entry is built in place from a live string and a temporary number it copies; accept.
namespace declarations {
  template <typename Value>
  class in_place_slot {
  public:
    template <typename... Arguments>
    TBC_CONSTRUCTS explicit in_place_slot(std::in_place_t, Arguments&&... arguments)
        : value_(std::forward<Arguments>(arguments)...) {}

    [[nodiscard]] const Value& get() const noexcept {
      return value_;
    }

  private:
    Value value_;
  };
}

std::size_t declarationConstructedInPlaceCopy(const std::string& text) {
  const declarations::in_place_slot<declarations::entry> slot{std::in_place, text, 7};

  return slot.get().text.size();
}

// END CASE

// CASE: declaration.constructed_in_place_view
// PAIR: declaration.constructs_in_place
// SOURCE: lib/base/ds/ds.cppm :: Option
// STATUS: implemented
// CONTRACT: A constructor marked TBC_CONSTRUCTS builds its class's first template argument in place from its trailing pack, and keeps what that type's constructor keeps of it.
// SCENARIO: The entry built in place keeps a view of a temporary string that dies with its declaration; reject at the declaration.
std::size_t declarationConstructedInPlaceView() {
  const declarations::in_place_slot<declarations::entry> slot{std::in_place, std::string{"temporary"}, 7}; // expected-error [tbc-dangling-borrow]

  return slot.get().text.size();
}

// END CASE

// CASE: declaration.constructed_in_place_same_view
// PAIR: declaration.constructs_in_place
// SOURCE: lib/base/text/text.cpp :: Split::next
// STATUS: implemented
// CONTRACT: A constructor marked TBC_CONSTRUCTS builds its class's first template argument in place from its trailing pack, and keeps what that type's constructor keeps of it.
// SCENARIO: A view built from a local view copies it, as its copy constructor does and none of its constructor templates, so the holder keeps what the local views, the caller's text, not the local; accept.
namespace declarations {
  template <typename Value>
  class converted_slot {
  public:
    template <typename Other>
    TBC_CONSTRUCTS converted_slot(Other&& value)
        : value_(std::forward<Other>(value)) {}

  private:
    Value value_;
  };
}

declarations::converted_slot<std::string_view> declarationConstructedInPlaceSameView(std::string_view text) {
  const auto prefix = text.substr(0, 1);

  return prefix;
}

// END CASE

// CASE: declaration.constructed_in_place_library_copy
// PAIR: declaration.constructs_library_in_place
// SOURCE: src/gui/features/prompt/prompt.cpp :: ask
// STATUS: implemented
// CONTRACT: A constructor marked TBC_CONSTRUCTS keeps what its first template argument's construction keeps; a library type keeps a copy of what each argument holds, unless it is a view.
// SCENARIO: A variant takes a temporary query that views the caller's text, so the slot keeps a view of that text, not of the temporary; accept.
namespace declarations {
  struct query {
    std::string_view prefix;
  };
}

declarations::converted_slot<std::variant<declarations::query>> declarationConstructedInPlaceLibraryCopy(std::string_view text) {
  return declarations::query{.prefix = text};
}

// END CASE

// CASE: declaration.constructed_in_place_library_escape
// PAIR: declaration.constructs_library_in_place
// SOURCE: src/gui/features/prompt/prompt.cpp :: ask
// STATUS: implemented
// CONTRACT: A constructor marked TBC_CONSTRUCTS keeps what its first template argument's construction keeps; a library type keeps a copy of what each argument holds, unless it is a view.
// SCENARIO: The variant keeps a copy of a query that views a local string, which dies before the slot is used; reject.
declarations::converted_slot<std::variant<declarations::query>> declarationConstructedInPlaceLibraryEscape() {
  const std::string local = "local";

  return declarations::query{.prefix = local}; // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: declaration.class_parameter_callback
// PAIR: declaration.class_parameter
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: PaneService::sendText
// STATUS: implemented
// CONTRACT: An object keeps only arguments its class template's own parameters spell, as a Rust struct keeps a `T` only in a field of type `T`.
// SCENARIO: A callback capturing a local is only called, so the box is read after the local dies; accept.
std::size_t declarationClassParameterCallback(declarations::box<int>& values) {
  {
    std::size_t total = 0;
    values.visit([&total](int value) {
      total += static_cast<std::size_t>(value);
    });
  }
  values.push(1);
  return 1;
}

// END CASE

// CASE: declaration.class_parameter_kept
// PAIR: declaration.class_parameter
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: PaneService::sendText
// STATUS: implemented
// CONTRACT: An object keeps only arguments its class template's own parameters spell, as a Rust struct keeps a `T` only in a field of type `T`.
// SCENARIO: The box keeps a view of a local string of its own `T`, and is used after it dies.
void declarationClassParameterKept() {
  declarations::box<std::string_view> values;
  {
    const std::string text = "local";
    values.push(text);
  } // expected-error [tbc-invalidated-borrow]
  values.visit([](std::string_view value) {
    declarations::observe(value);
  });
}

// END CASE

// CASE: declaration.retained_copy
// PAIR: declaration.retained_argument
// SOURCE: lib/config/core/core.cppm :: LimitNotices::add
// STATUS: implemented
// CONTRACT: A labeled reference parameter retained into fields that hold values keeps what the argument holds, not the argument.
// SCENARIO: A temporary limit is copied into the notices, which are used after it dies; accept.
void declarationRetainedCopy(declarations::notices& kept) {
  kept.add({.name = "terminal.max_bytes", .value = 1});
  kept.add({.name = "terminal.max_rows", .value = 2});
}

// END CASE

// CASE: declaration.retained_reference
// PAIR: declaration.retained_argument
// SOURCE: lib/config/core/core.cppm :: LimitNotices::add
// STATUS: implemented
// CONTRACT: A labeled reference parameter retained into fields that hold values keeps what the argument holds, not the argument.
// SCENARIO: A holder whose region keeps a view retains the temporary string itself; reject where it dies.
std::size_t declarationRetainedReference(declarations::holder& kept) {
  kept.hold(std::string{"temporary"}); // expected-error [tbc-dangling-borrow]
  return kept.size();
}

// END CASE

// CASE: declaration.receiver_shared
// PAIR: declaration.receiver_fields
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime::handle
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
    [[nodiscard]] std::size_t measure(const std::vector<int>& items) const {
      return items.size();
    }

    std::vector<int> items_;
  };
}

std::size_t declarationReceiverShared(const declarations::reader& counted) {
  return counted.total();
}

// END CASE

// CASE: declaration.receiver_exclusive
// PAIR: declaration.receiver_fields
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime::handle
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
    void append(std::vector<int>& items) {
      items.push_back(static_cast<int>(items.size()));
    }

    std::vector<int> items_;
  };
}

void declarationReceiverExclusive(declarations::writer& counted) {
  counted.grow();
}

// END CASE

// CASE: declaration.shared_sibling_pinned
// PAIR: declaration.shared_sibling
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime (limits_ kept by its services)
// STATUS: implemented
// CONTRACT: A field may keep a TBC_SHARED sibling only while their object can be neither copied nor moved, as Rust shares through `Pin`.
// SCENARIO: A lender keeps the arena beside it in a pinned object; accept.
namespace declarations {
  class pinned_pool {
  public:
    pinned_pool()
        : lender_(memory_) {}

    pinned_pool(const pinned_pool&) = delete;
    pinned_pool& operator=(const pinned_pool&) = delete;

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
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime (limits_ kept by its services)
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
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: AgentService::authorize
// STATUS: implemented
// CONTRACT: A labeled reference to a table that holds borrows lends to a result of its region, as `fn f<'a>(store: &'a mut Store) -> &'a Entry` lends the store.
// SCENARIO: The entry found in a live table is read; accept.
namespace declarations {
  tbc::view<entry&, tbc::lt::a> firstEntry(tbc::view<std::vector<entry>&, tbc::lt::a> entries);
}

std::size_t declarationLendingOutputLive(std::vector<declarations::entry>& entries) {
  const auto& found = declarations::firstEntry(entries);
  return found.text.size();
}

// END CASE

// CASE: declaration.lending_output_dead
// PAIR: declaration.lending_output
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: AgentService::authorize
// STATUS: implemented
// CONTRACT: A labeled reference to a table that holds borrows lends to a result of its region, as `fn f<'a>(store: &'a mut Store) -> &'a Entry` lends the store.
// SCENARIO: The table dies while the entry found in it is still read; reject where it dies.
std::size_t declarationLendingOutputDead(const std::string& text) {
  const declarations::entry* found = nullptr;
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
// SOURCE: src/cli/window/window.cpp :: plugins
// STATUS: implemented
// CONTRACT: Only a parameter that designates the caller's object hands a write back to the caller; a parameter passed by value is the callee's own copy.
// SCENARIO: A view passed by value is pointed at another argument and read before the function returns; accept.
std::size_t declarationValueParameterCopy(std::string_view text, const std::string& other) {
  text = other;
  return text.size();
}

// END CASE

// CASE: declaration.reference_parameter_kept
// PAIR: declaration.parameter_write
// SOURCE: src/cli/window/window.cpp :: plugins
// STATUS: implemented
// CONTRACT: Only a parameter that designates the caller's object hands a write back to the caller; a parameter passed by value is the callee's own copy.
// SCENARIO: A view passed by reference is pointed at another argument the declaration does not let it keep; reject the write.
void declarationReferenceParameterKept(std::string_view& text, const std::string& other) {
  text = other; // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: declaration.shared_reached
// PAIR: declaration.shared_reach
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime (session_.configure)
// STATUS: implemented
// CONTRACT: An object of a TBC_SHARED type is never invalidated, whatever a call does to the inputs that keep it, as a Rust type with interior mutability keeps every borrow it lent valid.
// SCENARIO: A store builds a pass over a model that keeps the shared arena and mutates the model; the model, keeping the arena too, stays valid; accept.
namespace declarations {
  struct shared_model {
    explicit shared_model(arena& memory)
        : memory(memory) {}

    arena& memory;
    std::vector<int> items;
  };

  class shared_pass {
  public:
    shared_pass(arena& memory, shared_model& target)
        : memory_(memory),
          target_(target) {}

    void apply() {
      target_.items.push_back(1);
    }

  private:
    arena& memory_;
    shared_model& target_;
  };

  class shared_store {
  public:
    explicit shared_store(arena& memory)
        : memory_(memory) {}

    template <typename Model>
    void configure(Model& target) {
      shared_pass pass{memory_, target};
      pass.apply();
    }

  private:
    arena& memory_;
  };

  class shared_owner {
  public:
    explicit shared_owner(arena& memory)
        : model_(memory),
          store_(memory) {
      store_.configure(model_);
    }

    shared_owner(const shared_owner&) = delete;

  private:
    shared_model model_;
    shared_store store_;
  };
}

void declarationSharedReached(declarations::arena& memory) {
  const declarations::shared_owner made{memory};
  static_cast<void>(&made);
}

// END CASE

// CASE: declaration.unshared_reached
// PAIR: declaration.shared_reach
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime (session_.configure)
// STATUS: implemented
// CONTRACT: An object of a TBC_SHARED type is never invalidated, whatever a call does to the inputs that keep it, as a Rust type with interior mutability keeps every borrow it lent valid.
// SCENARIO: The same store over a pool without the mark may invalidate the pool its argument keeps; reject at the argument.
namespace declarations {
  struct pooled_model {
    explicit pooled_model(pool& memory)
        : memory(memory) {}

    pool& memory;
    std::vector<int> items;
  };

  class pooled_pass {
  public:
    pooled_pass(pool& memory, pooled_model& target)
        : memory_(memory),
          target_(target) {}

    void apply() {
      target_.items.push_back(1);
    }

  private:
    pool& memory_;
    pooled_model& target_;
  };

  class pooled_store {
  public:
    explicit pooled_store(pool& memory)
        : memory_(memory) {}

    template <typename Model>
    void configure(Model& target) {
      pooled_pass pass{memory_, target};
      pass.apply();
    }

  private:
    pool& memory_;
  };

  class pooled_owner {
  public:
    explicit pooled_owner(pool& memory)
        : model_(memory),
          store_(memory) {
      store_.configure(model_); // expected-error [tbc-invalidated-borrow]
    }

    pooled_owner(const pooled_owner&) = delete;

  private:
    pooled_model model_;
    pooled_store store_;
  };
}

void declarationUnsharedReached(declarations::pool& memory) {
  const declarations::pooled_owner made{memory};
  static_cast<void>(&made);
}

// END CASE

// CASE: declaration.self_field_elided
// PAIR: declaration.self_field_lifetimes
// SOURCE: src/runtime/terminal/text_reader/text_reader.cppm :: Terminal (response_outbox_)
// STATUS: implemented
// CONTRACT: A field labeled lt::self or lt::static_storage declares no lifetime of its class, so a constructor of a class whose other fields carry no label still keeps every argument that lends.
// SCENARIO: A pinned recorder keeps a view of its own buffer and the caller's name, and is read while the name lives; accept.
namespace declarations {
  class recorder {
  public:
    explicit recorder(std::string_view name)
        : name_(name),
          cursor_(buffer_.data()) {}

    recorder(const recorder&) = delete;
    recorder& operator=(const recorder&) = delete;

    [[nodiscard]] std::size_t size() const {
      return name_.size();
    }

  private:
    std::string_view name_;
    std::string buffer_{"buffer"};
    tbc::view<const char*, tbc::lt::self> cursor_;
  };
}

std::size_t declarationSelfFieldElided(const std::string& name) {
  const declarations::recorder kept{name};
  return kept.size();
}

// END CASE

// CASE: declaration.self_field_elided_dangling
// PAIR: declaration.self_field_lifetimes
// SOURCE: src/runtime/terminal/text_reader/text_reader.cppm :: Terminal (response_outbox_)
// STATUS: implemented
// CONTRACT: A field labeled lt::self or lt::static_storage declares no lifetime of its class, so a constructor of a class whose other fields carry no label still keeps every argument that lends.
// SCENARIO: The recorder outlives the name it was built from; reject where the name dies.
std::size_t declarationSelfFieldElidedDangling(declarations::arena& memory) {
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
// SOURCE: src/runtime/config/loader/loader.cppm :: Loader::load (lua::JsonDecoder::install)
// STATUS: implemented
// CONTRACT: An object of a TBC_SHARED type is never invalidated, also when it is reached through an object that keeps it, as a Rust type with interior mutability keeps every borrow it lent valid.
// SCENARIO: A machine keeps the loader's arena and is passed with that arena to a call that may mutate the machine; accept.
namespace declarations {
  template <typename Memory>
  class machine {
  public:
    explicit machine(Memory& memory)
        : memory_(memory) {}

    machine(const machine&) = delete;
    machine& operator=(const machine&) = delete;

    [[nodiscard]] int* slot() const {
      return slot_;
    }

  private:
    Memory& memory_;
    int* slot_ = nullptr;
  };

  template <typename Memory>
  void install(int* slot, Memory& memory) {
    static_cast<void>(memory);
    static_cast<void>(slot);
  }

  template <typename Memory>
  class machine_loader {
  public:
    explicit machine_loader(Memory& memory)
        : memory_(memory) {}

    void load() {
      const machine<Memory> running{memory_};
      install(running.slot(), memory_);
      static_cast<void>(running.slot());
    }

  private:
    Memory& memory_;
  };
}

void declarationSharedKept(declarations::arena& memory) {
  declarations::machine_loader<declarations::arena>{memory}.load();
}

// END CASE

// CASE: declaration.unshared_kept
// PAIR: declaration.shared_kept
// SOURCE: src/runtime/config/loader/loader.cppm :: Loader::load (lua::JsonDecoder::install)
// STATUS: implemented
// CONTRACT: An object of a TBC_SHARED type is never invalidated, also when it is reached through an object that keeps it, as a Rust type with interior mutability keeps every borrow it lent valid.
// SCENARIO: The same loader over a pool without the mark passes the pool the machine keeps as a mutable argument, and the call may invalidate it while the machine is used later; reject the overlapping argument and the call.
namespace declarations {
  class pooled_loader {
  public:
    explicit pooled_loader(pool& memory)
        : memory_(memory) {}

    void load() {
      const machine<pool> running{memory_};
      install(
          running.slot(),
          memory_ // expected-error [tbc-invalidated-borrow]
      );          // expected-error [tbc-invalidated-borrow]
      static_cast<void>(running.slot());
    }

  private:
    pool& memory_;
  };
}

void declarationUnsharedKept(declarations::pool& memory) {
  declarations::pooled_loader{memory}.load();
}

// END CASE

// CASE: declaration.exclusive_field_call
// PAIR: declaration.exclusive_field
// SOURCE: src/runtime/graphics/pane_media/pane_media.cppm :: PaneMedia::process (MediaInput::feed)
// STATUS: implemented
// CONTRACT: What a receiver designates through its own reference fields it borrows exclusively, as a Rust `&mut` field is: a call through it invalidates other borrows of those objects, not the receiver's own.
// SCENARIO: A feeder keeps a screen by reference and is fed twice, each feed growing the screen's cells; accept.
namespace declarations {
  struct screen {
    std::vector<int> cells;

    void resize(std::size_t size) {
      cells.resize(size);
    }
  };

  class feeder {
  public:
    explicit feeder(screen& target)
        : target_(target) {}

    void feed(int value) {
      target_.cells.push_back(value);
    }

  private:
    screen& target_;
  };
}

void declarationExclusiveFieldCall(const std::vector<int>& values) {
  declarations::screen shown;
  declarations::feeder input{shown};
  for (const int value : values) {
    input.feed(value);
  }
}

// END CASE

// CASE: declaration.exclusive_field_alias
// PAIR: declaration.exclusive_field
// SOURCE: src/runtime/graphics/pane_media/pane_media.cppm :: PaneMedia::process (MediaInput::feed)
// STATUS: implemented
// CONTRACT: What a receiver designates through its own reference fields it borrows exclusively, as a Rust `&mut` field is: a call through it invalidates other borrows of those objects, not the receiver's own.
// SCENARIO: The screen is resized directly while the feeder that keeps it is fed again; reject at the resize.
void declarationExclusiveFieldAlias(const std::vector<int>& values) {
  declarations::screen shown;
  declarations::feeder input{shown};
  for (const int value : values) {
    if (value > 0) {
      input.feed(value);
    } else {
      shown.resize(0); // expected-error [tbc-invalidated-borrow]
    }
  }
}

// END CASE

// CASE: declaration.static_input
// PAIR: declaration.static_input
// SOURCE: src/runtime/proxy/http2_capture_streams/http2_capture_streams.cppm :: respond (ProxyRejection::response)
// STATUS: implemented
// CONTRACT: A parameter labeled static_storage takes only storage that outlives every caller, which the call checks at the argument, so it supplies static fields and results, as a Rust `&'static str` parameter does.
// SCENARIO: A reply keeps a literal it is handed and forwards another; accept.
namespace declarations {
  class reply {
  public:
    void respond(static_text text) {
      text_ = text;
    }

    static static_text forward(static_text text) {
      return text;
    }

    [[nodiscard]] std::size_t size() const {
      return text_.size();
    }

  private:
    static_text text_;
  };
}

std::size_t declarationStaticInput(declarations::reply& out) {
  out.respond("HTTP/1.1 200 OK\r\n\r\n");
  return out.size() + declarations::reply::forward("ok").size();
}

// END CASE

// CASE: declaration.static_input_owned
// PAIR: declaration.static_input
// SOURCE: src/runtime/proxy/http2_capture_streams/http2_capture_streams.cppm :: respond (ProxyRejection::response)
// STATUS: implemented
// CONTRACT: A parameter labeled static_storage takes only storage that outlives every caller, which the call checks at the argument, so it supplies static fields and results, as a Rust `&'static str` parameter does.
// SCENARIO: The reply is handed a local string; reject at the argument.
std::size_t declarationStaticInputOwned() {
  const std::string text = "dynamic";
  return declarations::reply::forward(text).size(); // expected-error [tbc-contract-violation]
}

// END CASE

// CASE: declaration.constant_referent
// PAIR: declaration.constant_referent
// SOURCE: src/runtime/cli/server/server.cppm :: runServer (runRuntime)
// STATUS: implemented
// CONTRACT: What a reference to const designates cannot change through it, as a Rust `&T` parameter cannot, so a call that receives it invalidates no borrow of it.
// SCENARIO: A launcher reads settings through a const reference while an options copy keeps a view of them; accept.
namespace declarations {
  struct settings {
    std::string history;
  };

  struct launch_options {
    std::string_view history;
  };

  class launcher {
  public:
    explicit launcher(const settings& values)
        : values_(values) {}

    void run() {
      count_ += values_.history.size();
    }

  private:
    const settings& values_;
    std::size_t count_ = 0;
  };

  void launch(const launch_options& options, const settings& values) {
    launcher running{values};
    running.run();
    static_cast<void>(options.history.size());
  }
}

std::size_t declarationConstantReferent(const declarations::settings& values) {
  const declarations::launch_options options{.history = values.history};
  declarations::launch(options, values);
  return options.history.size();
}

// END CASE

// CASE: declaration.mutable_referent
// PAIR: declaration.constant_referent
// SOURCE: src/runtime/cli/server/server.cppm :: runServer (runRuntime)
// STATUS: implemented
// CONTRACT: What a reference to const designates cannot change through it, as a Rust `&T` parameter cannot, so a call that receives it invalidates no borrow of it.
// SCENARIO: The same settings passed by mutable reference to a call that replaces them while a view of them is used later; reject at the call.
namespace declarations {
  void reset(settings& values) {
    values.history = std::string(64, 'x');
  }
}

std::size_t declarationMutableReferent(declarations::settings& values) {
  const declarations::launch_options options{.history = values.history};
  declarations::reset(values); // expected-error [tbc-invalidated-borrow]
  return options.history.size();
}

// END CASE

// CASE: declaration.raw_pointer
// PAIR: declaration.raw_pointer
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: Http2EndpointConnection::advance
// STATUS: implemented
// CONTRACT: A pointer passed through tbc::raw carries no borrow, as Rust's `as *mut T` does, so the code that dereferences it answers for the object being alive.
// SCENARIO: A connection resolves each stream of its own table through a raw pointer, by index, since a method of the connection lends it whole; accept.
namespace declarations {
  struct raw_half {
    int ticket = 0;
  };

  struct raw_stream {
    raw_half request;
  };

  class raw_connection {
  public:
    void advance() {
      for (std::size_t index = 0; index < streams_.size(); ++index) {
        if (auto* current = tbc::raw(streams_[index].get())) {
          resolve(current->request);
        }
      }
    }

  private:
    void resolve(raw_half& value) {
      value.ticket = 0;
    }

    std::array<std::unique_ptr<raw_stream>, 4> streams_;
  };
}

void declarationRawPointer(declarations::raw_connection& connection) {
  connection.advance();
}

// END CASE

// CASE: declaration.checked_pointer
// PAIR: declaration.raw_pointer
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: Http2EndpointConnection::advance
// STATUS: implemented
// CONTRACT: A pointer passed through tbc::raw carries no borrow, as Rust's `as *mut T` does, so the code that dereferences it answers for the object being alive.
// SCENARIO: The same connection resolves its streams through the table's own pointers; reject the overlapping argument.
namespace declarations {
  class checked_connection {
  public:
    void advance() {
      for (std::size_t index = 0; index < streams_.size(); ++index) {
        if (auto* current = streams_[index].get()) {
          resolve(current->request); // expected-error [tbc-invalidated-borrow]
        }
      }
    }

  private:
    void resolve(raw_half& value) {
      value.ticket = 0;
    }

    std::array<std::unique_ptr<raw_stream>, 4> streams_;
  };
}

void declarationCheckedPointer(declarations::checked_connection& connection) {
  connection.advance();
}

// END CASE

// CASE: declaration.template_constructor_copy
// PAIR: declaration.template_constructor
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: ApplicationRelay::transfer (Http1Connection)
// STATUS: implemented
// CONTRACT: A constructor template keeps by its declaration, as any constructor does: a parameter taken by value keeps a copy of what its argument holds, not the argument.
// SCENARIO: A factory builds a relay from a moved local through a constructor template taking it by value; accept.
namespace declarations {
  struct tally {
    int value = 0;
  };

  struct observer {
    tally* target;
  };

  class template_relay {
  public:
    template <typename Context>
    template_relay(tally& total, observer observed, Context context)
        : total_(total),
          observed_(observed),
          context_(static_cast<int>(context)) {}

    void advance() {
      ++total_.value;
    }

  private:
    tally& total_;
    observer observed_;
    int context_;
  };

  class template_owner {
  public:
    template_owner(arena& memory, tally& total)
        : memory_(memory),
          total_(total) {}

    template_owner(const template_owner&) = delete;

    void advance() {
      if (!relay_) {
        observer observed{&total_};
        relay_ = make<template_relay>(memory_, total_, std::move(observed), 3);
      }
      relay_->advance();
    }

  private:
    arena& memory_;
    tally& total_;
    std::unique_ptr<template_relay> relay_;
  };
}

void declarationTemplateConstructorCopy(declarations::arena& memory, declarations::tally& total) {
  declarations::template_owner owner{memory, total};
  owner.advance();
}

// END CASE

// CASE: declaration.template_constructor_reference
// PAIR: declaration.template_constructor
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: ApplicationRelay::transfer (Http1Connection)
// STATUS: implemented
// CONTRACT: A constructor template keeps by its declaration, as any constructor does: a parameter taken by value keeps a copy of what its argument holds, not the argument.
// SCENARIO: The relay's constructor template keeps the observer by reference, and the local dies before the relay is used; reject at the use.
namespace declarations {
  class reference_relay {
  public:
    template <typename Context>
    reference_relay(const observer& observed, Context context)
        : observed_(observed),
          context_(static_cast<int>(context)) {}

    [[nodiscard]] int advance() const {
      return observed_.target->value + context_;
    }

  private:
    const observer& observed_;
    int context_;
  };
}

int declarationTemplateConstructorReference(declarations::arena& memory, declarations::tally& total) {
  std::unique_ptr<declarations::reference_relay> relay;
  {
    const declarations::observer observed{&total};
    relay = declarations::make<declarations::reference_relay>(memory, observed, 3);
  } // expected-error [tbc-invalidated-borrow]
  return relay->advance();
}

// END CASE

// CASE: declaration.static_field_result
// PAIR: declaration.static_field_result
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: FlowGate::failureReason
// STATUS: implemented
// CONTRACT: What a field labeled static_storage holds outlives every caller, so it supplies a static result and may be kept anywhere, as a static input may.
// SCENARIO: A gate keeps the literal it fails with and returns it; a transport forwards a literal to the gate it owns; accept.
namespace declarations {
  class failure_gate {
  public:
    void fail(static_text reason) {
      failure_ = reason;
    }

    [[nodiscard]] static_text failure() const {
      return failure_;
    }

  private:
    static_text failure_;
  };

  class failure_transport {
  public:
    void error(static_text reason) {
      if (gate_) {
        gate_->fail(reason);
      }
    }

  private:
    std::unique_ptr<failure_gate> gate_ = std::make_unique<failure_gate>();
  };
}

std::size_t declarationStaticFieldResult(declarations::failure_transport& transport, const declarations::failure_gate& gate) {
  transport.error("closed");
  return gate.failure().size();
}

// END CASE

// CASE: declaration.dynamic_field_result
// PAIR: declaration.static_field_result
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: FlowGate::failureReason
// STATUS: implemented
// CONTRACT: What a field labeled static_storage holds outlives every caller, so it supplies a static result and may be kept anywhere, as a static input may.
// SCENARIO: A gate returns a field without the label as static; reject the result.
namespace declarations {
  class dynamic_gate {
  public:
    explicit dynamic_gate(std::string_view reason)
        : failure_(reason) {}

    [[nodiscard]] static_text failure() const {
      return failure_; // expected-error [tbc-contract-violation]
    }

  private:
    std::string_view failure_;
  };
}

std::size_t declarationDynamicFieldResult(const declarations::dynamic_gate& gate) {
  return gate.failure().size();
}

// END CASE

// CASE: declaration.owned_receiver_call
// PAIR: declaration.owned_receiver
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: ApplicationRelay::Relays::transfer (http1_->advance)
// STATUS: implemented
// CONTRACT: The object a sole owner holds, as a unique_ptr's, is that owner's own: a call through it invalidates other borrows of what it designates, not the owner's own.
// SCENARIO: An owner feeds a screen twice through the feeder its unique_ptr holds; accept.
namespace declarations {
  class feeding_owner {
  public:
    explicit feeding_owner(screen& shown)
        : feeder_(std::make_unique<feeder>(shown)) {}

    void feed(int value) {
      feeder_->feed(value);
      feeder_->feed(value);
    }

  private:
    std::unique_ptr<feeder> feeder_;
  };
}

void declarationOwnedReceiverCall(declarations::screen& shown) {
  declarations::feeding_owner owner{shown};
  owner.feed(1);
}

// END CASE

// CASE: declaration.owned_receiver_alias
// PAIR: declaration.owned_receiver
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: ApplicationRelay::Relays::transfer (http1_->advance)
// STATUS: pending
// CONTRACT: The object a sole owner holds, as a unique_ptr's, is that owner's own: a call through it invalidates other borrows of what it designates, not the owner's own.
// SCENARIO: A view of the screen's cells is read after the owned feeder grows them; reject at the feed.
std::size_t declarationOwnedReceiverAlias() {
  declarations::screen shown;
  shown.cells.push_back(0);
  auto input = std::make_unique<declarations::feeder>(shown);
  const auto* first = shown.cells.data();
  input->feed(1); // expected-error [tbc-invalidated-borrow]
  return static_cast<std::size_t>(*first);
}

// END CASE

// CASE: declaration.shared_reference_result
// PAIR: declaration.shared_reference_result
// SOURCE: src/gui/ui/design/controls/native_chrome_text.cpp :: NativeChromeText::refreshLayout (ResidentFonts::face)
// STATUS: implemented
// CONTRACT: A reference a shared type's method returns is storage the shared object keeps valid, as a pointer it returns is, so a call through it invalidates nothing of its caller.
// SCENARIO: An item measures through a face its shared fonts hand out while a view of its own text is used later; accept.
namespace declarations {
  class font_face {
  public:
    int measure(int size) {
      size_ = size;
      return size_;
    }

  private:
    int size_ = 0;
  };

  class TBC_SHARED shared_fonts {
  public:
    font_face& face() {
      return face_;
    }

  private:
    font_face face_;
  };

  class text_item {
  public:
    explicit text_item(shared_fonts& fonts)
        : fonts_(&fonts) {}

    std::size_t layout() {
      const std::string_view text{utf8_};
      height_ = fonts_->face().measure(12);
      return text.size();
    }

  private:
    shared_fonts* fonts_;
    std::string utf8_ = "text";
    int height_ = 0;
  };
}

std::size_t declarationSharedReferenceResult(declarations::shared_fonts& fonts) {
  declarations::text_item item{fonts};
  return item.layout();
}

// END CASE

// CASE: declaration.unshared_reference_result
// PAIR: declaration.shared_reference_result
// SOURCE: src/gui/ui/design/controls/native_chrome_text.cpp :: NativeChromeText::refreshLayout (ResidentFonts::face)
// STATUS: implemented
// CONTRACT: A reference a shared type's method returns is storage the shared object keeps valid, as a pointer it returns is, so a call through it invalidates nothing of its caller.
// SCENARIO: A face the item owns grows a buffer a view of it was taken from before; reject the later use.
namespace declarations {
  class buffered_face {
  public:
    std::string& buffer() {
      return buffer_;
    }

  private:
    std::string buffer_ = "glyphs";
  };
}

std::size_t declarationUnsharedReferenceResult(declarations::buffered_face& face) {
  const std::string_view glyphs{face.buffer()};
  face.buffer().append(64, 'x'); // expected-error [tbc-invalidated-borrow]
  return glyphs.size();
}

// END CASE

// CASE: declaration.pinned_shared_field
// PAIR: declaration.pinned_shared_field
// SOURCE: src/gui/application/application-configuration.cppm :: ConfigurationGeneration::readConfiguration (lua::Vm)
// STATUS: implemented
// CONTRACT: A field of a TBC_SHARED type that can be neither assigned nor moved lives as long as its object, so a call that mutates the object keeps every borrow the field lent valid, as a pinned Rust value with interior mutability does.
// SCENARIO: A value read from the owner's pinned machine is used after the owner records it; accept.
namespace declarations {
  class TBC_SHARED pinned_machine {
  public:
    pinned_machine() = default;
    pinned_machine(const pinned_machine&) = delete;
    pinned_machine& operator=(const pinned_machine&) = delete;

    [[nodiscard]] int* slot() const;
  };

  class pinned_reader {
  public:
    int read() {
      const int* slot = machine_.slot();
      record(*slot);
      return *slot;
    }

    void record(int value);

  private:
    pinned_machine machine_;
    int recorded_ = 0;
  };
}

int declarationPinnedSharedField() {
  declarations::pinned_reader reader;
  return reader.read();
}

// END CASE

// CASE: declaration.movable_shared_field
// PAIR: declaration.pinned_shared_field
// SOURCE: src/gui/application/application-configuration.cppm :: ConfigurationGeneration::readConfiguration (lua::Vm)
// STATUS: pending
// CONTRACT: A field of a TBC_SHARED type that can be neither assigned nor moved lives as long as its object, so a call that mutates the object keeps every borrow the field lent valid, as a pinned Rust value with interior mutability does.
// SCENARIO: A machine that can be assigned may be replaced by the call, dropping the value it lent; reject at the call.
namespace declarations {
  class TBC_SHARED movable_machine {
  public:
    [[nodiscard]] int* slot() const;
  };

  class movable_reader {
  public:
    int read() {
      const int* slot = machine_.slot();
      record(*slot); // expected-error [tbc-invalidated-borrow]
      return *slot;
    }

    void record(int value);

  private:
    movable_machine machine_;
    int recorded_ = 0;
  };
}

int declarationMovableSharedField() {
  declarations::movable_reader reader;
  return reader.read();
}

// END CASE

// CASE: declaration.abstract_shared_memory
// PAIR: declaration.abstract_shared
// SOURCE: lib/base/include/telar_base/memory/allocator.hpp :: ConcurrentAllocator (the type-erased Memory planned to replace it)
// STATUS: implemented
// CONTRACT: An abstract TBC_SHARED type is shared through a reference to it, as a Rust `&dyn Trait` of a type with interior mutability: its virtual calls invalidate nothing.
// SCENARIO: Two holders keep one `Memory &`, and allocations through it and through each holder leave a block read later valid; accept.
namespace declarations {
  // An allocator behind a virtual interface, used through `Memory &` instead of a concept.
  class TBC_SHARED memory {
  public:
    virtual ~memory() = default;
    virtual void* allocate(std::size_t size, std::size_t alignment) noexcept = 0;
    virtual void deallocate(void* block, std::size_t size, std::size_t alignment) noexcept = 0;
  };

  // Each implementation carries its own mark: a derived type is audited apart from its base.
  template <typename allocator>
  class TBC_SHARED memory_adapter final : public memory {
  public:
    explicit memory_adapter(tbc::view<allocator&, tbc::lt::a> wrapped) noexcept
        : allocator_(wrapped) {}

    void* allocate(std::size_t size, std::size_t alignment) noexcept override {
      static_cast<void>(alignment);
      return allocator_.allocate(size);
    }

    void deallocate(void* block, std::size_t size, std::size_t alignment) noexcept override {
      static_cast<void>(block);
      static_cast<void>(size);
      static_cast<void>(alignment);
    }

  private:
    tbc::view<allocator&, tbc::lt::a> allocator_;
  };

  // The same adapter without the mark.
  template <typename allocator>
  class unmarked_adapter final : public memory {
  public:
    explicit unmarked_adapter(tbc::view<allocator&, tbc::lt::a> wrapped) noexcept
        : allocator_(wrapped) {}

    void* allocate(std::size_t size, std::size_t alignment) noexcept override {
      static_cast<void>(alignment);
      return allocator_.allocate(size);
    }

    void deallocate(void* block, std::size_t size, std::size_t alignment) noexcept override {
      static_cast<void>(block);
      static_cast<void>(size);
      static_cast<void>(alignment);
    }

  private:
    tbc::view<allocator&, tbc::lt::a> allocator_;
  };

  // A buffer that keeps the memory it was given, as services keep their allocator.
  class erased_bytes {
  public:
    explicit erased_bytes(tbc::view<memory&, tbc::lt::a> memory) noexcept
        : memory_(memory) {}

    erased_bytes(const erased_bytes&) = delete;
    erased_bytes& operator=(const erased_bytes&) = delete;

    bool resize(std::size_t size) noexcept {
      auto* block = static_cast<char*>(memory_.allocate(size, alignof(char)));
      if (block == nullptr) {
        return false;
      }

      memory_.deallocate(data_, size_, alignof(char));
      data_ = block;
      size_ = size;
      return true;
    }

    char* data() noexcept {
      return data_;
    }

  private:
    tbc::view<memory&, tbc::lt::a> memory_;
    char* data_ = nullptr;
    std::size_t size_ = 0;
  };
}

char declarationAbstractSharedMemory(tbc::view<declarations::memory&, tbc::lt::a> memory) {
  declarations::erased_bytes first(memory);
  declarations::erased_bytes second(memory);

  first.resize(8);

  const char* data = first.data();
  void* block = memory.allocate(16, 8);

  second.resize(4);
  memory.deallocate(block, 16, 8);
  return *data;
}

// END CASE

// CASE: declaration.abstract_shared_escapes
// PAIR: declaration.abstract_shared
// SOURCE: lib/base/include/telar_base/memory/allocator.hpp :: ConcurrentAllocator (the type-erased Memory planned to replace it)
// STATUS: implemented
// CONTRACT: An abstract TBC_SHARED type is shared through a reference to it, as a Rust `&dyn Trait` of a type with interior mutability: its virtual calls invalidate nothing.
// SCENARIO: Sharing does not extend the referent: a buffer keeps a local adapter through `Memory &` and outlives it; reject at the return.
declarations::erased_bytes declarationAbstractSharedEscapes(declarations::arena& system) {
  declarations::memory_adapter<declarations::arena> local(system);

  return declarations::erased_bytes(local); // expected-error [tbc-dangling-borrow]
}

// END CASE

// CASE: declaration.abstract_shared_sibling_marked
// PAIR: declaration.abstract_shared_sibling
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: Http2EndpointConnection (budget_ lent to sibling fields)
// STATUS: implemented
// CONTRACT: The TBC_SHARED mark is not inherited: a field keeps a sibling through a shared base only when the sibling's own type is marked and its object is pinned.
// SCENARIO: A pinned service lends its marked adapter to a buffer beside it as `Memory &`; accept.
namespace declarations {
  class marked_service {
  public:
    explicit marked_service(tbc::view<arena&, tbc::lt::a> system) noexcept
        : memory_(system),
          bytes_(memory_) {}

    marked_service(const marked_service&) = delete;
    marked_service& operator=(const marked_service&) = delete;

    bool grow() noexcept {
      return bytes_.resize(32);
    }

  private:
    memory_adapter<arena> memory_;
    erased_bytes bytes_;
  };
}

bool declarationAbstractSharedSiblingMarked(declarations::arena& system) {
  declarations::marked_service service(system);

  return service.grow();
}

// END CASE

// CASE: declaration.abstract_shared_sibling_unmarked
// PAIR: declaration.abstract_shared_sibling
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: Http2EndpointConnection (budget_ lent to sibling fields)
// STATUS: implemented
// CONTRACT: The TBC_SHARED mark is not inherited: a field keeps a sibling through a shared base only when the sibling's own type is marked and its object is pinned.
// SCENARIO: The adapter derives from the marked interface but is not marked itself; reject where the constructor lends it.
namespace declarations {
  class unmarked_service {
  public:
    explicit unmarked_service(tbc::view<arena&, tbc::lt::a> system) noexcept
        : memory_(system),
          bytes_(memory_) {} // expected-error [tbc-dangling-borrow]

    unmarked_service(const unmarked_service&) = delete;
    unmarked_service& operator=(const unmarked_service&) = delete;

    bool grow() noexcept {
      return bytes_.resize(32);
    }

  private:
    unmarked_adapter<arena> memory_;
    erased_bytes bytes_;
  };
}

bool declarationAbstractSharedSiblingUnmarked(declarations::arena& system) {
  declarations::unmarked_service service(system);

  return service.grow();
}

// END CASE

// CASE: declaration.abstract_shared_release_read_first
// PAIR: declaration.abstract_shared_release
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime::closeWorkspace (removeTab erases the workspace through SlotStore and AllocationDeleter)
// STATUS: implemented
// CONTRACT: A call through an abstract TBC_SHARED type's virtual deallocate releases only the block it is given, after the caller has evaluated the call's arguments.
// SCENARIO: The identity is copied into a local, then a call releases the group it was read from through `memory &`, and the group is found again; accept.
namespace declarations {
  struct released_group {
    std::size_t id;
  };

  // Releases a group through the memory it came from, as AllocationDeleter does.
  class group_deleter {
  public:
    explicit group_deleter(memory& memory) noexcept
        : memory_(&memory) {}

    void operator()(released_group* group) const noexcept {
      std::destroy_at(group);
      memory_->deallocate(group, sizeof(released_group), alignof(released_group));
    }

  private:
    memory* memory_;
  };

  // Slots of groups that it releases on erase, as SlotStore does.
  class group_store {
  public:
    explicit group_store(memory& memory) noexcept
        : memory_(memory) {}

    group_store(const group_store&) = delete;
    group_store& operator=(const group_store&) = delete;

    const std::array<released_group*, 4>& items() const noexcept {
      return items_;
    }

    released_group* find(std::size_t id) const noexcept {
      return items_[id % 4];
    }

    void erase(std::size_t id) noexcept {
      auto* group = find(id);
      if (group == nullptr) {
        return;
      }

      items_[id % 4] = nullptr;
      group_deleter{memory_}(group);
    }

  private:
    memory& memory_;
    std::array<released_group*, 4> items_{};
  };

  inline void releaseGroup(group_store& groups, std::size_t group, std::size_t tab) noexcept {
    static_cast<void>(tab);
    groups.erase(group);
  }

  inline bool releaseGroupFound(group_store& groups, std::size_t group, std::size_t tab) noexcept {
    const bool found = groups.find(group) != nullptr;

    releaseGroup(groups, group, tab);
    return found;
  }
}

void declarationAbstractSharedReleaseReadFirst(declarations::group_store& groups, std::size_t id) {
  auto* current = groups.find(id);

  while (current != nullptr) {
    const auto tab = current->id;

    declarations::releaseGroup(groups, id, tab);
    current = groups.find(id);
  }
}

// END CASE

// CASE: declaration.abstract_shared_release_use
// PAIR: declaration.abstract_shared_release
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime::closeWorkspace (removeTab erases the workspace through SlotStore and AllocationDeleter)
// STATUS: implemented
// CONTRACT: A call through an abstract TBC_SHARED type's virtual deallocate releases only the block it is given, after the caller has evaluated the call's arguments.
// SCENARIO: The group is read after the call that releases it through `memory &`; reject at the call.
std::size_t declarationAbstractSharedReleaseUse(declarations::group_store& groups, std::size_t id) {
  auto* current = groups.find(id);
  if (current == nullptr) {
    return 0;
  }

  declarations::releaseGroup(groups, id, 0); // expected-error [tbc-invalidated-borrow]
  return current->id;
}

// END CASE

// CASE: declaration.abstract_shared_release_argument
// PAIR: declaration.abstract_shared_release
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime::closeWorkspace (removeTab erases the workspace through SlotStore and AllocationDeleter)
// STATUS: implemented
// CONTRACT: A call through an abstract TBC_SHARED type's virtual deallocate releases only the block it is given, after the caller has evaluated the call's arguments.
// SCENARIO: The identity is read from the group as a by-value argument of the call that releases it; the read completes before the call runs, as when it is copied into a local first; accept.
void declarationAbstractSharedReleaseArgument(declarations::group_store& groups, std::size_t id) {
  auto* current = groups.find(id);

  while (current != nullptr) {
    declarations::releaseGroup(groups, id, current->id);
    current = groups.find(id);
  }
}

// END CASE

// CASE: declaration.abstract_shared_release_argument_kept
// PAIR: declaration.abstract_shared_release
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime::closeWorkspace (removeTab erases the workspace through SlotStore and AllocationDeleter)
// STATUS: implemented
// CONTRACT: A call through an abstract TBC_SHARED type's virtual deallocate releases only the block it is given, after the caller has evaluated the call's arguments.
// SCENARIO: The releasing call's result initializes a local, and its by-value argument was read from the group before it ran; accept.
void declarationAbstractSharedReleaseArgumentKept(declarations::group_store& groups, std::size_t id) {
  auto* current = groups.find(id);

  while (current != nullptr) {
    const bool released = declarations::releaseGroupFound(groups, id, current->id);

    static_cast<void>(released);
    current = groups.find(id);
  }
}

// END CASE

// CASE: declaration.abstract_shared_release_next_round
// PAIR: declaration.abstract_shared_release
// SOURCE: src/runtime/runtime/runtime/runtime.cppm :: Runtime::closeWorkspace (removeTab erases the workspace through SlotStore and AllocationDeleter)
// STATUS: implemented
// CONTRACT: A call through an abstract TBC_SHARED type's virtual deallocate releases only the block it is given, after the caller has evaluated the call's arguments.
// SCENARIO: A loop's second round passes the call an argument read from the group the first round released, without finding the group again; reject at the call.
void declarationAbstractSharedReleaseNextRound(declarations::group_store& groups, std::size_t id) {
  auto* current = groups.find(id);

  for (int round = 0; round < 2; ++round) {
    declarations::releaseGroup(groups, id, current->id); // expected-error [tbc-invalidated-borrow]
  }
}

// END CASE

// CASE: declaration.abstract_shared_release_iteration
// PAIR: declaration.abstract_shared_release
// SOURCE: src/runtime/persistence/session_store/session_store.cppm :: Restore::dropEmptyTabs (erases workspaces while iterating the store's slots)
// STATUS: implemented
// CONTRACT: A method whose body releases a block through an abstract TBC_SHARED type's virtual deallocate borrows its whole receiver, as a Rust `&mut self` method does.
// SCENARIO: The store's slot array is iterated while the store erases one slot's group; the erase borrows the whole store, so the loop's view of its slots ends there, as Rust rejects calling a `&mut self` method while iterating a field; reject at the erase.
void declarationAbstractSharedReleaseIteration(declarations::group_store& groups) {
  for (auto* group : groups.items()) {
    if (group == nullptr) {
      continue;
    }

    const auto id = group->id;

    groups.erase(id); // expected-error [tbc-invalidated-borrow]
  }
}

// END CASE

// CASE: declaration.abstract_shared_release_collected
// PAIR: declaration.abstract_shared_release
// SOURCE: src/runtime/persistence/session_store/session_store.cppm :: Restore::dropEmptyTabs (erases workspaces while iterating the store's slots)
// STATUS: implemented
// CONTRACT: A method whose body releases a block through an abstract TBC_SHARED type's virtual deallocate borrows its whole receiver, as a Rust `&mut self` method does.
// SCENARIO: The identities are collected while iterating, and erased after the loop; accept.
void declarationAbstractSharedReleaseCollected(declarations::group_store& groups) {
  std::array<std::size_t, 4> identities{};
  std::size_t count = 0;

  for (const auto* group : groups.items()) {
    if (group != nullptr) {
      identities[count++] = group->id;
    }
  }

  for (std::size_t index = 0; index < count; ++index) {
    groups.erase(identities[index]);
  }
}

// END CASE

// CASE: declaration.shared_borrow_held_launch
// PAIR: declaration.shared_borrow_held
// SOURCE: src/runtime/persistence/session_store/session_store.cppm :: Restore::restore(const PaneRecord&) (launches a pane, then lists it in its tab)
// STATUS: implemented
// CONTRACT: A shared object keeps valid the storage it hands out. A place found through a borrow of it that an object holds, past a field the shared type does not have, is such storage; growth there still ends the borrows of the object that owns it.
// SCENARIO: A launch stores in the model a pane made with the shared memory, which a workspace's tab list also keeps through its allocator; growing a tab's list and then finding the pane again is accepted.
namespace declarations {
  class TBC_SHARED model_memory {
  public:
    void* allocate(std::size_t size, std::size_t alignment) noexcept {
      static_cast<void>(alignment);
      return ::operator new(size, std::nothrow);
    }

    void deallocate(void* block, std::size_t size, std::size_t alignment) noexcept {
      static_cast<void>(size);
      static_cast<void>(alignment);
      ::operator delete(block);
    }
  };

  template <typename Value, typename... Arguments>
  TBC_CONSTRUCTS std::unique_ptr<Value> makeFrom(model_memory& memory, Arguments&&... arguments) {
    static_cast<void>(memory);
    return std::make_unique<Value>(std::forward<Arguments>(arguments)...);
  }

  // A standard allocator over the shared memory, as AllocatorRef is.
  template <typename Value>
  struct model_allocator {
    using value_type = Value;

    explicit model_allocator(model_memory& memory) noexcept
        : memory(&memory) {}

    template <typename Other>
    model_allocator(const model_allocator<Other>& other) noexcept
        : memory(other.memory) {}

    Value* allocate(std::size_t count) {
      return static_cast<Value*>(memory->allocate(count * sizeof(Value), alignof(Value)));
    }

    void deallocate(Value* block, std::size_t count) noexcept {
      memory->deallocate(block, count * sizeof(Value), alignof(Value));
    }

    template <typename Other>
    bool operator==(const model_allocator<Other>& other) const noexcept {
      return memory == other.memory;
    }

    model_memory* memory;
  };

  template <typename Value>
  class pane_slots {
  public:
    void insert(std::size_t identity, Value* value) noexcept {
      items_[identity % 4] = value;
    }

    Value* find(std::size_t identity) const noexcept {
      return items_[identity % 4];
    }

  private:
    std::array<Value*, 4> items_{};
  };

  // A command keeps the memory it was built with, as Command does.
  class pane_command {
  public:
    explicit pane_command(tbc::view<model_memory&, tbc::lt::a> memory) noexcept
        : memory_(memory) {}

    pane_command(const pane_command&) = delete;
    pane_command& operator=(const pane_command&) = delete;

  private:
    tbc::view<model_memory&, tbc::lt::a> memory_;
  };

  struct model_tab {
    std::size_t id;
    std::vector<std::size_t> panes;
  };

  struct model_workspace {
    explicit model_workspace(model_memory& memory)
        : tabs(model_allocator<model_tab>{memory}) {}

    model_tab* tab(std::size_t identity) noexcept {
      for (auto& candidate : tabs) {
        if (candidate.id == identity) {
          return &candidate;
        }
      }

      return nullptr;
    }

    std::vector<model_tab, model_allocator<model_tab>> tabs;
  };

  struct model_pane {
    int restored = 0;
  };

  struct runtime_model {
    pane_slots<model_pane> panes;
    pane_slots<model_workspace> workspaces;
  };

  class pane_launcher {
  public:
    explicit pane_launcher(tbc::view<model_memory&, tbc::lt::a> memory) noexcept
        : memory_(memory) {}

    pane_launcher(const pane_launcher&) = delete;
    pane_launcher& operator=(const pane_launcher&) = delete;

    tbc::view<model_pane&, tbc::lt::a> launch(tbc::view<runtime_model&, tbc::lt::a> model, pane_command& command, std::size_t identity) {
      static_cast<void>(command);
      auto pane = makeFrom<model_pane>(memory_);

      model.panes.insert(identity, pane.release());
      return *model.panes.find(identity);
    }

  private:
    tbc::view<model_memory&, tbc::lt::a> memory_;
  };

  inline std::size_t readIdentity(const std::size_t& identity) noexcept {
    return identity;
  }
}

int declarationSharedBorrowHeldLaunch(tbc::view<declarations::model_memory&, tbc::lt::a> memory, tbc::view<declarations::runtime_model&, tbc::lt::a> model, tbc::view<declarations::pane_launcher&, tbc::lt::a> panes, std::size_t workspace, std::size_t tab, std::size_t record) {
  declarations::pane_command command{memory};

  panes.launch(model, command, record);
  model.workspaces.find(workspace)->tab(tab)->panes.push_back(record);
  auto& pane = *model.panes.find(record);

  return pane.restored;
}

// END CASE

// CASE: declaration.shared_borrow_held_field
// PAIR: declaration.shared_borrow_held
// SOURCE: src/runtime/persistence/session_store/session_store.cppm :: Restore::restore(const PaneRecord&) (launches a pane, then lists it in its tab)
// STATUS: implemented
// CONTRACT: A shared object keeps valid the storage it hands out. A place found through a borrow of it that an object holds, past a field the shared type does not have, is such storage; growth there still ends the borrows of the object that owns it.
// SCENARIO: An element of a tab's pane list, a field the shared memory does not have, is read after the list grows; reject at the growth.
std::size_t declarationSharedBorrowHeldField(tbc::view<declarations::model_memory&, tbc::lt::a> memory, tbc::view<declarations::runtime_model&, tbc::lt::a> model, tbc::view<declarations::pane_launcher&, tbc::lt::a> panes, std::size_t workspace, std::size_t tab, std::size_t record) {
  declarations::pane_command command{memory};

  panes.launch(model, command, record);
  auto& first = model.workspaces.find(workspace)->tab(tab)->panes.front();

  model.workspaces.find(workspace)->tab(tab)->panes.push_back(record); // expected-error [tbc-invalidated-borrow]
  return declarations::readIdentity(first);
}

// END CASE

// CASE: declaration.shared_borrow_held_element
// PAIR: declaration.shared_borrow_held
// SOURCE: src/runtime/persistence/session_store/session_store.cppm :: Restore::restore(const PaneRecord&) (launches a pane, then lists it in its tab)
// STATUS: implemented
// CONTRACT: A shared object keeps valid the storage it hands out. A place found through a borrow of it that an object holds, past a field the shared type does not have, is such storage; growth there still ends the borrows of the object that owns it.
// SCENARIO: A tab found by scanning the workspace's list, an element no field names, is read after the list grows; reject at the growth.
std::size_t declarationSharedBorrowHeldElement(tbc::view<declarations::model_memory&, tbc::lt::a> memory, tbc::view<declarations::runtime_model&, tbc::lt::a> model, tbc::view<declarations::pane_launcher&, tbc::lt::a> panes, std::size_t workspace, std::size_t tab, std::size_t record) {
  declarations::pane_command command{memory};

  panes.launch(model, command, record);
  auto* found = model.workspaces.find(workspace)->tab(tab);

  model.workspaces.find(workspace)->tabs.push_back(declarations::model_tab{record, {}}); // expected-error [tbc-invalidated-borrow]
  return declarations::readIdentity(found->id);
}

// END CASE

// CASE: declaration.nested_reference_reached
// PAIR: declaration.nested_reference
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: ApplicationRelay::advance
// STATUS: implemented
// CONTRACT: A call that receives an object by mutable reference may mutate what it reaches through each mutable reference in turn, as a Rust `&mut` reaches through nested `&mut` fields.
// SCENARIO: The call receives a wrapper of a wrapper of the vector a borrow points into, so it may grow that vector; reject at the call.
namespace declarations {
  struct nested_inner {
    std::vector<int>& items;
  };

  struct nested_outer {
    nested_inner& inner;
  };

  void growNested(nested_outer& outer);
  void consume(int value);
}

void declarationNestedReferenceReached() {
  std::vector<int> items{1, 2};
  declarations::nested_inner inner{items};
  declarations::nested_outer outer{inner};
  const int& first = items.front();

  declarations::growNested(outer); // expected-error [tbc-invalidated-borrow]
  declarations::consume(first);
}

// END CASE

// CASE: declaration.nested_reference_shared
// PAIR: declaration.nested_reference
// SOURCE: src/runtime/proxy/runtime/runtime.cppm :: ApplicationRelay::advance
// STATUS: implemented
// CONTRACT: A call that receives an object by mutable reference may mutate what it reaches through each mutable reference in turn, as a Rust `&mut` reaches through nested `&mut` fields.
// SCENARIO: The inner wrapper refers to the vector through a reference to const, so the call cannot reach it mutably; accept.
namespace declarations {
  struct shared_inner {
    const std::vector<int>& items;
  };

  struct shared_outer {
    shared_inner& inner;
  };

  void readNested(shared_outer& outer);
}

void declarationNestedReferenceShared() {
  std::vector<int> items{1, 2};
  declarations::shared_inner inner{items};
  declarations::shared_outer outer{inner};
  const int& first = items.front();

  declarations::readNested(outer);
  declarations::consume(first);
}

// END CASE


// CASE: declaration.region_shared_kept
// PAIR: declaration.region_shared
// SOURCE: src/gui/features/prompt/prompt.cpp :: plan (the memory the state lives in builds the plan's words)
// STATUS: implemented
// CONTRACT: A result in a class region that refers to a shared object is what the one field of that region holding such a reference designates, as a `&'a Memory` copied out of a `State<'a>` is: a call that mutates an object keeping it leaves the input's other parts valid.
// SCENARIO: The state's memory builds a list that keeps it, which grows while a history entry of the state is read; accept.
namespace declarations {
  class TBC_SHARED region_memory {
  public:
    virtual ~region_memory() = default;
    virtual void* allocate(std::size_t size) = 0;
  };

  class region_text {
  public:
    region_text(tbc::view<region_memory&, tbc::lt::a> memory, std::string_view text);

    [[nodiscard]] std::string_view view() const noexcept {
      return {bytes_, 1};
    }

  private:
    tbc::view<region_memory*, tbc::lt::a> memory_;
    char* bytes_ = nullptr;
  };

  class region_list {
  public:
    explicit region_list(tbc::view<region_memory&, tbc::lt::a> memory) noexcept
        : memory_(&memory) {}

    template <typename... Arguments>
    region_text& emplace(Arguments&&... arguments) {
      items_ = static_cast<region_text*>(memory_->allocate(sizeof(region_text)));
      return *new (items_) region_text(std::forward<Arguments>(arguments)...);
    }

    [[nodiscard]] std::span<const region_text> view() const noexcept {
      return {static_cast<const region_text*>(items_), 1};
    }

  private:
    tbc::view<region_memory*, tbc::lt::a> memory_;
    region_text* items_ = nullptr;
  };

  class region_state {
    friend struct region_access;

  public:
    explicit region_state(tbc::view<region_memory&, tbc::lt::a> memory);

  private:
    tbc::view<region_memory&, tbc::lt::a> memory_;
    tbc::view<region_list, tbc::lt::a> history_;
  };

  struct region_access {
    static tbc::view<region_memory&, tbc::lt::a> memory(const region_state& state) {
      return state.memory_;
    }

    static const region_list& history(const region_state& state) {
      return state.history_;
    }

  };

  void growHistory(region_state& state);
}

void declarationRegionSharedKept(declarations::region_state& state) {
  auto& memory = declarations::region_access::memory(state);
  const std::string_view entry = declarations::region_access::history(state).view()[0].view();
  declarations::region_list words{memory};

  words.emplace(memory, entry);
  declarations::observe(entry);
}

// END CASE

// CASE: declaration.region_shared_mutated
// PAIR: declaration.region_shared
// SOURCE: src/gui/features/prompt/prompt.cpp :: plan (the memory the state lives in builds the plan's words)
// STATUS: implemented
// CONTRACT: A result in a class region that refers to a shared object is what the one field of that region holding such a reference designates, as a `&'a Memory` copied out of a `State<'a>` is: a call that mutates an object keeping it leaves the input's other parts valid.
// SCENARIO: The state the entry lies in is mutated while the list keeps its memory, before the entry is read; reject at the mutation.
void declarationRegionSharedMutated(declarations::region_state& state) {
  auto& memory = declarations::region_access::memory(state);
  const std::string_view entry = declarations::region_access::history(state).view()[0].view();
  declarations::region_list words{memory};

  words.emplace(memory, "x");
  declarations::growHistory(state); // expected-error [tbc-invalidated-borrow]
  declarations::observe(entry);
}

// END CASE

// CASE: declaration.output_shared_only_copied
// PAIR: declaration.output_shared_only
// SOURCE: src/gui/features/prompt/prompt.cpp :: ask (the root a path's question names is written in a buffer of the state)
// STATUS: implemented
// CONTRACT: A labeled output whose type labels its fields, all of them shared, keeps no other input of its region, as a Rust `&'b mut String` beside a `&'b str` cannot keep the text: a result in that region still borrows both.
// SCENARIO: A buffer that keeps only its memory is filled from a word and the result is read while the word lives; accept.
namespace declarations {
  struct shared_buffer_holder {
    region_text root;
  };

  tbc::view<std::string_view, tbc::lt::b> rooted(tbc::view<region_text&, tbc::lt::b> root, tbc::view<std::string_view, tbc::lt::b> word);
}

std::size_t declarationOutputSharedOnlyCopied(declarations::shared_buffer_holder& holder, std::string_view word) {
  const auto rooted = declarations::rooted(holder.root, word);
  return rooted.size();
}

// END CASE

// CASE: declaration.output_shared_only_kept
// PAIR: declaration.output_shared_only
// SOURCE: src/gui/features/prompt/prompt.cpp :: ask (the root a path's question names is written in a buffer of the state)
// STATUS: implemented
// CONTRACT: A labeled output whose type labels its fields, all of them shared, keeps no other input of its region, as a Rust `&'b mut String` beside a `&'b str` cannot keep the text: a result in that region still borrows both.
// SCENARIO: An output with a labeled view field can keep the word, which the caller's declaration does not let its holder keep; reject at the call.
namespace declarations {
  struct kept_word {
    tbc::view<std::string_view, tbc::lt::a> word;
  };

  struct kept_word_holder {
    kept_word kept;
  };

  tbc::view<std::string_view, tbc::lt::b> keep(tbc::view<kept_word&, tbc::lt::b> into, tbc::view<std::string_view, tbc::lt::b> word);
}

std::size_t declarationOutputSharedOnlyKept(declarations::kept_word_holder& holder, std::string_view word) {
  const auto kept = declarations::keep(holder.kept, word); // expected-error [tbc-contract-violation]
  return kept.size();
}

// END CASE

// CASE: declaration.shared_nested_sibling_pinned
// PAIR: declaration.shared_nested_sibling
// SOURCE: src/gui/application/application-session-layout.cpp :: Session::ensurePane (each pane's store counts against the graphics state's budget)
// STATUS: implemented
// CONTRACT: A field may keep a TBC_SHARED object another field holds only while their object can be neither copied nor moved, as it may keep a shared sibling.
// SCENARIO: A lender keeps the arena a state beside it holds, in a pinned object; accept.
namespace declarations {
  struct arena_state {
    arena memory;
  };

  class nested_pinned_pool {
  public:
    nested_pinned_pool()
        : lender_(state_.memory) {}

    nested_pinned_pool(const nested_pinned_pool&) = delete;
    nested_pinned_pool& operator=(const nested_pinned_pool&) = delete;

  private:
    arena_state state_;
    lender lender_;
  };
}

void declarationSharedNestedSiblingPinned() {
  const declarations::nested_pinned_pool pool;
  static_cast<void>(&pool);
}

// END CASE

// CASE: declaration.shared_nested_sibling_copied
// PAIR: declaration.shared_nested_sibling
// SOURCE: src/gui/application/application-session-layout.cpp :: Session::ensurePane (each pane's store counts against the graphics state's budget)
// STATUS: implemented
// CONTRACT: A field may keep a TBC_SHARED object another field holds only while their object can be neither copied nor moved, as it may keep a shared sibling.
// SCENARIO: The object holding the lender and the state can be copied; reject where the constructor lends the arena.
namespace declarations {
  class nested_copied_pool {
  public:
    nested_copied_pool()
        : lender_(state_.memory) {} // expected-error [tbc-dangling-borrow]

  private:
    arena_state state_;
    lender lender_;
  };
}

void declarationSharedNestedSiblingCopied() {
  const declarations::nested_copied_pool pool;
  static_cast<void>(&pool);
}

// END CASE
