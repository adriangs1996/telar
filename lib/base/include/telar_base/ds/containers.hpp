#pragma once

#include "tbc/annotations.hpp"
#include "tbc/view.hpp"
#include "telar_base/diagnostics/config.hpp"
#include "telar_base/ds/values.hpp"
#include "telar_base/memory/allocator.hpp"
#include <algorithm>
#include <bit>
#include <compare>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <format>
#include <functional>
#include <limits>
#include <memory>
#include <new>
#include <span>
#include <string_view>
#include <type_traits>
#include <utility>

// The containers of telar::ds that take their memory from an allocator; see telar_base/ds/values.hpp.
namespace telar::ds {

  // Allocates bytes for a container, which throws where the allocator fails, as Rust's allocation
  // failure aborts rather than returning null.
  template <Allocator Memory>
  TBC_GENERIC void* allocateBytes(Memory& memory, std::size_t size, std::size_t alignment) {
    auto* storage = memory.allocate(size, alignment);
    if (storage == nullptr) {
      throw std::bad_alloc{};
    }

    return storage;
  }

  // One value in an allocation of its own from an allocator, as Rust's `Box`, or none yet, as
  // `Option<Box>` is one pointer: a default Box holds nothing until a `makeBox` is assigned to it.
  // Shared access is deep, as through Rust's `&Box<T>`: a const Box hands out a const value, and
  // `getMut` the mutable one. Moving it moves the pointer, so what borrows the value outlives the
  // Box's moves, as a Vec of them growing.
  template <typename Value, Allocator Memory>
  class TBC_OWNER TBC_GENERIC Box {
  public:
    using element_type = Value;

    Box() noexcept = default;

    Box(const Box&) = delete;
    Box& operator=(const Box&) = delete;

    Box(Box&& other) noexcept
        : value_(std::exchange(other.value_, nullptr)),
          memory_(other.memory_) {}

    Box& operator=(Box&& other) noexcept {
      if (this != &other) {
        drop();
        value_ = std::exchange(other.value_, nullptr);
        memory_ = other.memory_;
      }

      return *this;
    }

    ~Box() {
      drop();
    }

    [[nodiscard]] bool hasValue() const noexcept {
      return value_ != nullptr;
    }

    explicit operator bool() const noexcept {
      return hasValue();
    }

    // Destroys the value, leaving none.
    void reset() noexcept {
      drop();
    }

    // Takes back a value `intoRaw` handed out, from `memory`, as Rust's `Box::from_raw`: the caller
    // answers for it being one, as unsafe Rust does.
    [[nodiscard]] static Box fromRaw(Value* value, Memory& memory) noexcept {
      return Box{value, memory};
    }

    // Hands the value over to foreign code that keeps it by address, leaving none, as Rust's
    // `Box::into_raw`: `fromRaw` frees it again.
    [[nodiscard]] Value* intoRaw() noexcept {
      return std::exchange(value_, nullptr);
    }

    // Hands the value over to shared owners, which free it in the same memory once the last one goes,
    // as Rust's `Arc::from(Box)`; their count lives where std::shared_ptr keeps it.
    [[nodiscard]] std::shared_ptr<Value> intoShared() && {
      if (value_ == nullptr) {
        return {};
      }

      auto* memory = memory_;

      return std::shared_ptr<Value>{std::exchange(value_, nullptr), [memory](Value* value) noexcept {
                                      fromRaw(value, *memory).reset();
                                    }};
    }

    [[nodiscard]] const Value& get() const noexcept {
      TELAR_ASSERT(value_ != nullptr);
      return *value_;
    }

    [[nodiscard]] Value& getMut() noexcept {
      TELAR_ASSERT(value_ != nullptr);
      return *value_;
    }

    [[nodiscard]] const Value& operator*() const noexcept {
      return get();
    }

    [[nodiscard]] const Value* operator->() const noexcept {
      return &get();
    }

  private:
    template <typename Boxed, Allocator Source, typename... Arguments>
    friend Box<Boxed, Source> makeBox(Source& memory, Arguments&&... arguments);

    Box(Value* value, Memory& memory) noexcept
        : value_(value),
          memory_(&memory) {}

    void drop() noexcept {
      if (value_ != nullptr) {
        std::destroy_at(value_);
        memory_->deallocate(value_, sizeof(Value), alignof(Value));
        value_ = nullptr;
      }
    }

    Value* value_ = nullptr;
    Memory* memory_ = nullptr;
  };

  // A Box holding the Value its arguments construct, in `memory`; it keeps what Value's constructor
  // keeps of them, and the allocator.
  template <typename Value, Allocator Memory, typename... Arguments>
  TBC_CONSTRUCTS TBC_GENERIC Box<Value, Memory> makeBox(Memory& memory, Arguments&&... arguments) {
    auto* value = static_cast<Value*>(allocateBytes(memory, sizeof(Value), alignof(Value)));

    try {
      std::construct_at(value, std::forward<Arguments>(arguments)...);
    } catch (...) {
      memory.deallocate(value, sizeof(Value), alignof(Value));
      throw;
    }

    return Box<Value, Memory>{value, memory};
  }

  // The high and low halves of a 128-bit product folded together: every bit of either factor
  // reaches every bit of the result, as wyhash and rapidhash mix.
  TBC_HOT_PATH inline std::uint64_t mix(std::uint64_t left, std::uint64_t right) noexcept {
    const auto product = static_cast<unsigned __int128>(left) * right;

    return static_cast<std::uint64_t>(product) ^ static_cast<std::uint64_t>(product >> 64);
  }

  TBC_HOT_PATH inline std::uint64_t read64(const char* bytes) noexcept {
    std::uint64_t value;

    std::memcpy(&value, bytes, sizeof(value));
    return value;
  }

  TBC_HOT_PATH inline std::uint64_t read32(const char* bytes) noexcept {
    std::uint32_t value;

    std::memcpy(&value, bytes, sizeof(value));
    return value;
  }

  // Copies up to 23 bytes, as an inline String holds, with overlapping word moves rather than a call
  // to memcpy, which costs more than the copy at these sizes.
  TBC_HOT_PATH inline void copyShort(char* target, const char* source, std::size_t count) noexcept {
    if (count >= 8) {
      const auto first = read64(source);
      const auto last = read64(source + count - 8);

      if (count > 16) {
        const auto middle = read64(source + 8);

        std::memcpy(target + 8, &middle, sizeof(middle));
      }

      std::memcpy(target, &first, sizeof(first));
      std::memcpy(target + count - 8, &last, sizeof(last));
    } else if (count >= 4) {
      const auto first = static_cast<std::uint32_t>(read32(source));
      const auto last = static_cast<std::uint32_t>(read32(source + count - 4));

      std::memcpy(target, &first, sizeof(first));
      std::memcpy(target + count - 4, &last, sizeof(last));
    } else if (count > 0) {
      target[0] = source[0];
      target[count >> 1] = source[count >> 1];
      target[count - 1] = source[count - 1];
    }
  }

  inline constexpr std::uint64_t hash_secrets[] = {
      0x2d358dccaa6c78a5,
      0x8bb84b93962eacc9,
      0x4b33a62ed433d4a3,
      0x4d5a2da51de1aa47,
  };

  // Where this constant lies moves with address space layout randomization, so its address seeds
  // hashes per process and keys cannot be chosen ahead of time to collide.
  inline constexpr char hash_anchor = 0;

  TBC_HOT_PATH inline std::uint64_t hashSeed() noexcept {
    return hash_secrets[0] ^ reinterpret_cast<std::uintptr_t>(&hash_anchor);
  }

