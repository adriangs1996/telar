#include "system_library.hpp"

#include <tbc/annotations.hpp>

#include <cstddef>
#include <memory>
#include <span>
#include <string_view>
#include <vector>

// CASE: constness.distinct_names
// PAIR: constness.accessors
// SOURCE: lib/base/text/json/json.cppm :: JsonNode::find
// STATUS: implemented
// CONTRACT: A project type never overloads a method on constness: a read is a const method, and mutable access has a name of its own, as Rust's `get` and `get_mut`.
// SCENARIO: The lookup that reads is const, and the one that gives mutable access is named apart; accept.
namespace constness {
  class named_node {
  public:
    [[nodiscard]] std::span<const named_node> children() const noexcept;
    [[nodiscard]] std::span<named_node> childrenMut() noexcept;
    [[nodiscard]] const named_node* find(std::string_view name) const noexcept;
    [[nodiscard]] named_node* findMut(std::string_view name) noexcept;

  private:
    std::vector<named_node> children_;
  };
}

// END CASE

// CASE: constness.overloaded_accessors
// PAIR: constness.accessors
// SOURCE: lib/base/text/json/json.cppm :: JsonNode::find
// STATUS: implemented
// CONTRACT: A project type never overloads a method on constness: a read is a const method, and mutable access has a name of its own, as Rust's `get` and `get_mut`.
// SCENARIO: Each lookup is overloaded on constness, so a read through a non-const node would pick the overload that lends it exclusively; reject each non-const overload.
namespace constness {
  class overloaded_node {
  public:
    [[nodiscard]] std::span<overloaded_node> children() noexcept; // expected-error [tbc-const-overload]
    [[nodiscard]] std::span<const overloaded_node> children() const noexcept;
    [[nodiscard]] overloaded_node* find(std::string_view name) noexcept; // expected-error [tbc-const-overload]
    [[nodiscard]] const overloaded_node* find(std::string_view name) const noexcept;

  private:
    std::vector<overloaded_node> children_;
  };
}

// END CASE

// CASE: constness.mutable_access_ends_children
// PAIR: constness.accessors
// SOURCE: lib/base/text/json/json.cppm :: JsonNode::find
// STATUS: implemented
// CONTRACT: A project type never overloads a method on constness: a read is a const method, and mutable access has a name of its own, as Rust's `get` and `get_mut`.
// SCENARIO: The lookup for mutable access lends the whole node, so it ends the view of its children; reject at the call, in a unit whose other cases report overloads on constness first.
std::size_t constnessMutableAccess(constness::named_node& root) {
  const auto children = root.children();

  static_cast<void>(root.findMut("name")); // expected-error [tbc-invalidated-borrow]
  return children.size();
}

// END CASE

// CASE: constness.rvalue_receiver
// PAIR: constness.qualifiers
// SOURCE: lib/base/memory/containers/containers.cppm :: DropChannel::take
// STATUS: implemented
// CONTRACT: Only constness counts: an overload that an rvalue receiver selects moves out of the object rather than reading it.
// SCENARIO: The value is read through a const lvalue receiver and moved out of an rvalue one; accept.
namespace constness {
  template <typename type>
  class slot {
  public:
    [[nodiscard]] const type& value() const& noexcept;
    [[nodiscard]] type&& value() && noexcept;

  private:
    type value_;
  };
}

// END CASE

// CASE: constness.template_overloads
// PAIR: constness.qualifiers
// SOURCE: lib/base/memory/containers/containers.cppm :: SlotIndexes::forEach
// STATUS: implemented
// CONTRACT: Only constness counts: an overload that an rvalue receiver selects moves out of the object rather than reading it.
// SCENARIO: A member template is overloaded on constness alone, as a visitor over the elements would be; reject the non-const overload.
namespace constness {
  class indexes {
  public:
    template <typename visitor>
    void forEach(visitor&& visit); // expected-error [tbc-const-overload]
    template <typename visitor>
    void forEach(visitor&& visit) const;

  private:
    std::vector<std::size_t> words_;
  };
}

// END CASE

// CASE: constness.library_override
// PAIR: constness.overrides
// SOURCE: src/gui/ui/app/application_controller.cpp :: ApplicationController
// STATUS: implemented
// CONTRACT: An override takes its signature from the method it overrides, so only the declaration that introduces a method is checked.
// SCENARIO: An item overrides the library's update next to a const helper of the same name and parameters; the override's signature is the library's; accept.
namespace constness {
  class scene_item : public library::item {
  public:
    library::node* update(library::node* previous) override;
    library::node* update(library::node* previous) const;
  };
}

