#include "support.hpp"

// CASE: runtime.allocator_escape
// PAIR: runtime.allocator_dependency
// SOURCE: lib/base/memory/allocators/allocators.cppm :: AllocationDeleter / makeOwned
// STATUS: implemented
// CONTRACT: An allocated owner's deleter borrows the allocator until owner destruction.
// SCENARIO: Heap-allocated pointee lifetime does not rescue a dead stack allocator.
tbc::view<spec::allocated_int, tbc::lt::a> allocatorEscape() {
  spec::arena memory;
  return spec::makeOwned(memory); // expected-error [tbc-destructor-dependency]
}

// END CASE

// CASE: runtime.allocator_caller_owned
// PAIR: runtime.allocator_dependency
// SOURCE: lib/base/memory/allocators/allocators.cppm :: AllocationDeleter / makeOwned
// STATUS: implemented
// CONTRACT: A returned owner's allocator dependency is propagated to its caller.
// SCENARIO: The allocator is borrowed from a reference parameter, not created locally.
tbc::view<spec::allocated_int, tbc::lt::a> allocatorCallerOwned(tbc::view<spec::arena&, tbc::lt::a> memory) {
  return spec::makeOwned(memory);
}

// END CASE

// CASE: runtime.moved_owner_releases_view
// PAIR: runtime.owner_transfer
// SOURCE: lib/base/memory/allocators/allocators.cppm :: Owned
// STATUS: implemented
// CONTRACT: Moving unique_ptr transfers ownership; destroying the new owner invalidates views.
// SCENARIO: Follow the allocation to destination and diagnose reset, not the prior move.
void movedOwnerReleasesView() {
  auto source = std::make_unique<int>(1);
  tbc::view<const int&> view = *source;
  auto destination = std::move(source);
  destination.reset(); // expected-error [tbc-invalidated-borrow]
  spec::observe(view);
}

// END CASE

// CASE: runtime.moved_owner_preserves_view
// PAIR: runtime.owner_transfer
// SOURCE: lib/base/memory/allocators/allocators.cppm :: Owned
// STATUS: implemented
// CONTRACT: Moving a unique_ptr does not move its pointee or immediately dangle its views.
// SCENARIO: Accept a pointee read while the transferred allocation remains owned.
void movedOwnerPreservesView() {
  auto source = std::make_unique<int>(1);
  tbc::view<const int&> view = *source;
  auto destination = std::move(source);
  spec::observe(view);
  spec::observe(destination);
}

// END CASE

// CASE: runtime.queue_slot_removed
// PAIR: runtime.queue_slot
// SOURCE: src/runtime/workers/request_worker/request_worker.cppm :: operator[] / take
// STATUS: implemented
// CONTRACT: take destroys the old optional slot object after transferring its value.
// SCENARIO: A reference to that slot is invalid even if its value was moved elsewhere.
void queueSlotRemoved(tbc::view<spec::request_queue&> queue) {
  const auto& view = queue.front();
  const auto taken = queue.take(); // expected-error [tbc-invalidated-borrow]
  spec::observe(view);
  spec::observe(taken);
}

// END CASE

// CASE: runtime.queue_taken_owner
// PAIR: runtime.queue_slot
// SOURCE: src/runtime/workers/request_worker/request_worker.cppm :: take
// STATUS: implemented
// CONTRACT: The returned string owns its transferred value independently of the old slot.
// SCENARIO: A view acquired from the taken string remains valid after more queue removals.
void queueTakenOwner(tbc::view<spec::request_queue&> queue) {
  const auto taken = queue.take();
  spec::text view = taken;
  const auto other = queue.take();
  spec::observe(view);
  spec::observe(other);
}

// END CASE

// CASE: runtime.box_growth_keeps_value
// PAIR: runtime.box_owner
// SOURCE: lib/base/ds/ds.cppm :: Box
// STATUS: implemented
// CONTRACT: A class marked TBC_OWNER owns its value through an allocation of its own, as the standard library's unique owner does: the value lies one level below it, so moving the owner, as a growing vector does, leaves borrows of the value valid.
// SCENARIO: A boxed record's name is read after the vector holding the boxes grows; accept.
namespace spec_box {
  template <typename Value>
  class [[tbc::owner]] box {
  public:
    using element_type = Value;

    box() noexcept = default;

    explicit box(Value* value) noexcept
        : value_(value) {}

    box(const box&) = delete;
    box& operator=(const box&) = delete;

    box(box&& other) noexcept
        : value_(std::exchange(other.value_, nullptr)) {}

    box& operator=(box&& other) noexcept {
      delete value_;
      value_ = std::exchange(other.value_, nullptr);
      return *this;
    }

    ~box() {
      delete value_;
    }

    [[nodiscard]] const Value& get() const noexcept {
      return *value_;
    }

    [[nodiscard]] Value& getMut() noexcept {
      return *value_;
    }

    void reset() noexcept {
      delete value_;
      value_ = nullptr;
    }

    [[nodiscard]] Value* intoRaw() noexcept {
      return std::exchange(value_, nullptr);
    }

  private:
    Value* value_ = nullptr;
  };

  struct record {
    std::string name;
  };

  void observe(std::string_view text);
}

void runtimeBoxGrowthKeepsValue(std::vector<spec_box::box<spec_box::record>>& boxes) {
  const std::string_view name = boxes.front().get().name;

  boxes.push_back(spec_box::box<spec_box::record>{new spec_box::record{}});
  spec_box::observe(name);
}

// END CASE

// CASE: runtime.box_reset_ends_value
// PAIR: runtime.box_owner
// SOURCE: lib/base/ds/ds.cppm :: Box
// STATUS: implemented
// CONTRACT: A class marked TBC_OWNER owns its value through an allocation of its own, as the standard library's unique owner does: resetting it destroys the value, which ends every borrow of it.
// SCENARIO: A boxed record's name is read after its owner is reset; reject at the reset.
void runtimeBoxResetEndsValue(spec_box::box<spec_box::record>& owner) {
  const std::string_view name = owner.get().name;

  owner.reset(); // expected-error [tbc-invalidated-borrow]
  spec_box::observe(name);
}

// END CASE

// CASE: runtime.box_into_raw_hands_over
// PAIR: runtime.box_owner
// SOURCE: src/runtime/core/model/slot_store/slot_store.cppm :: SlotStore::insertProvisional
// STATUS: implemented
// CONTRACT: A class marked TBC_OWNER owns its value through an allocation of its own, as the standard library's unique owner does: `intoRaw`, as Rust's `Box::into_raw`, hands the value to an owner the analysis does not see, so the pointer it returns borrows nothing of the owner.
// SCENARIO: A store keeps the raw pointer a boxed parameter hands over; accept.
namespace spec_box {
  struct slots {
    void keep(box<record> value) {
      items[0] = value.intoRaw();
    }

    record* items[4]{};
  };

  record* handOver() {
    return box<record>{}.intoRaw();
  }
}

// END CASE