  // Eight control bytes of a Map read as one word, as abseil's portable group. A full slot's byte is
  // seven bits of its key's hash; an empty or removed slot's has the top bit set, and so does the
  // sentinel that ends iteration.
  struct TBC_HOT_PATH Group {
    static_assert(std::endian::native == std::endian::little, "a slot's byte is the word's byte of the same rank");

    static constexpr std::size_t width = 8;
    static constexpr std::int8_t empty = -128;
    static constexpr std::int8_t removed = -2;
    static constexpr std::int8_t sentinel = -1;
    static constexpr std::uint64_t low_bits = 0x0101010101010101;
    static constexpr std::uint64_t high_bits = 0x8080808080808080;

    [[nodiscard]] static std::uint64_t load(const std::int8_t* control) noexcept {
      std::uint64_t word;

      std::memcpy(&word, control, sizeof(word));
      return word;
    }

    // The slots whose byte is `tag`. A full slot right after one of them may come out too, which
    // comparing its key rules out; an empty or removed slot never does.
    [[nodiscard]] static std::uint64_t match(std::uint64_t word, std::uint8_t tag) noexcept {
      const auto difference = word ^ (low_bits * tag);

      return (difference - low_bits) & ~difference & high_bits;
    }

    [[nodiscard]] static std::uint64_t matchEmpty(std::uint64_t word) noexcept {
      return word & ~(word << 6) & high_bits;
    }

    [[nodiscard]] static std::uint64_t matchEmptyOrRemoved(std::uint64_t word) noexcept {
      return word & ~(word << 7) & high_bits;
    }

    // How many slots from the first are empty or removed, up to the group's width.
    [[nodiscard]] static std::size_t leadingEmptyOrRemoved(std::uint64_t word) noexcept {
      return static_cast<std::size_t>(std::countr_zero((word | ~(word >> 7)) & low_bits) + 1) >> 3;
    }

    // The rank of the first slot a match holds.
    [[nodiscard]] static std::size_t first(std::uint64_t matches) noexcept {
      return static_cast<std::size_t>(std::countr_zero(matches)) >> 3;
    }

    // The rank of the last slot a match holds, counted from the group's end.
    [[nodiscard]] static std::size_t lastFromEnd(std::uint64_t matches) noexcept {
      return static_cast<std::size_t>(std::countl_zero(matches)) >> 3;
    }
  };

  // The control bytes of every empty Map, so that a lookup in one needs no test for storage.
  alignas(Group::width) inline constexpr Array<std::int8_t, Group::width> empty_group = {
      Group::sentinel,
      Group::empty,
      Group::empty,
      Group::empty,
      Group::empty,
      Group::empty,
      Group::empty,
      Group::empty,
  };

  // What a Map looks a key up by: text keys by any text, as a std::string_view, so that a lookup
  // builds no key; other scalars by value.
  template <typename Key>
  using KeyLookup = std::conditional_t<
      std::is_convertible_v<const Key&, std::string_view>,
      std::string_view,
      std::conditional_t<std::is_scalar_v<Key>, Key, const Key&>>;

  // A growable sequence in memory from an allocator, as Rust's `Vec<T>`. Copying allocates, so it is
  // explicit (`clone`); moving hands the storage over, or moves the values when the destination's
  // allocator is another one. Values relocate without throwing, as Rust moves them, and as bytes
  // where they can. The value type may be incomplete where a Vec of it is declared, as a tree's node
  // holds a Vec of nodes; it is checked where a Vec is destroyed.
  template <typename Value, Allocator Memory>
  class TBC_GENERIC Vec {
  public:
    explicit Vec(tbc::view<Memory&, tbc::lt::a> memory) noexcept
        : memory_(&memory) {}

    // Copies the values, so the Vec borrows nothing of them. The storage holds exactly them, as Rust's
    // `to_vec` does: a copy is not expected to grow.
    Vec(tbc::view<Memory&, tbc::lt::a> memory, std::span<const Value> values)
      requires std::is_copy_constructible_v<Value>
        : memory_(&memory) {
      reserve(values.size());
      extend(values);
    }

    Vec(const Vec&) = delete;
    Vec& operator=(const Vec&) = delete;

    Vec(Vec&& other) noexcept
        : memory_(other.memory_),
          items_(std::exchange(other.items_, nullptr)),
          size_(std::exchange(other.size_, 0)),
          capacity_(std::exchange(other.capacity_, 0)) {}

    Vec& operator=(Vec&& other) {
      if (this == &other) {
        return *this;
      }

      if (memory_ == other.memory_) {
        release();
        items_ = std::exchange(other.items_, nullptr);
        size_ = std::exchange(other.size_, 0);
        capacity_ = std::exchange(other.capacity_, 0);
        return *this;
      }

      // Storage goes back to the allocator it came from, so values move between allocators one by one.
      clear();
      reserve(other.size_);
      for (std::size_t index = 0; index < other.size_; ++index) {
        std::construct_at(items_ + index, std::move(other.items_[index]));
      }

      size_ = other.size_;
      other.release();
      return *this;
    }

    ~Vec() {
      static_assert(std::is_nothrow_move_constructible_v<Value>, "a Vec relocates its values without throwing, as Rust moves them");

      release();
    }

    // The copy lives in the allocator's region, as its storage does, and borrows nothing else of this
    // Vec. Values that copy only explicitly, as a String, are cloned one by one.
    [[nodiscard]] tbc::view<Vec, tbc::lt::a> clone() const
      requires std::is_copy_constructible_v<Value> || requires(const Value& value) {
        { value.clone() } -> std::same_as<Value>;
      }
    {
      Vec copy{*memory_};

      copy.reserve(size_);
      if constexpr (std::is_copy_constructible_v<Value>) {
        copy.extend(view());
      } else {
        for (std::size_t index = 0; index < size_; ++index) {
          copy.push(items_[index].clone());
        }
      }

      return copy;
    }

    [[nodiscard]] std::size_t size() const noexcept {
      return size_;
    }

    [[nodiscard]] std::size_t capacity() const noexcept {
      return capacity_;
    }

    [[nodiscard]] bool empty() const noexcept {
      return size_ == 0;
    }

    [[nodiscard]] const Value& operator[](std::size_t index) const noexcept {
      TELAR_ASSERT(index < size_);
      return items_[index];
    }

    [[nodiscard]] Value& atMut(std::size_t index) noexcept {
      TELAR_ASSERT(index < size_);
      return items_[index];
    }

    [[nodiscard]] const Value& front() const noexcept {
      return (*this)[0];
    }

    [[nodiscard]] Value& frontMut() noexcept {
      return atMut(0);
    }

    [[nodiscard]] const Value& back() const noexcept {
      TELAR_ASSERT(size_ != 0);
      return items_[size_ - 1];
    }

    [[nodiscard]] Value& backMut() noexcept {
      TELAR_ASSERT(size_ != 0);
      return items_[size_ - 1];
    }

    [[nodiscard]] const Value* data() const noexcept {
      return items_;
    }

    [[nodiscard]] Value* dataMut() noexcept {
      return items_;
    }

    [[nodiscard]] std::span<const Value> view() const noexcept {
      // The span's constructor is given shared access to the values, as this method has.
      return {static_cast<const Value*>(items_), size_};
    }

    [[nodiscard]] std::span<Value> viewMut() noexcept {
      return {items_, size_};
    }

    [[nodiscard]] const Value* begin() const noexcept {
      return items_;
    }

    [[nodiscard]] const Value* end() const noexcept {
      return items_ + size_;
    }

    [[nodiscard]] tbc::view<Memory&, tbc::lt::a> memory() const noexcept {
      return *memory_;
    }

    // Makes room for at least `count` values without moving them again until the size passes it.
    void reserve(std::size_t count) {
      if (count > capacity_) {
        reallocate(count);
      }
    }

