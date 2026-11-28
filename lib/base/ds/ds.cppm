module;
#include "telar_base/diagnostics/config.hpp"

export module telar.base.ds;

import std;
import telar.tbc;
import telar.base.ds.values;
import telar.base.memory.allocators;

export namespace telar::ds {
  using telar::ds::Array;
  using telar::ds::Cell;
  using telar::ds::get;
  using telar::ds::is_option;
  using telar::ds::None;
  using telar::ds::none;
  using telar::ds::Option;
  using telar::ds::relocatable;
  using telar::ds::toArray;
  using telar::ds::operator==;
  using telar::ds::operator<=>;
}

export {
  // The containers of telar::ds that take their memory from an allocator; see telar_base/ds/values.hpp.
  namespace telar::ds {

    // Allocates bytes for a container, which throws where the allocator fails, as Rust's allocation
    // failure aborts rather than returning null.
    template <Allocator Memory>
    [[tbc::generic]] void* allocateBytes(Memory& memory, std::size_t size, std::size_t alignment) {
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
    class [[tbc::owner]] [[tbc::generic]] Box {
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

        return std::shared_ptr<Value>{
            std::exchange(value_, nullptr),
            [memory](Value* value) noexcept {
              fromRaw(value, *memory).reset();
            },
        };
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
    [[tbc::constructs]] [[tbc::generic]] Box<Value, Memory> makeBox(Memory& memory, Arguments&&... arguments) {
      auto* value = static_cast<Value*>(allocateBytes(memory, sizeof(Value), alignof(Value)));

      try {
        std::construct_at(value, std::forward<Arguments>(arguments)...);
      } catch (...) {
        memory.deallocate(value, sizeof(Value), alignof(Value));
        throw;
      }

      return Box<Value, Memory>{value, memory};
    }

    // The `count` values at `storage` as a span. The containers below keep their storage as a pointer
    // and count how many values it holds, so this is where their bounds meet the pointer.
    template <typename Value>
    [[tbc::hot_path]] inline std::span<Value> spanOver(Value* storage, std::size_t count) noexcept {
      // Every caller passes the count of values its storage holds.
#pragma clang unsafe_buffer_usage begin
      return {storage, count};
#pragma clang unsafe_buffer_usage end
    }

    // The high and low halves of a 128-bit product folded together: every bit of either factor
    // reaches every bit of the result, as wyhash and rapidhash mix.
    [[tbc::hot_path]] inline std::uint64_t mix(std::uint64_t left, std::uint64_t right) noexcept {
      constexpr std::size_t half_bits = 64;
      const auto product = static_cast<unsigned __int128>(left) * right;

      return static_cast<std::uint64_t>(product) ^ static_cast<std::uint64_t>(product >> half_bits);
    }

    // The word the first bytes of `bytes` hold, in the machine's order; a constant-size copy, which
    // compiles to one load.
    template <std::unsigned_integral Word, typename Byte>
    [[tbc::hot_path]] inline Word readWord(std::span<const Byte> bytes) noexcept {
      Word word = 0;

      std::ranges::copy(std::as_bytes(bytes.first(sizeof(Word))), std::as_writable_bytes(std::span{&word, 1}).begin());
      return word;
    }

    template <std::unsigned_integral Word>
    [[tbc::hot_path]] inline void writeWord(std::span<char> target, Word word) noexcept {
      std::ranges::copy(std::as_bytes(std::span{&word, 1}), std::as_writable_bytes(target.first(sizeof(Word))).begin());
    }

    [[tbc::hot_path]] inline std::uint64_t read64(std::span<const char> bytes) noexcept {
      return readWord<std::uint64_t>(bytes);
    }

    [[tbc::hot_path]] inline std::uint64_t read32(std::span<const char> bytes) noexcept {
      return readWord<std::uint32_t>(bytes);
    }

    // Copies up to 23 bytes, as an inline String holds, with overlapping word moves rather than a call
    // to memcpy, which costs more than the copy at these sizes. `target` has room for all of `source`.
    [[tbc::hot_path]] inline void copyShort(std::span<char> target, std::span<const char> source) noexcept {
      constexpr std::size_t long_word = sizeof(std::uint64_t);
      constexpr std::size_t short_word = sizeof(std::uint32_t);
      const auto count = source.size();

      if (count >= long_word) {
        const auto first = readWord<std::uint64_t>(source);
        const auto last = readWord<std::uint64_t>(source.last(long_word));

        if (count > 2 * long_word) {
          writeWord(target.subspan(long_word), readWord<std::uint64_t>(source.subspan(long_word)));
        }

        writeWord(target, first);
        writeWord(target.subspan(count - long_word), last);
      } else if (count >= short_word) {
        const auto first = readWord<std::uint32_t>(source);
        const auto last = readWord<std::uint32_t>(source.last(short_word));

        writeWord(target, first);
        writeWord(target.subspan(count - short_word), last);
      } else if (count > 0) {
        target[0] = source[0];
        target[count >> 1U] = source[count >> 1U];
        target[count - 1] = source[count - 1];
      }
    }

    inline constexpr Array<std::uint64_t, 4> hash_secrets = {
        0x2d358dccaa6c78a5,
        0x8bb84b93962eacc9,
        0x4b33a62ed433d4a3,
        0x4d5a2da51de1aa47,
    };

    // Where this constant lies moves with address space layout randomization, so its address seeds
    // hashes per process and keys cannot be chosen ahead of time to collide.
    inline constexpr char hash_anchor = 0;

    [[tbc::hot_path]] inline std::uint64_t hashSeed() noexcept {
      return hash_secrets[0] ^ std::bit_cast<std::uintptr_t>(&hash_anchor);
    }

    // Eight control bytes of a Map read as one word, as abseil's portable group. A full slot's byte is
    // seven bits of its key's hash; an empty or removed slot's has the top bit set, and so does the
    // sentinel that ends iteration.
    struct [[tbc::hot_path]] Group {
      static_assert(std::endian::native == std::endian::little, "a slot's byte is the word's byte of the same rank");

      static constexpr std::size_t width = 8;
      static constexpr std::int8_t empty = -128;
      static constexpr std::int8_t removed = -2;
      static constexpr std::int8_t sentinel = -1;
      static constexpr std::uint64_t low_bits = 0x0101010101010101;
      static constexpr std::uint64_t high_bits = 0x8080808080808080;

      // The top bit of a slot's byte, and the shift from a bit of the word to its slot's rank.
      static constexpr std::size_t top_bit = 7;
      static constexpr std::size_t rank_shift = 3;

      // The first `width` control bytes of `control`.
      [[nodiscard]] static inline std::uint64_t load(std::span<const std::int8_t> control) noexcept {
        return readWord<std::uint64_t>(control);
      }

      // The slots whose byte is `tag`. A full slot right after one of them may come out too, which
      // comparing its key rules out; an empty or removed slot never does.
      [[nodiscard]] static inline std::uint64_t match(std::uint64_t word, std::uint8_t tag) noexcept {
        const auto difference = word ^ (low_bits * tag);

        return (difference - low_bits) & ~difference & high_bits;
      }

      // Of the bytes with the top bit set, only an empty slot's clears bit 1, which the shift moves to
      // the top.
      [[nodiscard]] static inline std::uint64_t matchEmpty(std::uint64_t word) noexcept {
        return word & ~(word << (top_bit - 1)) & high_bits;
      }

      // Of the bytes with the top bit set, the sentinel's alone sets bit 0.
      [[nodiscard]] static inline std::uint64_t matchEmptyOrRemoved(std::uint64_t word) noexcept {
        return word & ~(word << top_bit) & high_bits;
      }

      // How many slots from the first are empty or removed, up to the group's width.
      [[nodiscard]] static inline std::size_t leadingEmptyOrRemoved(std::uint64_t word) noexcept {
        return static_cast<std::size_t>(std::countr_zero((word | ~(word >> top_bit)) & low_bits) + 1) >> rank_shift;
      }

      // The rank of the first slot a match holds.
      [[nodiscard]] static inline std::size_t first(std::uint64_t matches) noexcept {
        return static_cast<std::size_t>(std::countr_zero(matches)) >> rank_shift;
      }

      // The rank of the last slot a match holds, counted from the group's end.
      [[nodiscard]] static inline std::size_t lastFromEnd(std::uint64_t matches) noexcept {
        return static_cast<std::size_t>(std::countl_zero(matches)) >> rank_shift;
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
    class [[tbc::generic]] Vec {
    public:
      explicit Vec(tbc::mut_a<Memory> memory) noexcept
          : memory_(&memory) {}

      // Copies the values, so the Vec borrows nothing of them. The storage holds exactly them, as Rust's
      // `to_vec` does: a copy is not expected to grow.
      Vec(tbc::mut_a<Memory> memory, std::span<const Value> values)
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

      Vec& operator=(Vec&& other) { // NOLINT(bugprone-exception-escape,cppcoreguidelines-noexcept-move-operations,performance-noexcept-move-constructor): moving between two allocators allocates, as std::vector's move does
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
          std::construct_at(&storageSpan()[index], std::move(other.viewMut()[index]));
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
      [[nodiscard]] tbc::val_a<Vec> clone() const
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
            copy.push(view()[index].clone());
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
        return view()[index];
      }

      [[nodiscard]] Value& atMut(std::size_t index) noexcept {
        TELAR_ASSERT(index < size_);
        return viewMut()[index];
      }

      [[nodiscard]] const Value& front() const noexcept {
        return (*this)[0];
      }

      [[nodiscard]] Value& frontMut() noexcept {
        return atMut(0);
      }

      [[nodiscard]] const Value& back() const noexcept {
        TELAR_ASSERT(size_ != 0);
        return view().back();
      }

      [[nodiscard]] Value& backMut() noexcept {
        TELAR_ASSERT(size_ != 0);
        return viewMut().back();
      }

      [[nodiscard]] const Value* data() const noexcept {
        return items_;
      }

      [[nodiscard]] Value* dataMut() noexcept {
        return items_;
      }

      [[nodiscard]] std::span<const Value> view() const noexcept {
        // The span's constructor is given shared access to the values, as this method has.
        return spanOver(static_cast<const Value*>(items_), size_);
      }

      [[nodiscard]] std::span<Value> viewMut() noexcept {
        return spanOver(items_, size_);
      }

      [[nodiscard]] const Value* begin() const noexcept {
        return items_;
      }

      [[nodiscard]] const Value* end() const noexcept {
        return std::to_address(view().end());
      }

      [[nodiscard]] tbc::mut_a<Memory> memory() const noexcept {
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
          auto* slot = std::construct_at(&storageSpan()[size_], std::forward<Arguments>(arguments)...);

          ++size_;
          return *slot;
        }

        const auto capacity = grownCapacity(size_ + 1);
        auto* storage = allocate(capacity);

        try {
          std::construct_at(&spanOver(storage, capacity)[size_], std::forward<Arguments>(arguments)...);
        } catch (...) {
          deallocate(storage, capacity);
          throw;
        }

        relocate(spanOver(storage, capacity));
        deallocate(items_, capacity_);
        items_ = tbc::raw(storage);
        capacity_ = capacity;
        ++size_;
        return backMut();
      }

      // Removes the last value and hands it back, as Rust's `pop`.
      // The value leaves with what it borrows, region `a`, and none of this Vec's storage, as Rust's `-> T`.
      [[nodiscard]] tbc::val_a<Option<Value>> pop() noexcept(std::is_nothrow_move_constructible_v<Value>) {
        if (size_ == 0) {
          return {};
        }

        --size_;
        // Emplaced, so that the value moves once rather than through Option's by-value constructor.
        Option<Value> last;

        last.emplace(std::move(storageSpan()[size_]));

        std::destroy_at(&storageSpan()[size_]);
        return last;
      }

      // Destroys the values past the first `count`.
      void truncate(std::size_t count) noexcept {
        if (count >= size_) {
          return;
        }

        std::ranges::destroy(viewMut().subspan(count));
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
        std::ranges::uninitialized_value_construct(storageSpan().subspan(size_, count - size_));
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
        std::ranges::uninitialized_fill(storageSpan().subspan(size_, count - size_), value);
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

          std::construct_at(&spanOver(storage, capacity)[index], std::move(value));
          relocate(viewMut().first(index), spanOver(storage, capacity));
          relocate(viewMut().subspan(index), spanOver(storage, capacity).subspan(index + 1));
          deallocate(items_, capacity_);
          items_ = tbc::raw(storage);
          capacity_ = capacity;
          ++size_;
          return atMut(index);
        }

        // The later values move up one slot each: as bytes when they can, as std::vector does.
        if constexpr (relocatable<Value>) {
          std::ranges::copy_backward(std::as_bytes(viewMut().subspan(index)), std::as_writable_bytes(storageSpan().first(size_ + 1)).end());
          std::construct_at(&storageSpan()[index], std::move(value));
        } else {
          std::construct_at(&storageSpan()[size_], std::move(viewMut().back()));
          std::ranges::move_backward(viewMut().subspan(index, size_ - index - 1), viewMut().end());
          viewMut()[index] = std::move(value);
        }

        ++size_;
        return atMut(index);
      }

      // Removes the value at `index` and hands it back, moving the later ones down, as Rust's `remove`:
      // it leaves with what it borrows, region `a`, and none of this Vec's storage.
      tbc::val_a<Value> remove(std::size_t index) {
        TELAR_ASSERT(index < size_);
        Value removed = std::move(viewMut()[index]);

        std::ranges::move(viewMut().subspan(index + 1), viewMut().subspan(index).begin());
        --size_;
        std::destroy_at(&storageSpan()[size_]);
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
          if (!keep(view()[index])) {
            continue;
          }

          // A different slot, `kept` being behind `index`: read through a raw pointer, as Rust's `retain`
          // moves values within its buffer.
          if (kept != index) {
            viewMut()[kept] = std::move(*tbc::raw(&viewMut()[index]));
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
            copy(values, spanOver(storage, capacity).subspan(size_));
          } catch (...) {
            deallocate(storage, capacity);
            throw;
          }

          relocate(spanOver(storage, capacity));
          deallocate(items_, capacity_);
          items_ = tbc::raw(storage);
          capacity_ = capacity;
        } else {
          copy(values, storageSpan().subspan(size_));
        }

        size_ = count;
      }

      friend inline bool operator==(const Vec& left, const Vec& right)
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
          memory_->deallocate(static_cast<void*>(storage), count * sizeof(Value), alignof(Value));
        }
      }

      // Moves the values into storage of at least `capacity` values.
      void reallocate(std::size_t capacity) {
        auto* storage = allocate(capacity);

        relocate(spanOver(storage, capacity));
        deallocate(items_, capacity_);
        items_ = tbc::raw(storage);
        capacity_ = capacity;
      }

      // The storage, whose first `size_` slots hold the values.
      [[nodiscard]] std::span<Value> storageSpan() noexcept {
        return spanOver(items_, capacity_);
      }

      // Moves the values into new storage and ends their lifetimes in the old one.
      void relocate(std::span<Value> storage) noexcept {
        relocate(viewMut(), storage);
      }

      // Moves the values of `source` to the start of `target`, which has room for them.
      static void relocate(std::span<Value> source, std::span<Value> target) noexcept {
        if constexpr (relocatable<Value>) {
          std::ranges::copy(std::as_bytes(source), std::as_writable_bytes(target).begin());
        } else {
          std::uninitialized_move(source.begin(), source.end(), target.begin());
          std::ranges::destroy(source);
        }
      }

      // Copies values into uninitialized storage: as bytes when they are trivially copyable, which
      // std::uninitialized_copy leaves to a loop.
      static void copy(std::span<const Value> values, std::span<Value> target) {
        if constexpr (std::is_trivially_copyable_v<Value>) {
          std::ranges::copy(std::as_bytes(values), std::as_writable_bytes(target).begin());
        } else {
          std::uninitialized_copy(values.begin(), values.end(), target.begin());
        }
      }

      void release() noexcept {
        std::ranges::destroy(viewMut());
        deallocate(items_, capacity_);
        items_ = nullptr;
        size_ = 0;
        capacity_ = 0;
      }

      // Small Vecs grow straight to a cache line's worth of values rather than through 1, 2 and 4.
      static constexpr std::size_t minimum_capacity = std::max<std::size_t>(1, 64 / sizeof(Value));

      tbc::val_a<Memory*> memory_;
      // The values live in storage from the allocator, region `a`, as a Rust `Vec<'a, T>` in an arena keeps them.
      tbc::val_a<Value*> items_ = nullptr;
      std::size_t size_ = 0;
      std::size_t capacity_ = 0;
    };

    // Owned bytes in memory from an allocator, as Rust's `String`, followed by a NUL for C. Up to 23
    // bytes live inline, all the room beside the allocator, so a short String does not allocate. It
    // keeps no pointer into itself, so containers relocate it as its bytes. Copying allocates, so it is
    // explicit (`clone`).
    template <Allocator Memory>
    class [[tbc::generic]] String {
    public:
      using trivially_relocatable = String;

      explicit String(tbc::mut_a<Memory> memory) noexcept
          : memory_(&memory) {
        setInlineSize(0);
      }

      // Copies the text, so the String borrows nothing of it.
      String(tbc::mut_a<Memory> memory, std::string_view text)
          : memory_(&memory) {
        if (text.size() <= inline_capacity) [[likely]] {
          copyShort(representation_.bytes.viewMut(), text);
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

      String& operator=(String&& other) { // NOLINT(bugprone-exception-escape,cppcoreguidelines-noexcept-move-operations,performance-noexcept-move-constructor): moving between two allocators allocates, as std::vector's move does
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
      [[nodiscard]] tbc::val_a<String> clone() const {
        String copy{*memory_};

        copy.append(view());
        return copy;
      }

      [[nodiscard]] std::size_t size() const noexcept {
        return onHeap() ? representation_.heap.size : inline_capacity - tag();
      }

      // The allocator its storage comes from, which a String built beside it shares.
      [[nodiscard]] tbc::mut_a<Memory> memory() const noexcept {
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
        return onHeap() ? representation_.heap.data : representation_.bytes.data();
      }

      [[nodiscard]] std::string_view view() const noexcept {
        if (onHeap()) {
          return {representation_.heap.data, representation_.heap.size};
        }

        return {representation_.bytes.data(), inline_capacity - tag()};
      }

      // The bytes to edit in place, as a span over `size()` of them; the NUL after them stays.
      [[nodiscard]] std::span<char> viewMut() noexcept {
        return storageMut().first(size());
      }

      // As std::string converts, so that a String passes where text is read.
      [[nodiscard]] operator std::string_view() const noexcept { // NOLINT(cppcoreguidelines-explicit-constructor,misc-explicit-constructor): converts implicitly as std::string does
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

          copyShort(shorter.bytes.viewMut(), view());
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
            std::ranges::copy(text, storageOf(heap).subspan(heap.size).begin());
            heap.size += count;
            storageOf(heap)[heap.size] = '\0';
            return;
          }
        } else if (const auto size = inline_capacity - tag(); count <= inline_capacity - size) [[likely]] {
          copyShort(representation_.bytes.viewMut().subspan(size), text);
          setInlineSize(size + count);
          return;
        }

        reallocate(grownCapacity(count), text);
      }

      void push(char character) {
        if (onHeap()) {
          auto& heap = representation_.heap;

          if (heap.size < (heap.capacity & ~heap_flag)) [[likely]] {
            storageOf(heap)[heap.size] = character;
            ++heap.size;
            storageOf(heap)[heap.size] = '\0';
            return;
          }
        } else if (const auto size = inline_capacity - tag(); size < inline_capacity) [[likely]] {
          representation_.bytes.atMut(size) = character;
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
        return storageMut().data();
      }

      [[nodiscard]] char operator[](std::size_t index) const noexcept {
        TELAR_ASSERT(index < size());
        return view()[index];
      }

      [[nodiscard]] char& atMut(std::size_t index) noexcept {
        TELAR_ASSERT(index < size());
        return storageMut()[index];
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
        std::ranges::fill(storageMut().subspan(size, count - size), fill);
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

        const char last = view().back();

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

        const auto size = this->size();

        moveBytes(storageMut(), {.from = index + count, .to = index, .count = size - index - count});
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
        if (result > capacity() || overlapsStorage(text)) {
          // New storage, so the text and the old bytes stay intact while they are copied.
          const auto capacity = roundedCapacity(std::max(result, size));
          const std::span<const char> old = view();
          auto* storage = static_cast<char*>(allocateBytes(*memory_, capacity + 1, 1));
          auto* end = std::ranges::copy(old.first(index), storage).out;

          end = std::ranges::copy(text, end).out;
          end = std::ranges::copy(old.subspan(index + count), end).out;
          *end = '\0';
          release();
          representation_.heap = {
              .data = tbc::raw(storage),
              .size = result,
              .capacity = capacity | heap_flag,
          };

          return;
        }

        moveBytes(storageMut(), {.from = index + count, .to = index + text.size(), .count = size - index - count});
        std::ranges::copy(text, storageMut().subspan(index).begin());
        setSize(result);
      }

      friend inline bool operator==(const String& left, const String& right) noexcept {
        return left.view() == right.view();
      }

      friend inline bool operator==(const String& left, std::string_view right) noexcept {
        return left.view() == right;
      }

      friend inline std::strong_ordering operator<=>(const String& left, const String& right) noexcept {
        return left.view() <=> right.view();
      }

      friend inline std::strong_ordering operator<=>(const String& left, std::string_view right) noexcept {
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
        Array<char, sizeof(Heap)> bytes;
      };

      // Bytes that move within the storage: `count` of them, from index `from` to index `to`.
      struct Move {
        std::size_t from;
        std::size_t to;
        std::size_t count;
      };

      static_assert(std::endian::native == std::endian::little, "the capacity's top byte is the last inline byte");

      static constexpr std::size_t inline_capacity = sizeof(Heap) - 1;
      static constexpr std::size_t heap_flag = std::size_t{1} << (std::numeric_limits<std::size_t>::digits - 1U);

      // The heap flag's bit in the last inline byte, which is the capacity's top one.
      static constexpr std::size_t heap_tag = heap_flag >> ((sizeof(std::size_t) - 1) * std::numeric_limits<unsigned char>::digits);

      // Leaves the top bits of a capacity free for the flag, and its rounding from overflowing.
      static constexpr std::size_t maximum_capacity = heap_flag / 4;

      // The allocator hands bytes out in blocks of this many.
      static constexpr std::size_t allocation_block = 16;

      [[nodiscard]] std::size_t tag() const noexcept {
        return static_cast<unsigned char>(representation_.bytes[inline_capacity]);
      }

      [[nodiscard]] bool onHeap() const noexcept {
        return (tag() & heap_tag) != 0;
      }

      // The heap storage's bytes: its capacity's and the NUL's.
      [[nodiscard]] static std::span<char> storageOf(Heap& heap) noexcept {
        return spanOver(heap.data, (heap.capacity & ~heap_flag) + 1);
      }

      // The storage's bytes, `capacity()` and the NUL's: the heap's, or the inline ones and the tag,
      // which is their NUL when all are used.
      [[nodiscard]] std::span<char> storageMut() noexcept {
        if (onHeap()) {
          return storageOf(representation_.heap);
        }

        return representation_.bytes.viewMut();
      }

      // Whether the text lies in this String's storage, its NUL included.
      [[nodiscard]] bool overlapsStorage(std::string_view text) const noexcept {
        const auto address = std::bit_cast<std::uintptr_t>(text.data());
        const auto start = std::bit_cast<std::uintptr_t>(data());

        return address >= start && address - start <= capacity();
      }

      // Moves bytes within `storage`, the source and target overlapping or not, as memmove does.
      static void moveBytes(std::span<char> storage, Move move) noexcept {
        const std::span<const char> source = storage.subspan(move.from, move.count);

        if (move.to > move.from) {
          std::ranges::copy_backward(source, storage.subspan(move.to, move.count).end());
        } else {
          std::ranges::copy(source, storage.subspan(move.to, move.count).begin());
        }
      }

      void setInlineSize(std::size_t size) noexcept {
        TELAR_ASSERT(size <= inline_capacity);
        representation_.bytes.atMut(size) = '\0';
        representation_.bytes.atMut(inline_capacity) = static_cast<char>(inline_capacity - size);
      }

      // Sets the size within the current storage, followed by its NUL.
      void setSize(std::size_t size) noexcept {
        if (onHeap()) {
          representation_.heap.size = size;
          storageOf(representation_.heap)[size] = '\0';
        } else {
          setInlineSize(size);
        }
      }

      // A capacity of at least `count` bytes whose NUL ends a whole block, as the allocator hands them
      // out.
      [[nodiscard]] static std::size_t roundedCapacity(std::size_t count) {
        if (count > maximum_capacity) {
          throw std::bad_array_new_length{};
        }

        return ((count + allocation_block) & ~(allocation_block - 1)) - 1;
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
        auto* end = std::ranges::copy(current, storage).out;

        end = std::ranges::copy(text, end).out;
        *end = '\0';
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

      tbc::val_a<Memory*> memory_;
      Representation representation_;
    };

    // An output iterator that appends to a String, so that std::format_to writes into one in a single
    // pass, growing it as std::back_inserter grows a std::string.
    template <Allocator Memory>
    class [[tbc::generic]] StringAppender {
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
    [[tbc::generic]] void formatTo(String<Memory>& text, std::format_string<Arguments...> format, Arguments&&... arguments) {
      std::format_to(StringAppender<Memory>{text}, format, std::forward<Arguments>(arguments)...);
    }

    // The formatted arguments in a String from `memory`, as std::format returns a std::string.
    template <Allocator Memory, typename... Arguments>
    [[tbc::generic]] [[nodiscard]] tbc::val_a<String<Memory>> format(tbc::mut_a<Memory> memory, std::format_string<Arguments...> format, Arguments&&... arguments) {
      String<Memory> text{memory};

      formatTo(text, format, std::forward<Arguments>(arguments)...);
      return text;
    }

    // A hash for Map keys: integers, enumerations, pointers and text, mixed so that the low bits a
    // table indexes by depend on every bit of the key, and seeded per process. Text hashes as wyhash
    // does: overlapping words for short text, three lanes of 16 bytes for long.
    struct [[tbc::hot_path]] Hash {
      template <typename Key>
        requires(std::is_integral_v<Key> || std::is_enum_v<Key> || std::is_pointer_v<Key>)
      [[nodiscard]] std::uint64_t operator()(Key key) const noexcept {
        std::uint64_t bits{};

        if constexpr (std::is_pointer_v<Key>) {
          bits = std::bit_cast<std::uintptr_t>(key);
        } else {
          bits = static_cast<std::uint64_t>(key);
        }

        return mix(bits ^ hashSeed(), hash_secrets[1]);
      }

      [[nodiscard]] inline std::uint64_t operator()(std::string_view text) const noexcept {
        const std::span<const char> bytes{text};
        const auto count = bytes.size();
        std::uint64_t first = 0;
        std::uint64_t second = 0;
        auto seed = hashSeed();

        if (count <= short_text) [[likely]] {
          if (count >= sizeof(std::uint32_t)) {
            const auto quarter = (count >> 3U) << 2U;

            first = (read32(bytes) << half_bits) | read32(bytes.subspan(quarter));
            second = (read32(bytes.last(sizeof(std::uint32_t))) << half_bits) | read32(bytes.subspan(count - sizeof(std::uint32_t) - quarter));
          } else if (count > 0) {
            first = (byteAt(bytes, 0) << (2 * byte_bits)) | (byteAt(bytes, count >> 1U) << byte_bits) | byteAt(bytes, count - 1);
          }
        } else {
          auto rest = bytes;

          // Three lanes a round while more than a round is left, then one at a time.
          if (rest.size() > round_bytes) {
            auto lane1 = seed;
            auto lane2 = seed;

            while (rest.size() > round_bytes) {
              seed = lane<1>(rest, seed);
              lane1 = lane<2>(rest.subspan(lane_bytes), lane1);
              lane2 = lane<3>(rest.subspan(2 * lane_bytes), lane2);
              rest = rest.subspan(round_bytes);
            }

            seed ^= lane1 ^ lane2;
          }

          while (rest.size() > lane_bytes) {
            seed = lane<1>(rest, seed);
            rest = rest.subspan(lane_bytes);
          }

          // The last 16 bytes, which the last lane may have read too, end the text.
          first = read64(bytes.last(lane_bytes));
          second = read64(bytes.last(sizeof(std::uint64_t)));
        }

        return mix(hash_secrets[1] ^ count, mix(first ^ hash_secrets[1], second ^ seed));
      }

    private:
      // Text up to this long hashes as overlapping words, and longer text in lanes of this many bytes.
      static constexpr std::size_t short_text = 16;
      static constexpr std::size_t lane_bytes = 16;
      static constexpr std::size_t round_bytes = 3 * lane_bytes;
      static constexpr std::size_t byte_bits = 8;
      static constexpr std::size_t half_bits = 32;

      [[nodiscard]] static inline std::uint64_t byteAt(std::span<const char> bytes, std::size_t index) noexcept {
        return std::uint64_t{static_cast<unsigned char>(bytes[index])};
      }

      // Mixes the lane of 16 bytes at the start of `bytes` into `seed` with the secret of rank `secret`.
      template <std::size_t secret>
      [[nodiscard]] static std::uint64_t lane(std::span<const char> bytes, std::uint64_t seed) noexcept {
        return mix(read64(bytes) ^ hash_secrets[secret], read64(bytes.subspan(sizeof(std::uint64_t))) ^ seed);
      }
    };

    // A hash map in memory from an allocator, as Rust's `HashMap`: a Swiss table, whose open
    // addressing keeps a byte of each key's hash apart, so that a lookup compares eight of them at a
    // time and reads a key only where its byte matches. Values relocate without throwing, as Rust moves
    // them, and as bytes where they can. Copying allocates, so it is explicit (`clone`).
    template <typename Key, typename Value, Allocator Memory, typename Hasher = Hash>
      requires(std::is_nothrow_move_constructible_v<Key> && std::is_nothrow_move_constructible_v<Value> && std::is_nothrow_invocable_r_v<std::uint64_t, Hasher, KeyLookup<Key>>)
    class [[tbc::generic]] Map {
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
        [[nodiscard]] tbc::ref_a<Entry> operator*() const noexcept {
          return *entry_;
        }

        [[nodiscard]] tbc::val_a<const Entry*> operator->() const noexcept {
          return entry_;
        }

        Iterator& operator++() noexcept {
          ++control_;
          ++entry_;
          skip();
          return *this;
        }

        friend inline bool operator==(const Iterator& left, const Iterator& right) noexcept {
          return left.control_ == right.control_;
        }

      private:
        friend class Map;

        Iterator(tbc::val_a<const std::int8_t*> control, tbc::val_a<const Entry*> entry) noexcept
            : control_(control),
              entry_(entry) {
          skip();
        }

        // Stops at a full slot or at the sentinel past the last one. A group's width of control bytes
        // follows every slot's, the sentinel's and the copies of the first slots'.
        void skip() noexcept {
          while (*control_ < Group::sentinel) {
            const auto shift = Group::leadingEmptyOrRemoved(Group::load(spanOver(control_, Group::width)));

            control_ += shift;
            entry_ += shift;
          }
        }

        tbc::val_a<const std::int8_t*> control_;
        tbc::val_a<const Entry*> entry_;
      };

      explicit Map(tbc::mut_a<Memory> memory) noexcept
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

      Map& operator=(Map&& other) { // NOLINT(bugprone-exception-escape,cppcoreguidelines-noexcept-move-operations,performance-noexcept-move-constructor): moving between two allocators allocates, as std::vector's move does
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
          if (other.controlView()[index] >= 0) {
            auto& entry = other.entriesMut()[index];

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
      [[nodiscard]] tbc::val_a<Map> clone() const
        requires(std::is_copy_constructible_v<Key> && std::is_copy_constructible_v<Value>)
      {
        Map copy{*memory_};

        if (mask_ == 0) {
          return copy;
        }

        // The copy keeps each slot where it is, removed ones too, so no key is hashed again.
        auto [control, entries] = allocateBlock(*memory_, mask_);

        copy.control_ = tbc::raw(control);
        copy.entries_ = tbc::raw(entries);
        copy.mask_ = mask_;
        resetControl(copy.controlMut());

        // A slot counts once its entry is constructed, so where a copy throws, the copy's destructor
        // destroys the ones before it.
        for (std::size_t index = 0; index < mask_; ++index) {
          const auto byte = controlView()[index];

          if (byte >= 0) {
            std::construct_at(&copy.entriesMut()[index], entriesView()[index]);
            ++copy.size_;
          }

          if (byte != Group::empty) {
            setControl(copy.controlMut(), index, byte);
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

        return index == not_found ? nullptr : &entriesView()[index].value;
      }

      [[nodiscard]] Value* findMut(Lookup key) {
        const auto index = locate(key, hashOf(key));

        return index == not_found ? nullptr : &entriesMut()[index].value;
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
          entriesMut()[index].value = std::move(value);
          return false;
        }

        add(hash, std::move(key), std::move(value));
        return true;
      }

      // Removes the key's entry and hands its value back, as Rust's `remove`: it leaves with what it
      // borrows, region `a`, and none of this Map's storage.
      tbc::val_a<Option<Value>> remove(Lookup key) {
        const auto index = locate(key, hashOf(key));
        if (index == not_found) {
          return {};
        }

        // The value leaves with the borrows it holds, region `a`, not with a borrow of this Map's storage.
        Option<Value> removed{std::move(tbc::raw(&entriesMut()[index])->value)};

        erase(index);
        return removed;
      }

      // Keeps the entries `keep` accepts and drops the others, as Rust's `retain`. `keep` sees each key
      // shared and its value mutable, and must not reach this Map. Returns how many it dropped.
      template <typename Predicate>
      std::size_t retain(Predicate keep) {
        std::size_t dropped = 0;

        for (std::size_t index = 0; index < mask_; ++index) {
          if (controlView()[index] >= 0 && !keep(std::as_const(entriesMut()[index].key), entriesMut()[index].value)) {
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
        resetControl(controlMut());
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
          capacity = (capacity * 2) + 1;
        }

        rehash(capacity);
      }

      [[nodiscard]] Iterator begin() const noexcept {
        return Iterator{control_, entries_};
      }

      [[nodiscard]] Iterator end() const noexcept {
        return Iterator{&controlView()[mask_], std::to_address(entriesView().end())};
      }

    private:
      // A block of storage for a number of slots: their control bytes, then their entries.
      struct Block {
        std::int8_t* control;
        Entry* entries;
      };

      static constexpr std::size_t not_found = std::numeric_limits<std::size_t>::max();
      static constexpr std::size_t block_alignment = std::max(alignof(Entry), alignof(std::uint64_t));

      // A full slot's byte keeps the low bits of its key's hash, and the rest pick where probes start.
      static constexpr std::size_t tag_bits = Group::top_bit;
      static constexpr std::uint64_t tag_mask = (std::uint64_t{1} << tag_bits) - 1;

      // One slot in this many stays free, so that every probe ends at an empty one.
      static constexpr std::size_t free_share = 8;

      // A table grows into as many slots, rather than twice as many, while its entries fill at most
      // this share of them, removed slots taking the rest.
      static constexpr std::size_t in_place_entries = 25;
      static constexpr std::size_t in_place_slots = 32;

      [[nodiscard]] static std::uint64_t hashOf(Lookup key) noexcept {
        return Hasher{}(key);
      }

      // The control bytes: a slot's each, the sentinel's, and copies of the first slots'.
      [[nodiscard]] std::span<const std::int8_t> controlView() const noexcept {
        return spanOver<const std::int8_t>(control_, controlBytes(mask_));
      }

      [[nodiscard]] std::span<std::int8_t> controlMut() noexcept {
        return spanOver(control_, controlBytes(mask_));
      }

      // The entries, a slot's each; only the full slots' are alive.
      [[nodiscard]] std::span<const Entry> entriesView() const noexcept {
        return spanOver<const Entry>(entries_, mask_);
      }

      [[nodiscard]] std::span<Entry> entriesMut() noexcept {
        return spanOver(entries_, mask_);
      }

      // Destroys the entry in a full slot.
      void erase(std::size_t index) noexcept {
        std::destroy_at(&entriesMut()[index]);
        --size_;

        // A slot no probe ever passed full can be empty again; any other stays removed, so that probes
        // for the keys past it go on.
        const auto before = Group::matchEmpty(Group::load(controlView().subspan((index - Group::width) & mask_)));
        const auto after = Group::matchEmpty(Group::load(controlView().subspan(index)));

        if (mask_ < Group::width || (before != 0 && after != 0 && Group::lastFromEnd(before) + Group::first(after) < Group::width)) {
          setControl(controlMut(), index, Group::empty);
          ++growth_left_;
        } else {
          setControl(controlMut(), index, Group::removed);
        }
      }

      // The byte a full slot keeps of its key's hash; the rest of the hash picks where probes start.
      [[nodiscard]] static std::uint8_t tagOf(std::uint64_t hash) noexcept {
        return static_cast<std::uint8_t>(hash & tag_mask);
      }

      [[nodiscard]] static std::int8_t* emptyControl() noexcept {
        return tbc::raw(const_cast<std::int8_t*>(empty_group.data())); // NOLINT(cppcoreguidelines-pro-type-const-cast): a Map writes control bytes only once it holds storage of its own
      }

      // Fills seven slots in eight, and always leaves one empty, where every probe ends.
      [[nodiscard]] static std::size_t growthOf(std::size_t capacity) noexcept {
        return capacity - ((capacity + 1) / free_share);
      }

      // The control bytes are the slots', the sentinel's, and copies of the first slots' after it, so
      // that a group read near the end wraps around to the beginning.
      [[nodiscard]] static std::size_t controlBytes(std::size_t capacity) noexcept {
        return capacity + Group::width;
      }

      [[nodiscard]] static std::size_t entriesOffset(std::size_t capacity) noexcept {
        return (controlBytes(capacity) + alignof(Entry) - 1) & ~(alignof(Entry) - 1);
      }

      // The bytes of a block for `capacity` slots, which one already allocated is known to fit.
      [[nodiscard]] static std::size_t blockBytes(std::size_t capacity) noexcept {
        return entriesOffset(capacity) + (capacity * sizeof(Entry));
      }

      // A block for `capacity` slots from `memory`, its control bytes yet to be reset.
      [[nodiscard]] static Block allocateBlock(Memory& memory, std::size_t capacity) {
        if (capacity > (std::numeric_limits<std::size_t>::max() - entriesOffset(capacity)) / sizeof(Entry)) {
          throw std::bad_array_new_length{};
        }

        void* block = allocateBytes(memory, blockBytes(capacity), block_alignment);
        void* entries = &spanOver(static_cast<std::byte*>(block), blockBytes(capacity))[entriesOffset(capacity)];

        return {.control = static_cast<std::int8_t*>(block), .entries = static_cast<Entry*>(entries)};
      }

      // Sets a slot's control byte and, for one of the first slots, its copy past the sentinel.
      static void setControl(std::span<std::int8_t> control, std::size_t index, std::int8_t byte) noexcept {
        const auto mask = control.size() - Group::width;

        control[index] = byte;
        control[((index - (Group::width - 1)) & mask) + (Group::width - 1)] = byte;
      }

      // Marks every slot empty, and the sentinel after them.
      static void resetControl(std::span<std::int8_t> control) noexcept {
        std::ranges::fill(control, Group::empty);
        control[control.size() - Group::width] = Group::sentinel;
      }

      // Probes a group at a time, at triangular strides, which visit every group of a power of two.
      [[nodiscard]] std::size_t locate(Lookup key, std::uint64_t hash) const {
        const auto tag = tagOf(hash);
        auto offset = (hash >> tag_bits) & mask_;
        std::size_t stride = 0;

        while (true) {
          const auto word = Group::load(controlView().subspan(offset));

          for (auto matches = Group::match(word, tag); matches != 0; matches &= matches - 1) {
            const auto index = (offset + Group::first(matches)) & mask_;
            if (entriesView()[index].key == key) [[likely]] {
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

      // The first empty or removed slot of the probe sequence of `hash`.
      [[nodiscard]] static std::size_t firstFree(std::span<const std::int8_t> control, std::uint64_t hash) noexcept {
        const auto mask = control.size() - Group::width;
        auto offset = (hash >> tag_bits) & mask;
        std::size_t stride = 0;

        while (true) {
          if (const auto free = Group::matchEmptyOrRemoved(Group::load(control.subspan(offset))); free != 0) [[likely]] {
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

        const auto index = firstFree(controlView(), hash);
        if (controlView()[index] == Group::empty) {
          --growth_left_;
        }

        setControl(controlMut(), index, static_cast<std::int8_t>(tagOf(hash)));
        std::construct_at(&entriesMut()[index], std::move(key), std::move(value));
        ++size_;
      }

      // Doubles the slots, or, where removed slots took the room, rehashes into as many.
      void grow() {
        if (mask_ != 0 && size_ * in_place_slots <= mask_ * in_place_entries) {
          rehash(mask_);
        } else {
          rehash(mask_ == 0 ? Group::width - 1 : (mask_ * 2) + 1);
        }
      }

      // Moves the entries to new storage of `capacity` slots, a power of two less one.
      void rehash(std::size_t capacity) {
        auto [control, entries] = allocateBlock(*memory_, capacity);

        resetControl(spanOver(control, controlBytes(capacity)));
        for (std::size_t index = 0; index < mask_; ++index) {
          if (controlView()[index] < 0) {
            continue;
          }

          const auto hash = hashOf(entriesView()[index].key);
          const auto target = firstFree(spanOver<const std::int8_t>(control, controlBytes(capacity)), hash);

          setControl(spanOver(control, controlBytes(capacity)), target, static_cast<std::int8_t>(tagOf(hash)));
          // The new storage and this Map's are separate allocations.
          relocate(tbc::raw(&spanOver(entries, capacity)[target]), tbc::raw(&entriesMut()[index]));
        }

        deallocate();
        control_ = tbc::raw(control);
        entries_ = tbc::raw(entries);
        mask_ = capacity;
        growth_left_ = growthOf(capacity) - size_;
      }

      static void relocate(Entry* target, Entry* source) noexcept {
        if constexpr (relocatable<Entry>) {
          std::ranges::copy(std::as_bytes(spanOver(source, 1)), std::as_writable_bytes(spanOver(target, 1)).begin());
        } else {
          std::construct_at(target, std::move(*source));
          std::destroy_at(source);
        }
      }

      void destroyEntries() noexcept {
        if constexpr (!std::is_trivially_destructible_v<Entry>) {
          for (std::size_t index = 0; index < mask_; ++index) {
            if (controlView()[index] >= 0) {
              std::destroy_at(&entriesMut()[index]);
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

      tbc::val_a<Memory*> memory_;
      std::int8_t* control_ = emptyControl();
      // The entries live in storage from the allocator, region `a`, as a Vec's values do.
      tbc::val_a<Entry*> entries_ = nullptr;
      std::size_t mask_ = 0;
      std::size_t size_ = 0;
      std::size_t growth_left_ = 0;
    };

    template <typename Signature, std::size_t Capacity = 3 * sizeof(void*)>
    class Function;

    namespace detail {

      // What a Function's callable returns, region `a`; nothing to label for void.
      template <typename Result>
      struct FunctionResult {
        using type = tbc::val_a<Result>;
      };

      template <>
      struct FunctionResult<void> {
        using type = void;
      };

    }

    // A callable of any type behind one signature, as std::move_only_function and Rust's
    // `Box<dyn FnMut>`, stored inline so that it never allocates: a callable larger than Capacity
    // bytes, aligned past a pointer, or whose move can throw does not convert. A call may mutate the
    // callable, as an `FnMut`'s does, so it is not const. Calling an empty Function traps.
    template <typename Result, typename... Arguments, std::size_t Capacity>
    class [[tbc::generic]] Function<Result(Arguments...), Capacity> {
      // Scalars pass to the callable by value, in registers, and the rest by reference, as libc++'s
      // std::function passes them.
      template <typename Argument>
      using Pass = std::conditional_t<std::is_scalar_v<Argument>, Argument, Argument&&>;

      // The result borrows what the callable at the storage holds, region `a`, never the arguments, region
      // `b`, as Rust's FnMut returns an Output that borrows none of them.
      using Invoke = detail::FunctionResult<Result>::type (*)(tbc::val_a<void*>, tbc::val_b<Pass<Arguments>>...);

      // The storage a manager moves a callable out of, and the one it moves it to, null to only destroy it.
      struct Relocation {
        void* target;
        void* source;
      };

      // Moves the callable at the source to the target and destroys it, or only destroys it when the
      // target is null.
      using Manage = void (*)(Relocation relocation) noexcept;

    public:
      Function() noexcept = default;

      template <typename Callable>
        requires(!std::same_as<Callable, Function> && std::is_invocable_r_v<Result, Callable&, Arguments...> && sizeof(Callable) <= Capacity && alignof(Callable) <= alignof(void*) && std::is_nothrow_move_constructible_v<Callable>)
      Function(Callable callable) noexcept // NOLINT(cppcoreguidelines-explicit-constructor,misc-explicit-constructor): a callable converts as it does to std::function
          : invoke_(&call<Callable>),
            manage_(std::is_trivially_copyable_v<Callable> ? nullptr : &manage<Callable>) {
        ::new (static_cast<void*>(storage_.dataMut())) Callable(std::move(callable));
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
      Result operator()(tbc::val_b<Arguments>... arguments) { // NOLINT(performance-unnecessary-value-param): each argument passes on as the signature takes it, as std::function's call does
        return invoke_(storage_.dataMut(), std::forward<Arguments>(arguments)...);
      }

    private:
      template <typename Callable>
      static Result call(void* storage, Pass<Arguments>... arguments) {
        return std::invoke_r<Result>(*static_cast<Callable*>(storage), std::forward<Arguments>(arguments)...);
      }

      [[noreturn]] static Result callEmpty(void* /*storage*/, Pass<Arguments>... /*arguments*/) noexcept {
        __builtin_verbose_trap("telar::ds::Function", "called while empty");
      }

      template <typename Callable>
      static void manage(Relocation relocation) noexcept {
        auto* callable = static_cast<Callable*>(relocation.source);

        if (relocation.target != nullptr) {
          std::construct_at(static_cast<Callable*>(relocation.target), std::move(*callable));
        }

        std::destroy_at(callable);
      }

      // Takes the callable of `other`, whose manager this Function already holds. A trivially copyable
      // one moves as its bytes.
      void take(Function& other) noexcept {
        if (manage_ == nullptr) {
          storage_ = other.storage_;
        } else {
          manage_({.target = storage_.dataMut(), .source = other.storage_.dataMut()});
        }
      }

      void destroy() noexcept {
        if (manage_ != nullptr) {
          manage_({.target = nullptr, .source = storage_.dataMut()});
        }
      }

      alignas(void*) Array<std::byte, Capacity> storage_{};
      Invoke invoke_ = &callEmpty;
      Manage manage_ = nullptr;
    };

  }

  // A String formats as its text does.
  template <telar::Allocator Memory>
  struct [[tbc::generic]] std::formatter<telar::ds::String<Memory>, char> : std::formatter<std::string_view, char> {
    template <typename Context>
    auto format(const telar::ds::String<Memory>& text, Context& context) const {
      return std::formatter<std::string_view, char>::format(text.view(), context);
    }
  };
}