// END CASE

// CASE: constness.project_overload
// PAIR: constness.overrides
// SOURCE: src/gui/ui/app/application_controller.cpp :: ApplicationController
// STATUS: implemented
// CONTRACT: An override takes its signature from the method it overrides, so only the declaration that introduces a method is checked.
// SCENARIO: The same pair introduced by a project class is an overload on constness; reject the non-const one.
namespace constness {
  class project_item {
  public:
    library::node* update(library::node* previous); // expected-error [tbc-const-overload]
    library::node* update(library::node* previous) const;
  };
}

// END CASE

// The objects a controller reaches: a store it changes and a counter shared by everything that counts.
namespace constness {
  struct store {
    std::vector<int> rows;

    void clear() noexcept {
      rows.clear();
    }
  };

  class TBC_SHARED counter {
  public:
    void add() noexcept {
      ++count_;
    }

  private:
    int count_ = 0;
  };

  struct opaque_handle;

  extern "C" void opaque_poke(opaque_handle* handle);
}

// CASE: constness.shared_reads
// PAIR: constness.shared_access
// SOURCE: src/gui/ui/app/panes/terminal/history/history_controller.cpp :: HistoryController::busy
// STATUS: implemented
// CONTRACT: A const method, or a reference to const, lends shared everything its object reaches, as Rust's `&T` does: nothing reached through a reference, a pointer or a smart pointer changes through it, except a shared type, a synchronization primitive or an opaque C object.
// SCENARIO: A const method reads the store it refers to, counts on a shared counter and hands an opaque C handle to C; accept.
namespace constness {
  class reader {
  public:
    reader(store& rows, counter& reads, opaque_handle* handle) noexcept
        : store_(rows),
          reads_(reads),
          handle_(handle) {}

    [[nodiscard]] std::size_t size() const noexcept {
      reads_.add();
      opaque_poke(handle_);
      return store_.rows.size();
    }

  private:
    store& store_;
    counter& reads_;
    opaque_handle* handle_;
  };
}

// END CASE

// CASE: constness.shared_reference_mutation
// PAIR: constness.shared_access
// SOURCE: src/gui/ui/app/panes/terminal/history/history_controller.cpp :: HistoryController::busy
// STATUS: implemented
// CONTRACT: A const method, or a reference to const, lends shared everything its object reaches, as Rust's `&T` does: nothing reached through a reference, a pointer or a smart pointer changes through it, except a shared type, a synchronization primitive or an opaque C object.
// SCENARIO: A const method clears the store it refers to, which its callers rely on staying as it was; reject at the reference.
namespace constness {
  class clearer {
  public:
    explicit clearer(store& rows) noexcept
        : store_(rows) {}

    void reset() const noexcept {
      store_.clear(); // expected-error [tbc-contract-violation]
    }

  private:
    store& store_;
  };
}

// END CASE

// CASE: constness.shared_pointer_mutation
// PAIR: constness.shared_access
// SOURCE: src/gui/ui/app/panes/terminal/terminal_item.hpp :: TerminalItem::viewFolds
// STATUS: implemented
// CONTRACT: A const method, or a reference to const, lends shared everything its object reaches, as Rust's `&T` does: nothing reached through a reference, a pointer or a smart pointer changes through it, except a shared type, a synchronization primitive or an opaque C object.
// SCENARIO: A function that receives a view by reference to const appends through the pointer the view holds; reject at the pointer.
namespace constness {
  struct rows_view {
    std::vector<int>* rows;
  };

  void appendThrough(const rows_view& view) {
    view.rows->push_back(1); // expected-error [tbc-contract-violation]
  }
}

// END CASE

// CASE: constness.shared_owner_mutation
// PAIR: constness.shared_access
// SOURCE: src/gui/ui/app/panes/terminal/terminal_item.hpp :: TerminalItem::viewFolds
// STATUS: implemented
// CONTRACT: A const method, or a reference to const, lends shared everything its object reaches, as Rust's `&T` does: nothing reached through a reference, a pointer or a smart pointer changes through it, except a shared type, a synchronization primitive or an opaque C object.
// SCENARIO: A const method clears the store a unique_ptr field owns, which is part of the object as a Rust `Box` is; reject at the owner's access.
namespace constness {
  class owner {
  public:
    void reset() const noexcept {
      owned_->clear(); // expected-error [tbc-contract-violation]
    }

  private:
    std::unique_ptr<store> owned_;
  };
}

// END CASE