    // Takes the value itself, as Rust's `push` does, so a value read from this Vec is copied before the
    // call can move the storage it lies in.
    Value& push(Value value) {
      return emplace(std::move(value));
    }

    // Constructs a value at the end. The new value is constructed before the others move to larger
    // storage, so the arguments stay valid while it is.
    template <typename... Arguments>
    Value& emplace(Arguments&&... arguments) {
      if (size_ < capacity_) [[likely]] {
        auto* slot = std::construct_at(items_ + size_, std::forward<Arguments>(arguments)...);

        ++size_;
        return *slot;
      }

      const auto capacity = grownCapacity(size_ + 1);
      auto* storage = allocate(capacity);
      Value* slot = nullptr;

      try {
        slot = std::construct_at(storage + size_, std::forward<Arguments>(arguments)...);
      } catch (...) {
        deallocate(storage, capacity);
        throw;
      }

      relocate(storage);
      deallocate(items_, capacity_);
      items_ = tbc::raw(storage);
      capacity_ = capacity;
      ++size_;
      return *slot;
    }

    // Removes the last value and hands it back, as Rust's `pop`.
    // The value leaves with what it borrows, region `a`, and none of this Vec's storage, as Rust's `-> T`.
    [[nodiscard]] tbc::view<Option<Value>, tbc::lt::a> pop() noexcept(std::is_nothrow_move_constructible_v<Value>) {
      if (size_ == 0) {
        return {};
      }

      --size_;
      // Emplaced, so that the value moves once rather than through Option's by-value constructor.
      Option<Value> last;

      last.emplace(std::move(items_[size_]));

      std::destroy_at(items_ + size_);
      return last;
    }

    // Destroys the values past the first `count`.
    void truncate(std::size_t count) noexcept {
      if (count >= size_) {
        return;
      }

      std::destroy(items_ + count, items_ + size_);
      size_ = count;
    }

    void clear() noexcept {
      truncate(0);
    }

    // Grows with value-initialized values, or truncates.
    void resize(std::size_t count)
      requires std::is_default_constructible_v<Value>
    {
      if (count <= size_) {
        truncate(count);
        return;
      }

      reserve(count);
      std::uninitialized_value_construct(items_ + size_, items_ + count);
      size_ = count;
    }

    // Grows with copies of the value, which the call takes itself, or truncates.
    void resize(std::size_t count, Value value)
      requires std::is_copy_constructible_v<Value>
    {
      if (count <= size_) {
        truncate(count);
        return;
      }

      reserve(count);
      std::uninitialized_fill(items_ + size_, items_ + count, value);
      size_ = count;
    }

    // Inserts a value before the one at `index`, moving the later ones up.
    Value& insert(std::size_t index, Value value) {
      TELAR_ASSERT(index <= size_);
      if (index == size_) {
        return emplace(std::move(value));
      }

      // Growing places the new value straight in its slot and the others around it.
      if (size_ == capacity_) {
        const auto capacity = grownCapacity(size_ + 1);
        auto* storage = tbc::raw(allocate(capacity));

        std::construct_at(storage + index, std::move(value));
        relocate(items_, index, storage);
        relocate(items_ + index, size_ - index, storage + index + 1);
        deallocate(items_, capacity_);
        items_ = tbc::raw(storage);
        capacity_ = capacity;
        ++size_;
        return items_[index];
      }

      // The later values move up one slot each: as bytes when they can, as std::vector does.
      if constexpr (relocatable<Value>) {
        std::memmove(static_cast<void*>(items_ + index + 1), static_cast<const void*>(items_ + index), (size_ - index) * sizeof(Value));
        std::construct_at(items_ + index, std::move(value));
      } else {
        std::construct_at(items_ + size_, std::move(items_[size_ - 1]));
        std::move_backward(items_ + index, items_ + size_ - 1, items_ + size_);
        items_[index] = std::move(value);
      }

      ++size_;
      return items_[index];
    }

    // Removes the value at `index` and hands it back, moving the later ones down, as Rust's `remove`:
    // it leaves with what it borrows, region `a`, and none of this Vec's storage.
    tbc::view<Value, tbc::lt::a> remove(std::size_t index) {
      TELAR_ASSERT(index < size_);
      Value removed = std::move(items_[index]);

      std::move(items_ + index + 1, items_ + size_, items_ + index);
      --size_;
      std::destroy_at(items_ + size_);
      return removed;
    }

    // Appends copies of the values.
    // Returns the storage past its values to the allocator, as Rust's `shrink_to_fit`.
    void shrinkToFit() {
      if (capacity_ == size_) {
        return;
      }

      if (size_ == 0) {
        release();
        return;
      }

      reallocate(size_);
    }

    // Keeps the values `keep` accepts, in their order, and drops the others, as Rust's `retain`.
    // Returns how many it dropped.
    template <typename Predicate>
    std::size_t retain(Predicate keep) {
      std::size_t kept = 0;

      for (std::size_t index = 0; index < size_; ++index) {
        if (!keep(std::as_const(items_[index]))) {
          continue;
        }

        // A different slot, `kept` being behind `index`: read through a raw pointer, as Rust's `retain`
        // moves values within its buffer.
        if (kept != index) {
          items_[kept] = std::move(*tbc::raw(items_ + index));
        }

        ++kept;
      }

      const auto dropped = size_ - kept;

      truncate(kept);
      return dropped;
    }

    void extend(std::span<const Value> values)
      requires std::is_copy_constructible_v<Value>
    {
      if (values.empty()) {
        return;
      }

      const auto count = size_ + values.size();
      if (count > capacity_) {
        const auto capacity = grownCapacity(count);
        auto* storage = allocate(capacity);

        try {
          copy(values, storage + size_);
        } catch (...) {
          deallocate(storage, capacity);
          throw;
        }

        relocate(storage);
        deallocate(items_, capacity_);
        items_ = tbc::raw(storage);
        capacity_ = capacity;
      } else {
        copy(values, items_ + size_);
      }

      size_ = count;
    }

    friend bool operator==(const Vec& left, const Vec& right)
      requires std::equality_comparable<Value>
    {
      return std::ranges::equal(left.view(), right.view());
    }

  private:
    // Doubles the capacity, so that n appends move each value a constant number of times on average.
    [[nodiscard]] std::size_t grownCapacity(std::size_t required) const noexcept {
      return std::max({required, capacity_ * 2, minimum_capacity});
    }

    [[nodiscard]] Value* allocate(std::size_t count) {
      if (count > std::numeric_limits<std::size_t>::max() / sizeof(Value)) {
        throw std::bad_array_new_length{};
      }

      auto* storage = static_cast<Value*>(memory_->allocate(count * sizeof(Value), alignof(Value)));
      if (storage == nullptr) {
        throw std::bad_alloc{};
      }

      return storage;
    }

    void deallocate(Value* storage, std::size_t count) noexcept {
      if (storage != nullptr) {
        memory_->deallocate(storage, count * sizeof(Value), alignof(Value));
      }
    }

    // Moves the values into storage of at least `capacity` values.
    void reallocate(std::size_t capacity) {
      auto* storage = allocate(capacity);

      relocate(storage);
      deallocate(items_, capacity_);
      items_ = tbc::raw(storage);
      capacity_ = capacity;
    }

    // Moves the values into new storage and ends their lifetimes in the old one.
    void relocate(Value* storage) noexcept {
      relocate(items_, size_, storage);
    }

    static void relocate(Value* from, std::size_t count, Value* to) noexcept {
      if constexpr (relocatable<Value>) {
        if (count != 0) {
          std::memcpy(static_cast<void*>(to), static_cast<const void*>(from), count * sizeof(Value));
        }
      } else {
        std::uninitialized_move(from, from + count, to);
        std::destroy(from, from + count);
      }
    }

    // Copies values into uninitialized storage: as bytes when they are trivially copyable, which
    // std::uninitialized_copy leaves to a loop.
    static void copy(std::span<const Value> values, Value* to) {
      if constexpr (std::is_trivially_copyable_v<Value>) {
        if (!values.empty()) {
          std::memcpy(static_cast<void*>(to), static_cast<const void*>(values.data()), values.size_bytes());
        }
      } else {
        std::uninitialized_copy(values.begin(), values.end(), to);
      }
    }

    void release() noexcept {
      std::destroy(items_, items_ + size_);
      deallocate(items_, capacity_);
      items_ = nullptr;
      size_ = 0;
      capacity_ = 0;
    }

    // Small Vecs grow straight to a cache line's worth of values rather than through 1, 2 and 4.
    static constexpr std::size_t minimum_capacity = std::max<std::size_t>(1, 64 / sizeof(Value));

    tbc::view<Memory*, tbc::lt::a> memory_;
    // The values live in storage from the allocator, region `a`, as a Rust `Vec<'a, T>` in an arena keeps them.
    tbc::view<Value*, tbc::lt::a> items_ = nullptr;
    std::size_t size_ = 0;
    std::size_t capacity_ = 0;
  };

  // Owned bytes in memory from an allocator, as Rust's `String`, followed by a NUL for C. Up to 23
  // bytes live inline, all the room beside the allocator, so a short String does not allocate. It
  // keeps no pointer into itself, so containers relocate it as its bytes. Copying allocates, so it is
  // explicit (`clone`).
  template <Allocator Memory>
  class TBC_GENERIC String {
  public:
    using trivially_relocatable = String;

    explicit String(tbc::view<Memory&, tbc::lt::a> memory) noexcept
        : memory_(&memory) {
      setInlineSize(0);
    }

    // Copies the text, so the String borrows nothing of it.
    String(tbc::view<Memory&, tbc::lt::a> memory, std::string_view text)
        : memory_(&memory) {
      if (text.size() <= inline_capacity) [[likely]] {
        copyShort(representation_.bytes, text.data(), text.size());
        setInlineSize(text.size());
        return;
      }

      setInlineSize(0);
      reallocate(roundedCapacity(text.size()), text);
    }

    String(const String&) = delete;
    String& operator=(const String&) = delete;

    String(String&& other) noexcept
        : memory_(other.memory_),
          representation_(other.representation_) {
      other.setInlineSize(0);
    }

    String& operator=(String&& other) {
      if (this == &other) {
        return *this;
      }

      // Inline bytes, or storage from the same allocator, move as they are.
      if (memory_ == other.memory_ || !other.onHeap()) {
        release();
        representation_ = other.representation_;
        other.setInlineSize(0);
        return *this;
      }

      // Storage goes back to the allocator it came from, so the bytes are copied between two.
      clear();
      append(other.view());
      other.release();
      other.setInlineSize(0);
      return *this;
    }

    ~String() {
      release();
    }

    // The copy lives in the allocator's region, as its storage does, and borrows nothing else of this
    // String.
    [[nodiscard]] tbc::view<String, tbc::lt::a> clone() const {
      String copy{*memory_};

      copy.append(view());
      return copy;
    }

    [[nodiscard]] std::size_t size() const noexcept {
      return onHeap() ? representation_.heap.size : inline_capacity - tag();
    }

    // The allocator its storage comes from, which a String built beside it shares.
    [[nodiscard]] tbc::view<Memory&, tbc::lt::a> memory() const noexcept {
      return *memory_;
    }

    // The bytes it holds without reallocating, besides the NUL.
    [[nodiscard]] std::size_t capacity() const noexcept {
      return onHeap() ? representation_.heap.capacity & ~heap_flag : inline_capacity;
    }

    [[nodiscard]] bool empty() const noexcept {
      return size() == 0;
    }

    // The bytes, followed by a NUL.
    [[nodiscard]] const char* data() const noexcept {
      return onHeap() ? representation_.heap.data : representation_.bytes;
    }

    [[nodiscard]] std::string_view view() const noexcept {
      if (onHeap()) {
        return {representation_.heap.data, representation_.heap.size};
      }

      return {representation_.bytes, inline_capacity - tag()};
    }

    // The bytes to edit in place, as a span over `size()` of them; the NUL after them stays.
    [[nodiscard]] std::span<char> viewMut() noexcept {
      return {dataMut(), size()};
    }

    // As std::string converts, so that a String passes where text is read.
    [[nodiscard]] operator std::string_view() const noexcept {
      return view();
    }

    // Makes room for at least `count` bytes without reallocating until the size passes it.
    void reserve(std::size_t count) {
      if (count > capacity()) {
        reallocate(roundedCapacity(count), {});
      }
    }

    // Returns the storage past its bytes to the allocator, back inline when they fit there.
    void shrinkToFit() {
      if (!onHeap() || capacity() == roundedCapacity(size())) {
        return;
      }

      const auto size = this->size();
      if (size <= inline_capacity) {
        Representation shorter;
        auto* bytes = shorter.bytes;

        copyShort(bytes, representation_.heap.data, size);
        release();
        representation_ = shorter;
        setInlineSize(size);
        return;
      }

      reallocate(roundedCapacity(size), {});
    }

    // Copies the text to the end. Text read from this String stays valid while it is copied, as the
    // old storage is released last.
    void append(std::string_view text) {
      const auto count = text.size();
      if (count == 0) {
        return;
      }

      if (onHeap()) {
        auto& heap = representation_.heap;

        if (count <= (heap.capacity & ~heap_flag) - heap.size) [[likely]] {
          std::memcpy(heap.data + heap.size, text.data(), count);
          heap.size += count;
          heap.data[heap.size] = '\0';
          return;
        }
      } else if (const auto size = inline_capacity - tag(); count <= inline_capacity - size) [[likely]] {
        copyShort(representation_.bytes + size, text.data(), count);
        setInlineSize(size + count);
        return;
      }

      reallocate(grownCapacity(count), text);
    }

    void push(char character) {
      if (onHeap()) {
        auto& heap = representation_.heap;

        if (heap.size < (heap.capacity & ~heap_flag)) [[likely]] {
          heap.data[heap.size] = character;
          ++heap.size;
          heap.data[heap.size] = '\0';
          return;
        }
      } else if (const auto size = inline_capacity - tag(); size < inline_capacity) [[likely]] {
        representation_.bytes[size] = character;
        setInlineSize(size + 1);
        return;
      }

      reallocate(grownCapacity(1), {&character, 1});
    }

    // Empties it and keeps its storage.
    void clear() noexcept {
      setSize(0);
    }

    // The bytes to write in place, `size()` of them followed by the NUL, which stays.
    [[nodiscard]] char* dataMut() noexcept {
      return onHeap() ? representation_.heap.data : representation_.bytes;
    }

    [[nodiscard]] char operator[](std::size_t index) const noexcept {
      TELAR_ASSERT(index < size());
      return data()[index];
    }

    [[nodiscard]] char& atMut(std::size_t index) noexcept {
      TELAR_ASSERT(index < size());
      return dataMut()[index];
    }

    // Shortens it to `count` bytes and keeps its storage; a longer count leaves it as it is.
    void truncate(std::size_t count) noexcept {
      if (count < size()) {
        setSize(count);
      }
    }

    // `count` bytes: the first ones kept, any new ones `fill`.
    void resize(std::size_t count, char fill = '\0') {
      const auto size = this->size();
      if (count <= size) {
        setSize(count);
        return;
      }

      reserve(count);
      std::memset(dataMut() + size, fill, count - size);
      setSize(count);
    }

    // `count` bytes, any new ones left for the caller to write before it reads them, as
    // std::string::resize_and_overwrite does: a buffer a read fills whole is not cleared first.
    void resizeForOverwrite(std::size_t count) {
      reserve(count);
      setSize(count);
    }

    // The last byte, removed; none when it is empty.
    [[nodiscard]] Option<char> pop() noexcept {
      const auto size = this->size();
      if (size == 0) {
        return none;
      }

      const char last = data()[size - 1];

      setSize(size - 1);
      return last;
    }

    // Its bytes become the text's, which may be a part of this String.
    void assign(std::string_view text) {
      replace(0, size(), text);
    }

    void insert(std::size_t index, std::string_view text) {
      replace(index, 0, text);
    }

    // Removes `count` bytes from `index`, or up to the end when fewer follow, as std::string::erase.
    void remove(std::size_t index, std::size_t count = std::string_view::npos) noexcept {
      TELAR_ASSERT(index <= size());
      count = std::min(count, size() - index);

      auto* bytes = dataMut();
      const auto size = this->size();

      std::memmove(bytes + index, bytes + index + count, size - index - count);
      setSize(size - count);
    }

    // The `count` bytes from `index`, or those up to the end, become the text, which may be a part of
    // this String: it is read before any byte it lies in is written.
    void replace(std::size_t index, std::size_t count, std::string_view text) {
      const auto size = this->size();

      TELAR_ASSERT(index <= size);
      count = std::min(count, size - index);
      if (text.size() > maximum_capacity - (size - count)) {
        throw std::bad_array_new_length{};
      }

      const auto result = size - count + text.size();
      const auto* own = data();
      const bool aliases = text.data() >= own && text.data() <= own + capacity();
      if (result > capacity() || aliases) {
        // New storage, so the text and the old bytes stay intact while they are copied.
        const auto capacity = roundedCapacity(std::max(result, size));
        auto* storage = static_cast<char*>(allocateBytes(*memory_, capacity + 1, 1));

        std::memcpy(storage, own, index);
        std::memcpy(storage + index, text.data(), text.size());
        std::memcpy(storage + index + text.size(), own + index + count, size - index - count);
        storage[result] = '\0';
        release();
        representation_.heap = {
            .data = tbc::raw(storage),
            .size = result,
            .capacity = capacity | heap_flag,
        };

        return;
      }

      auto* bytes = dataMut();

      std::memmove(bytes + index + text.size(), bytes + index + count, size - index - count);
      std::memcpy(bytes + index, text.data(), text.size());
      setSize(result);
    }

    friend bool operator==(const String& left, const String& right) noexcept {
      return left.view() == right.view();
    }

    friend bool operator==(const String& left, std::string_view right) noexcept {
      return left.view() == right;
    }

    friend std::strong_ordering operator<=>(const String& left, const String& right) noexcept {
      return left.view() <=> right.view();
    }

    friend std::strong_ordering operator<=>(const String& left, std::string_view right) noexcept {
      return left.view() <=> right;
    }

  private:
    // Heap storage. Its capacity's top bit marks it, and is the top bit of the inline bytes' last one,
    // which holds how many inline bytes are free: 0 when all 23 are used, so it is their NUL too.
    struct Heap {
      char* data;
      std::size_t size;
      std::size_t capacity;
    };

    union Representation {
      Heap heap;
      char bytes[sizeof(Heap)];
    };

    static_assert(std::endian::native == std::endian::little, "the capacity's top byte is the last inline byte");

    static constexpr std::size_t inline_capacity = sizeof(Heap) - 1;
    static constexpr std::size_t heap_flag = std::size_t{1} << (std::numeric_limits<std::size_t>::digits - 1);

    // Leaves the top bits of a capacity free for the flag, and its rounding from overflowing.
    static constexpr std::size_t maximum_capacity = heap_flag / 4;

    [[nodiscard]] std::size_t tag() const noexcept {
      return static_cast<unsigned char>(representation_.bytes[inline_capacity]);
    }

    [[nodiscard]] bool onHeap() const noexcept {
      return (tag() & 0x80) != 0;
    }

    void setInlineSize(std::size_t size) noexcept {
      representation_.bytes[size] = '\0';
      representation_.bytes[inline_capacity] = static_cast<char>(inline_capacity - size);
    }

    // Sets the size within the current storage, followed by its NUL.
    void setSize(std::size_t size) noexcept {
      if (onHeap()) {
        representation_.heap.size = size;
        representation_.heap.data[size] = '\0';
      } else {
        setInlineSize(size);
      }
    }

    // A capacity of at least `count` bytes whose NUL ends a whole 16-byte block, as the allocator
    // hands them out.
    [[nodiscard]] static std::size_t roundedCapacity(std::size_t count) {
      if (count > maximum_capacity) {
        throw std::bad_array_new_length{};
      }

      return ((count + 16) & ~std::size_t{15}) - 1;
    }

    // Room for `added` more bytes, doubling, so that n appends copy each byte a constant number of
    // times on average.
    [[nodiscard]] std::size_t grownCapacity(std::size_t added) const {
      const auto size = this->size();
      if (added > maximum_capacity - size) {
        throw std::bad_array_new_length{};
      }

      return roundedCapacity(std::max(size + added, 2 * capacity()));
    }

    // Moves the bytes, followed by `text`, to storage for `capacity` bytes.
    void reallocate(std::size_t capacity, std::string_view text) {
      auto* storage = static_cast<char*>(allocateBytes(*memory_, capacity + 1, 1));
      const auto current = view();
      const auto size = current.size() + text.size();

      std::memcpy(storage, current.data(), current.size());
      if (!text.empty()) {
        std::memcpy(storage + current.size(), text.data(), text.size());
      }

      storage[size] = '\0';
      release();
      representation_.heap = {
          .data = tbc::raw(storage),
          .size = size,
          .capacity = capacity | heap_flag,
      };
    }

    // Returns heap storage to the allocator, and leaves the representation for the caller to set.
    void release() noexcept {
      if (onHeap()) {
        memory_->deallocate(representation_.heap.data, (representation_.heap.capacity & ~heap_flag) + 1, 1);
      }
    }

    tbc::view<Memory*, tbc::lt::a> memory_;
    Representation representation_;
  };

  // An output iterator that appends to a String, so that std::format_to writes into one in a single
  // pass, growing it as std::back_inserter grows a std::string.
  template <Allocator Memory>
  class StringAppender {
  public:
    using difference_type = std::ptrdiff_t;

    explicit StringAppender(String<Memory>& text) noexcept
        : text_(&text) {}

    StringAppender& operator=(char character) {
      text_->push(character);
      return *this;
    }

    StringAppender& operator*() noexcept {
      return *this;
    }

    StringAppender& operator++() noexcept {
      return *this;
    }

    StringAppender operator++(int) noexcept {
      return *this;
    }

  private:
    String<Memory>* text_;
  };

  // Appends the formatted arguments to `text`, as std::format_to through a back inserter.
  template <Allocator Memory, typename... Arguments>
  void formatTo(String<Memory>& text, std::format_string<Arguments...> format, Arguments&&... arguments) {
    std::format_to(StringAppender<Memory>{text}, format, std::forward<Arguments>(arguments)...);
  }

  // The formatted arguments in a String from `memory`, as std::format returns a std::string.
  template <Allocator Memory, typename... Arguments>
  [[nodiscard]] tbc::view<String<Memory>, tbc::lt::a> format(tbc::view<Memory&, tbc::lt::a> memory, std::format_string<Arguments...> format, Arguments&&... arguments) {
    String<Memory> text{memory};

    formatTo(text, format, std::forward<Arguments>(arguments)...);
    return text;
  }

  // A hash for Map keys: integers, enumerations, pointers and text, mixed so that the low bits a
  // table indexes by depend on every bit of the key, and seeded per process. Text hashes as wyhash
  // does: overlapping words for short text, three lanes of 16 bytes for long.
  struct TBC_HOT_PATH Hash {
    template <typename Key>
      requires(std::is_integral_v<Key> || std::is_enum_v<Key> || std::is_pointer_v<Key>)
    [[nodiscard]] std::uint64_t operator()(Key key) const noexcept {
      std::uint64_t bits{};

      if constexpr (std::is_pointer_v<Key>) {
        bits = reinterpret_cast<std::uintptr_t>(key);
      } else {
        bits = static_cast<std::uint64_t>(key);
      }

      return mix(bits ^ hashSeed(), hash_secrets[1]);
    }

    [[nodiscard]] inline std::uint64_t operator()(std::string_view text) const noexcept {
      const auto* bytes = text.data();
      const auto count = text.size();
      auto seed = hashSeed();
      std::uint64_t first = 0;
      std::uint64_t second = 0;

      if (count <= 16) [[likely]] {
        if (count >= 4) {
          const auto quarter = (count >> 3) << 2;

          first = (read32(bytes) << 32) | read32(bytes + quarter);
          second = (read32(bytes + count - 4) << 32) | read32(bytes + count - 4 - quarter);
        } else if (count > 0) {
          first = (std::uint64_t{static_cast<unsigned char>(bytes[0])} << 16) | (std::uint64_t{static_cast<unsigned char>(bytes[count >> 1])} << 8) | static_cast<unsigned char>(bytes[count - 1]);
        }
      } else {
        auto remaining = count;

        if (remaining > 48) {
          auto lane1 = seed;
          auto lane2 = seed;

          do {
            seed = mix(read64(bytes) ^ hash_secrets[1], read64(bytes + 8) ^ seed);
            lane1 = mix(read64(bytes + 16) ^ hash_secrets[2], read64(bytes + 24) ^ lane1);
            lane2 = mix(read64(bytes + 32) ^ hash_secrets[3], read64(bytes + 40) ^ lane2);
            bytes += 48;
            remaining -= 48;
          } while (remaining > 48);

          seed ^= lane1 ^ lane2;
        }

        while (remaining > 16) {
          seed = mix(read64(bytes) ^ hash_secrets[1], read64(bytes + 8) ^ seed);
          bytes += 16;
          remaining -= 16;
        }

        first = read64(bytes + remaining - 16);
        second = read64(bytes + remaining - 8);
      }

      return mix(hash_secrets[1] ^ count, mix(first ^ hash_secrets[1], second ^ seed));
    }
  };

  // A hash map in memory from an allocator, as Rust's `HashMap`: a Swiss table, whose open
  // addressing keeps a byte of each key's hash apart, so that a lookup compares eight of them at a
  // time and reads a key only where its byte matches. Values relocate without throwing, as Rust moves
  // them, and as bytes where they can. Copying allocates, so it is explicit (`clone`).
  template <typename Key, typename Value, Allocator Memory, typename Hasher = Hash>
    requires(std::is_nothrow_move_constructible_v<Key> && std::is_nothrow_move_constructible_v<Value> && std::is_nothrow_invocable_r_v<std::uint64_t, Hasher, KeyLookup<Key>>)
  class TBC_GENERIC Map {
    using Lookup = KeyLookup<Key>;

  public:
    // Its storage, or the shared empty group, lies outside it.
    using trivially_relocatable = Map;

    struct Entry {
      using trivially_relocatable = std::conditional_t<relocatable<Key> && relocatable<Value>, Entry, void>;

      Key key;
      Value value;
    };

    // Visits the entries in no particular order. What it reads borrows the Map, not the iterator, as
    // Rust's `Iter<'a>` yields `&'a` items.
    class Iterator {
    public:
      [[nodiscard]] tbc::view<const Entry&, tbc::lt::a> operator*() const noexcept {
        return *entry_;
      }

      [[nodiscard]] tbc::view<const Entry*, tbc::lt::a> operator->() const noexcept {
        return entry_;
      }

      Iterator& operator++() noexcept {
        ++control_;
        ++entry_;
        skip();
        return *this;
      }

      friend bool operator==(const Iterator& left, const Iterator& right) noexcept {
        return left.control_ == right.control_;
      }

    private:
      friend class Map;

      Iterator(tbc::view<const std::int8_t*, tbc::lt::a> control, tbc::view<const Entry*, tbc::lt::a> entry) noexcept
          : control_(control),
            entry_(entry) {
        skip();
      }

      // Stops at a full slot or at the sentinel past the last one.
      void skip() noexcept {
        while (*control_ < Group::sentinel) {
          const auto shift = Group::leadingEmptyOrRemoved(Group::load(control_));

          control_ += shift;
          entry_ += shift;
        }
      }

      tbc::view<const std::int8_t*, tbc::lt::a> control_;
      tbc::view<const Entry*, tbc::lt::a> entry_;
    };

    explicit Map(tbc::view<Memory&, tbc::lt::a> memory) noexcept
        : memory_(&memory) {}

    Map(const Map&) = delete;
    Map& operator=(const Map&) = delete;

    Map(Map&& other) noexcept
        : memory_(other.memory_),
          control_(std::exchange(other.control_, emptyControl())),
          entries_(std::exchange(other.entries_, nullptr)),
          mask_(std::exchange(other.mask_, 0)),
          size_(std::exchange(other.size_, 0)),
          growth_left_(std::exchange(other.growth_left_, 0)) {}

    Map& operator=(Map&& other) {
      if (this == &other) {
        return *this;
      }

      if (memory_ == other.memory_) {
        release();
        control_ = std::exchange(other.control_, emptyControl());
        entries_ = std::exchange(other.entries_, nullptr);
        mask_ = std::exchange(other.mask_, 0);
        size_ = std::exchange(other.size_, 0);
        growth_left_ = std::exchange(other.growth_left_, 0);
        return *this;
      }

      // Storage goes back to the allocator it came from, so entries move between allocators one by
      // one.
      clear();
      reserve(other.size_);
      for (std::size_t index = 0; index < other.mask_; ++index) {
        if (other.control_[index] >= 0) {
          auto& entry = other.entries_[index];

          add(hashOf(entry.key), std::move(entry.key), std::move(entry.value));
        }
      }

      other.release();
      return *this;
    }

    ~Map() {
      release();
    }

    // The copy lives in the allocator's region, as its storage does, and borrows nothing else of this
    // Map.
    [[nodiscard]] tbc::view<Map, tbc::lt::a> clone() const
      requires(std::is_copy_constructible_v<Key> && std::is_copy_constructible_v<Value>)
    {
      Map copy{*memory_};

      if (mask_ == 0) {
        return copy;
      }

      // The copy keeps each slot where it is, removed ones too, so no key is hashed again.
      auto* block = static_cast<std::byte*>(allocateBytes(*memory_, blockBytes(mask_), block_alignment));
      auto* control = reinterpret_cast<std::int8_t*>(block);
      auto* entries = reinterpret_cast<Entry*>(block + entriesOffset(mask_));

      resetControl(control, mask_);
      copy.control_ = tbc::raw(control);
      copy.entries_ = tbc::raw(entries);
      copy.mask_ = mask_;

      // A slot counts once its entry is constructed, so where a copy throws, the copy's destructor
      // destroys the ones before it.
      for (std::size_t index = 0; index < mask_; ++index) {
        if (control_[index] >= 0) {
          std::construct_at(entries + index, entries_[index]);
          ++copy.size_;
        }

        if (control_[index] != Group::empty) {
          setControl(control, mask_, index, control_[index]);
        }
      }

      copy.growth_left_ = growth_left_;
      return copy;
    }

    [[nodiscard]] std::size_t size() const noexcept {
      return size_;
    }

    [[nodiscard]] bool empty() const noexcept {
      return size_ == 0;
    }

    // The slots it has, of which it fills at most seven in eight before it grows.
    [[nodiscard]] std::size_t capacity() const noexcept {
      return mask_;
    }

    [[nodiscard]] const Value* find(Lookup key) const {
      const auto index = locate(key, hashOf(key));

      return index == not_found ? nullptr : &entries_[index].value;
    }

    [[nodiscard]] Value* findMut(Lookup key) {
      const auto index = locate(key, hashOf(key));

      return index == not_found ? nullptr : &entries_[index].value;
    }

    [[nodiscard]] bool contains(Lookup key) const {
      return locate(key, hashOf(key)) != not_found;
    }

    // Adds the entry unless the key is there, and says whether it added it. It takes the key and the
    // value themselves, as Rust's `insert` does, so ones read from this Map are copied before the
    // call can move its storage.
    bool insert(Key key, Value value) {
      const auto hash = hashOf(key);
      if (locate(key, hash) != not_found) {
        return false;
      }

      add(hash, std::move(key), std::move(value));
      return true;
    }

    // Adds the entry, or replaces the value of the key's, and says whether it added it.
    bool assign(Key key, Value value) {
      const auto hash = hashOf(key);
      if (const auto index = locate(key, hash); index != not_found) {
        entries_[index].value = std::move(value);
        return false;
      }

      add(hash, std::move(key), std::move(value));
      return true;
    }

    // Removes the key's entry and hands its value back, as Rust's `remove`: it leaves with what it
    // borrows, region `a`, and none of this Map's storage.
    tbc::view<Option<Value>, tbc::lt::a> remove(Lookup key) {
      const auto index = locate(key, hashOf(key));
      if (index == not_found) {
        return {};
      }

      Option<Value> removed{std::move(entries_[index].value)};

      erase(index);
      return removed;
    }

    // Keeps the entries `keep` accepts and drops the others, as Rust's `retain`. `keep` sees each key
    // shared and its value mutable, and must not reach this Map. Returns how many it dropped.
    template <typename Predicate>
    std::size_t retain(Predicate keep) {
      std::size_t dropped = 0;

      for (std::size_t index = 0; index < mask_; ++index) {
        if (control_[index] >= 0 && !keep(std::as_const(entries_[index].key), entries_[index].value)) {
          erase(index);
          ++dropped;
        }
      }

      return dropped;
    }

    // Destroys the entries and keeps the storage.
    void clear() noexcept {
      if (mask_ == 0) {
        return;
      }

      destroyEntries();
      resetControl(control_, mask_);
      size_ = 0;
      growth_left_ = growthOf(mask_);
    }

    // Makes room for at least `count` entries without moving them again until the size passes it.
    void reserve(std::size_t count) {
      if (count <= size_ + growth_left_) {
        return;
      }

      // No table that large can be allocated; failing here keeps the doubling below from relying on
      // growthOf wrapping at the largest capacity to stop.
      if (count > std::numeric_limits<std::size_t>::max() / 2) {
        throw std::bad_array_new_length{};
      }

      auto capacity = Group::width - 1;

      while (growthOf(capacity) < count) {
        capacity = capacity * 2 + 1;
      }

      rehash(capacity);
    }

    [[nodiscard]] Iterator begin() const noexcept {
      return Iterator{control_, entries_};
    }

    [[nodiscard]] Iterator end() const noexcept {
      return Iterator{control_ + mask_, entries_ + mask_};
    }

  private:
    static constexpr std::size_t not_found = std::numeric_limits<std::size_t>::max();
    static constexpr std::size_t block_alignment = std::max(alignof(Entry), alignof(std::uint64_t));

    [[nodiscard]] static std::uint64_t hashOf(Lookup key) noexcept {
      return Hasher{}(key);
    }

    // Destroys the entry in a full slot.
    void erase(std::size_t index) noexcept {
      std::destroy_at(entries_ + index);
      --size_;

      // A slot no probe ever passed full can be empty again; any other stays removed, so that probes
      // for the keys past it go on.
      const auto before = Group::matchEmpty(Group::load(control_ + ((index - Group::width) & mask_)));
      const auto after = Group::matchEmpty(Group::load(control_ + index));

      if (mask_ < Group::width || (before != 0 && after != 0 && Group::lastFromEnd(before) + Group::first(after) < Group::width)) {
        setControl(control_, mask_, index, Group::empty);
        ++growth_left_;
      } else {
        setControl(control_, mask_, index, Group::removed);
      }
    }

    // The byte a full slot keeps of its key's hash; the rest of the hash picks where probes start.
    [[nodiscard]] static std::uint8_t tagOf(std::uint64_t hash) noexcept {
      return static_cast<std::uint8_t>(hash & 0x7f);
    }

    [[nodiscard]] static std::int8_t* emptyControl() noexcept {
      return tbc::raw(const_cast<std::int8_t*>(empty_group.data()));
    }

    // Fills seven slots in eight, and always leaves one empty, where every probe ends.
    [[nodiscard]] static std::size_t growthOf(std::size_t capacity) noexcept {
      return capacity - (capacity + 1) / 8;
    }

    // The control bytes are the slots', the sentinel's, and copies of the first slots' after it, so
    // that a group read near the end wraps around to the beginning.
    [[nodiscard]] static std::size_t controlBytes(std::size_t capacity) noexcept {
      return capacity + Group::width;
    }

    [[nodiscard]] static std::size_t entriesOffset(std::size_t capacity) noexcept {
      return (controlBytes(capacity) + alignof(Entry) - 1) & ~(alignof(Entry) - 1);
    }

    [[nodiscard]] static std::size_t blockBytes(std::size_t capacity) {
      if (capacity > (std::numeric_limits<std::size_t>::max() - entriesOffset(capacity)) / sizeof(Entry)) {
        throw std::bad_array_new_length{};
      }

      return entriesOffset(capacity) + capacity * sizeof(Entry);
    }

    static void setControl(std::int8_t* control, std::size_t mask, std::size_t index, std::int8_t byte) noexcept {
      control[index] = byte;
      control[((index - (Group::width - 1)) & mask) + (Group::width - 1)] = byte;
    }

    static void resetControl(std::int8_t* control, std::size_t capacity) noexcept {
      std::memset(control, Group::empty, controlBytes(capacity));
      control[capacity] = Group::sentinel;
    }

    // Probes a group at a time, at triangular strides, which visit every group of a power of two.
    [[nodiscard]] std::size_t locate(Lookup key, std::uint64_t hash) const {
      const auto tag = tagOf(hash);
      auto offset = (hash >> 7) & mask_;
      std::size_t stride = 0;

      while (true) {
        const auto word = Group::load(control_ + offset);

        for (auto matches = Group::match(word, tag); matches != 0; matches &= matches - 1) {
          const auto index = (offset + Group::first(matches)) & mask_;
          if (entries_[index].key == key) [[likely]] {
            return index;
          }
        }

        if (Group::matchEmpty(word) != 0) [[likely]] {
          return not_found;
        }

        stride += Group::width;
        offset = (offset + stride) & mask_;
      }
    }

    [[nodiscard]] static std::size_t firstFree(const std::int8_t* control, std::size_t mask, std::uint64_t hash) noexcept {
      auto offset = (hash >> 7) & mask;
      std::size_t stride = 0;

      while (true) {
        if (const auto free = Group::matchEmptyOrRemoved(Group::load(control + offset)); free != 0) [[likely]] {
          return (offset + Group::first(free)) & mask;
        }

        stride += Group::width;
        offset = (offset + stride) & mask;
      }
    }

    // Adds a key this Map does not hold.
    void add(std::uint64_t hash, Key&& key, Value&& value) {
      if (growth_left_ == 0) [[unlikely]] {
        grow();
      }

      const auto index = firstFree(control_, mask_, hash);
      if (control_[index] == Group::empty) {
        --growth_left_;
      }

      setControl(control_, mask_, index, static_cast<std::int8_t>(tagOf(hash)));
      std::construct_at(entries_ + index, std::move(key), std::move(value));
      ++size_;
    }

    // Doubles the slots, or, where removed slots took the room, rehashes into as many.
    void grow() {
      if (mask_ != 0 && size_ * 32 <= mask_ * 25) {
        rehash(mask_);
      } else {
        rehash(mask_ == 0 ? Group::width - 1 : mask_ * 2 + 1);
      }
    }

    // Moves the entries to new storage of `capacity` slots, a power of two less one.
    void rehash(std::size_t capacity) {
      auto* block = static_cast<std::byte*>(allocateBytes(*memory_, blockBytes(capacity), block_alignment));
      auto* control = reinterpret_cast<std::int8_t*>(block);
      auto* entries = reinterpret_cast<Entry*>(block + entriesOffset(capacity));

      resetControl(control, capacity);
      for (std::size_t index = 0; index < mask_; ++index) {
        if (control_[index] < 0) {
          continue;
        }

        const auto hash = hashOf(entries_[index].key);
        const auto target = firstFree(control, capacity, hash);

        setControl(control, capacity, target, static_cast<std::int8_t>(tagOf(hash)));
        relocate(entries + target, entries_ + index);
      }

      deallocate();
      control_ = tbc::raw(control);
      entries_ = tbc::raw(entries);
      mask_ = capacity;
      growth_left_ = growthOf(capacity) - size_;
    }

    static void relocate(Entry* target, Entry* source) noexcept {
      if constexpr (relocatable<Entry>) {
        std::memcpy(static_cast<void*>(target), static_cast<const void*>(source), sizeof(Entry));
      } else {
        std::construct_at(target, std::move(*source));
        std::destroy_at(source);
      }
    }

    void destroyEntries() noexcept {
      if constexpr (!std::is_trivially_destructible_v<Entry>) {
        for (std::size_t index = 0; index < mask_; ++index) {
          if (control_[index] >= 0) {
            std::destroy_at(entries_ + index);
          }
        }
      }
    }

    void deallocate() noexcept {
      if (mask_ != 0) {
        memory_->deallocate(control_, blockBytes(mask_), block_alignment);
      }
    }

    void release() noexcept {
      destroyEntries();
      deallocate();
      control_ = emptyControl();
      entries_ = nullptr;
      mask_ = 0;
      size_ = 0;
      growth_left_ = 0;
    }

    tbc::view<Memory*, tbc::lt::a> memory_;
    std::int8_t* control_ = emptyControl();
    // The entries live in storage from the allocator, region `a`, as a Vec's values do.
    tbc::view<Entry*, tbc::lt::a> entries_ = nullptr;
    std::size_t mask_ = 0;
    std::size_t size_ = 0;
    std::size_t growth_left_ = 0;
  };

  template <typename Signature, std::size_t Capacity = 3 * sizeof(void*)>
  class Function;

  // A callable of any type behind one signature, as std::move_only_function and Rust's
  // `Box<dyn FnMut>`, stored inline so that it never allocates: a callable larger than Capacity
  // bytes, aligned past a pointer, or whose move can throw does not convert. A call may mutate the
  // callable, as an `FnMut`'s does, so it is not const. Calling an empty Function traps.
  template <typename Result, typename... Arguments, std::size_t Capacity>
  class TBC_GENERIC Function<Result(Arguments...), Capacity> {
    // Scalars pass to the callable by value, in registers, and the rest by reference, as libc++'s
    // std::function passes them.
    template <typename Argument>
    using Pass = std::conditional_t<std::is_scalar_v<Argument>, Argument, Argument&&>;

    using Invoke = Result (*)(void*, Pass<Arguments>...);

    // Moves the callable at `source` to `target` and destroys it, or only destroys it when `target`
    // is null.
    using Manage = void (*)(void* target, void* source) noexcept;

  public:
    Function() noexcept = default;

    template <typename Callable>
      requires(!std::same_as<Callable, Function> && std::is_invocable_r_v<Result, Callable&, Arguments...> && sizeof(Callable) <= Capacity && alignof(Callable) <= alignof(void*) && std::is_nothrow_move_constructible_v<Callable>)
    Function(Callable callable) noexcept
        : invoke_(&call<Callable>),
          manage_(std::is_trivially_copyable_v<Callable> ? nullptr : &manage<Callable>) {
      std::construct_at(reinterpret_cast<Callable*>(storage_), std::move(callable));
    }

    Function(const Function&) = delete;
    Function& operator=(const Function&) = delete;

    Function(Function&& other) noexcept
        : invoke_(std::exchange(other.invoke_, &callEmpty)),
          manage_(std::exchange(other.manage_, nullptr)) {
      take(other);
    }

    Function& operator=(Function&& other) noexcept {
      if (this == &other) {
        return *this;
      }

      destroy();
      invoke_ = std::exchange(other.invoke_, &callEmpty);
      manage_ = std::exchange(other.manage_, nullptr);
      take(other);
      return *this;
    }

    ~Function() {
      destroy();
    }

    explicit operator bool() const noexcept {
      return invoke_ != &callEmpty;
    }

    // The arguments are lent to this call alone, region `b` of no field, as Rust's `for<'b> FnMut(&'b T)`
    // takes them: the callable cannot keep them.
    Result operator()(tbc::view<Arguments, tbc::lt::b>... arguments) {
      return invoke_(storage_, std::forward<Arguments>(arguments)...);
    }

  private:
    template <typename Callable>
    static Result call(void* storage, Pass<Arguments>... arguments) {
      return std::invoke_r<Result>(*static_cast<Callable*>(storage), std::forward<Arguments>(arguments)...);
    }

    [[noreturn]] static Result callEmpty(void*, Pass<Arguments>...) noexcept {
      __builtin_verbose_trap("telar::ds::Function", "called while empty");
    }

    template <typename Callable>
    static void manage(void* target, void* source) noexcept {
      auto* callable = static_cast<Callable*>(source);

      if (target != nullptr) {
        std::construct_at(static_cast<Callable*>(target), std::move(*callable));
      }

      std::destroy_at(callable);
    }

    // Takes the callable of `other`, whose manager this Function already holds. A trivially copyable
    // one moves as its bytes.
    void take(Function& other) noexcept {
      if (manage_ == nullptr) {
        std::memcpy(storage_, other.storage_, Capacity);
      } else {
        manage_(storage_, other.storage_);
      }
    }

    void destroy() noexcept {
      if (manage_ != nullptr) {
        manage_(nullptr, storage_);
      }
    }

    alignas(void*) std::byte storage_[Capacity];
    Invoke invoke_ = &callEmpty;
    Manage manage_ = nullptr;
  };

}

// A String formats as its text does.
template <telar::Allocator Memory>
struct std::formatter<telar::ds::String<Memory>, char> : std::formatter<std::string_view, char> {
  template <typename Context>
  auto format(const telar::ds::String<Memory>& text, Context& context) const {
    return std::formatter<std::string_view, char>::format(text.view(), context);
  }
};
