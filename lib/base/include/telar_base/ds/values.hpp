#pragma once

#include "tbc/annotations.hpp"
#include "tbc/view.hpp"
#include "telar_base/diagnostics/config.hpp"
#include <algorithm>
#include <compare>
#include <concepts>
#include <cstddef>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <type_traits>
#include <utility>
#ifdef _LIBCPP_VERSION
#include <__type_traits/is_trivially_relocatable.h>
#endif

// Containers that follow the C++ tbc checks (lib/tbc/docs/contracts.md): a read is a const method, and
// mutable access has a name of its own, as Rust's `get` and `get_mut`, so no method is overloaded on
// constness. lib/base/tools/ds_bench.cpp measures each against its standard counterpart.
// This header holds the containers that need no allocator, so that the allocator's own header can
// use them; telar_base/ds/containers.hpp holds the others. Module units import telar.base.ds.
namespace telar::ds {

  // Whether a value can move to other storage as its bytes, as every Rust value does: a trivially
  // copyable one, or one the standard library knows holds no pointer into itself, such as libc++'s
  // std::string, which std::vector relocates the same way. A ds type says so with a
  // `trivially_relocatable` member naming its own type, as libc++'s do, which a type deriving from it
  // does not inherit.
  template <typename Value>
  constexpr bool relocatable = std::is_trivially_copyable_v<Value>
#ifdef _LIBCPP_VERSION
                               || std::__libcpp_is_trivially_relocatable<Value>::value
#endif
                               || requires { requires std::same_as<typename Value::trivially_relocatable, Value>; };

  // A fixed number of values stored inline, as std::array and Rust's `[T; N]`. An aggregate, so braces
  // initialize it and it copies as its values do.
  template <typename Value, std::size_t Count>
    requires(Count > 0)
  struct TBC_GENERIC Array {
    using value_type = Value;

    // Not static, as std::array's: a call reads as a call on the value it sizes.
    [[nodiscard]] constexpr std::size_t size() const noexcept {
      return Count;
    }

    [[nodiscard]] constexpr const Value& operator[](std::size_t index) const noexcept {
      TELAR_ASSERT(index < Count);
      return view()[index];
    }

    [[nodiscard]] constexpr Value& atMut(std::size_t index) noexcept {
      TELAR_ASSERT(index < Count);
      return viewMut()[index];
    }

    // A value whose index comes from outside, checked in every build: an index past the end throws
    // what std::array::at throws, for a caller that reports it.
    [[nodiscard]] constexpr const Value& at(std::size_t index) const {
      if (index >= Count) {
        throw std::out_of_range{"telar::ds::Array index out of range"};
      }

      return view()[index];
    }

    [[nodiscard]] constexpr Value& atCheckedMut(std::size_t index) {
      if (index >= Count) {
        throw std::out_of_range{"telar::ds::Array index out of range"};
      }

      return viewMut()[index];
    }

    [[nodiscard]] constexpr const Value& front() const noexcept {
      return values[0];
    }

    [[nodiscard]] constexpr const Value& back() const noexcept {
      return values[Count - 1];
    }

    [[nodiscard]] constexpr const Value* data() const noexcept {
      return std::data(values);
    }

    [[nodiscard]] constexpr Value* dataMut() noexcept {
      return std::data(values);
    }

    [[nodiscard]] constexpr std::span<const Value, Count> view() const noexcept {
      return std::span<const Value, Count>{values};
    }

    [[nodiscard]] constexpr std::span<Value, Count> viewMut() noexcept {
      return std::span<Value, Count>{values};
    }

    [[nodiscard]] constexpr const Value* begin() const noexcept {
      return std::begin(values);
    }

    [[nodiscard]] constexpr const Value* end() const noexcept {
      return std::end(values);
    }

    constexpr void fill(const Value& value) {
      std::ranges::fill(values, value);
    }

    // Spelled out rather than defaulted, as the comparison a default synthesizes over the C array
    // reads to the linter as a literal of its own.
    friend constexpr bool operator==(const Array& left, const Array& right) noexcept(noexcept(std::declval<const Value&>() == std::declval<const Value&>()))
      requires std::equality_comparable<Value>
    {
      return std::ranges::equal(left.view(), right.view());
    }

    friend constexpr auto operator<=>(const Array&, const Array&)
      requires std::three_way_comparable<Value>
    = default;

    // Public so that braces initialize it, as std::array's member is; read it through the methods.
    Value values[Count]; // NOLINT(cppcoreguidelines-avoid-c-arrays,modernize-avoid-c-arrays): the storage of the array type itself, as std::array's
  };

  template <typename First, typename... Rest>
  Array(First, Rest...) -> Array<First, 1 + sizeof...(Rest)>;

  // Structured bindings read an Array's values, as they read std::array's: `auto [a, b] = pair;`.
  template <std::size_t Index, typename Value, std::size_t Count>
    requires(Index < Count)
  [[nodiscard]] constexpr const Value& get(const Array<Value, Count>& array) noexcept {
    return array.values[Index];
  }

  template <std::size_t Index, typename Value, std::size_t Count>
    requires(Index < Count)
  [[nodiscard]] constexpr Value&& get(Array<Value, Count>&& array) noexcept {
    return std::move(array).values[Index];
  }

  // An Array of a C array's values, its size counted, as std::to_array does for a string literal's
  // characters. A braced list builds an Array directly, `Array<T, N>{a, b}`, which keeps a copy of each.
  template <typename Value, std::size_t Count>
  constexpr Array<std::remove_cv_t<Value>, Count> toArray(Value (&values)[Count]) { // NOLINT(cppcoreguidelines-avoid-c-arrays,modernize-avoid-c-arrays): a string literal is a C array
    return [&]<std::size_t... Index>(std::index_sequence<Index...>) {
      return Array<std::remove_cv_t<Value>, Count>{{std::span<Value, Count>{values}[Index]...}};
    }(std::make_index_sequence<Count>{});
  }

  // What an empty Option is built from, as Rust's `None`.
  struct None {
    explicit constexpr None() noexcept = default;
  };

  inline constexpr None none{};

  // A value or nothing, as std::optional and Rust's `Option<T>`. Its special members are trivial when
  // the value's are, so an Option of a trivial value copies as its bytes do.
  // NOLINTBEGIN(cppcoreguidelines-pro-type-union-access): the value lives in a union with nothing, as std::optional's does
  template <typename Value>
    requires(std::is_object_v<Value> && !std::is_array_v<Value>)
  class TBC_GENERIC Option {
  public:
    constexpr Option() noexcept
        : empty_() {}

    constexpr Option(None /*none*/) noexcept // NOLINT(cppcoreguidelines-explicit-constructor,misc-explicit-constructor): none converts to an empty Option as std::nullopt does
        : empty_() {}

    // Holds a value built from what it is given, a Value itself or anything a Value converts from, as
    // std::optional does; braces build a Value. It keeps what Value's constructor keeps of it.
    template <typename Other = Value>
      requires(!std::same_as<std::remove_cvref_t<Other>, Option> && !std::same_as<std::remove_cvref_t<Other>, None> && !std::same_as<std::remove_cvref_t<Other>, std::in_place_t> && std::is_constructible_v<Value, Other>)
    TBC_CONSTRUCTS constexpr explicit(!std::is_convertible_v<Other, Value>) Option(Other&& value)
        : value_(std::forward<Other>(value)),
          full_(true) {}

    // Holds a value converted from another Option's, as std::optional does. It keeps what Value's
    // constructor keeps of it.
    template <typename Other>
      requires(!std::same_as<Other, Value> && std::is_constructible_v<Value, const Other&>)
    TBC_CONSTRUCTS constexpr explicit(!std::is_convertible_v<const Other&, Value>) Option(const Option<Other>& other)
        : empty_() {
      if (other.hasValue()) {
        std::construct_at(&value_, other.get());
        full_ = true;
      }
    }

    // Builds the value in place, for one that cannot move, as std::optional's in_place constructor
    // does. It keeps what Value's constructor keeps of the arguments.
    template <typename... Arguments>
    TBC_CONSTRUCTS constexpr explicit Option(std::in_place_t /*tag*/, Arguments&&... arguments)
        : value_(std::forward<Arguments>(arguments)...),
          full_(true) {}

    constexpr Option(const Option&)
      requires std::is_trivially_copy_constructible_v<Value>
    = default;

    constexpr Option(const Option& other)
      requires(std::is_copy_constructible_v<Value> && !std::is_trivially_copy_constructible_v<Value>)
        : empty_() {
      if (other.full_) {
        std::construct_at(&value_, other.value_);
        full_ = true;
      }
    }

    constexpr Option(Option&&)
      requires std::is_trivially_move_constructible_v<Value>
    = default;

    constexpr Option(Option&& other) noexcept(std::is_nothrow_move_constructible_v<Value>)
      requires(std::is_move_constructible_v<Value> && !std::is_trivially_move_constructible_v<Value>)
        : empty_() {
      if (other.full_) {
        std::construct_at(&value_, std::move(other.value_));
        full_ = true;
      }
    }

    constexpr Option& operator=(const Option&)
      requires(std::is_trivially_copy_constructible_v<Value> && std::is_trivially_copy_assignable_v<Value> && std::is_trivially_destructible_v<Value>)
    = default;

    constexpr Option& operator=(const Option& other)
      requires(std::is_copy_constructible_v<Value> && std::is_copy_assignable_v<Value> && !(std::is_trivially_copy_constructible_v<Value> && std::is_trivially_copy_assignable_v<Value> && std::is_trivially_destructible_v<Value>))
    {
      if (this == &other) {
        return *this;
      }

      if (!other.full_) {
        reset();
      } else if (full_) {
        value_ = other.value_;
      } else {
        std::construct_at(&value_, other.value_);
        full_ = true;
      }

      return *this;
    }

    constexpr Option& operator=(Option&&)
      requires(std::is_trivially_move_constructible_v<Value> && std::is_trivially_move_assignable_v<Value> && std::is_trivially_destructible_v<Value>)
    = default;

    constexpr Option& operator=(Option&& other) noexcept(std::is_nothrow_move_constructible_v<Value> && std::is_nothrow_move_assignable_v<Value>) // NOLINT(bugprone-exception-escape): throws where the value's move does, as std::optional's
      requires(std::is_move_constructible_v<Value> && std::is_move_assignable_v<Value> && !(std::is_trivially_move_constructible_v<Value> && std::is_trivially_move_assignable_v<Value> && std::is_trivially_destructible_v<Value>))
    {
      if (this == &other) {
        return *this;
      }

      if (!other.full_) {
        reset();
      } else if (full_) {
        value_ = std::move(other.value_);
      } else {
        std::construct_at(&value_, std::move(other.value_));
        full_ = true;
      }

      return *this;
    }

    // Replaces what it holds with a value, which it takes by value as Rust moves one into place: a view
    // keeps what it views, not the view it was copied from. A template that leaves scalars out, as
    // std::optional's does, so that `option = {}` empties it through the move assignment rather than
    // storing a Value{}; a scalar is assigned through the constructor that converts it.
    template <typename Other = Value>
      requires(std::same_as<Other, Value> && !std::is_scalar_v<Value>)
    constexpr Option& operator=(tbc::val_a<Other> value) {
      if (full_) {
        value_ = std::move(value);
      } else {
        std::construct_at(&value_, std::move(value));
        full_ = true;
      }

      return *this;
    }

    // Replaces what it holds with what a value converts from, as std::optional does; it keeps what
    // Value's assignment keeps of it.
    template <typename Other>
      requires(!std::same_as<std::remove_cvref_t<Other>, Option> && !std::same_as<std::remove_cvref_t<Other>, None> && !std::same_as<std::remove_cvref_t<Other>, Value> && std::is_constructible_v<Value, Other> && std::is_assignable_v<Value&, Other>)
    constexpr Option& operator=(tbc::view<Other&&, tbc::lt::a> value) {
      if (full_) {
        value_ = std::forward<Other>(value);
      } else {
        std::construct_at(&value_, std::forward<Other>(value));
        full_ = true;
      }

      return *this;
    }

    constexpr ~Option()
      requires std::is_trivially_destructible_v<Value>
    = default;

    constexpr ~Option()
      requires(!std::is_trivially_destructible_v<Value>)
    {
      reset();
    }

    [[nodiscard]] constexpr bool hasValue() const noexcept {
      return full_;
    }

    constexpr explicit operator bool() const noexcept {
      return full_;
    }

    [[nodiscard]] constexpr const Value& get() const noexcept {
      TELAR_ASSERT(full_);
      return value_;
    }

    [[nodiscard]] constexpr Value& getMut() noexcept {
      TELAR_ASSERT(full_);
      return value_;
    }

    // The value, checked in every build as Rust's `unwrap` is: an empty Option throws what
    // std::optional::value throws, for a caller whose emptiness is an error it reports.
    [[nodiscard]] constexpr const Value& unwrap() const {
      if (!full_) {
        throw std::bad_optional_access{};
      }

      return value_;
    }

    [[nodiscard]] constexpr const Value& operator*() const noexcept {
      return get();
    }

    [[nodiscard]] constexpr const Value* operator->() const noexcept {
      return &get();
    }

    [[nodiscard]] constexpr tbc::val_a<Value> valueOr(tbc::val_a<Value> fallback) const
      requires std::is_copy_constructible_v<Value>
    {
      if (full_) {
        return value_;
      }

      return fallback;
    }

    template <typename... Arguments>
    constexpr Value& emplace(Arguments&&... arguments) {
      reset();
      std::construct_at(&value_, std::forward<Arguments>(arguments)...);
      full_ = true;
      return value_;
    }

    constexpr void reset() noexcept {
      if (!full_) {
        return;
      }

      std::destroy_at(&value_);
      full_ = false;
    }

    // Moves the value out and leaves this Option empty, as Rust's `take`.
    [[nodiscard]] constexpr Option take() noexcept(std::is_nothrow_move_constructible_v<Value>) {
      if (!full_) {
        return {};
      }

      Option taken{std::move(value_)};

      // What the moved value designates is the taken one's now; ending the old value's lifetime through a
      // raw pointer keeps the checker from merging the two, as Rust's `take` relies on unsafe code.
      std::destroy_at(tbc::raw(&value_));
      full_ = false;
      return taken;
    }

    friend constexpr bool operator==(const Option& left, const Option& right)
      requires std::equality_comparable<Value>
    {
      return left.full_ == right.full_ && (!left.full_ || left.value_ == right.value_);
    }

    friend constexpr bool operator==(const Option& option, None /*none*/) noexcept {
      return !option.full_;
    }

    friend constexpr auto operator<=>(const Option& left, const Option& right)
      requires std::three_way_comparable<Value>
    {
      using Ordering = std::compare_three_way_result_t<Value>;

      if (left.full_ && right.full_) {
        return left.value_ <=> right.value_;
      }

      return Ordering{static_cast<int>(left.full_) <=> static_cast<int>(right.full_)};
    }

  private:
    // The empty member keeps an empty Option a constant expression, as nothing else is alive in it.
    // Region `a` is the value's, as `'a` of Rust's `Option<&'a T>`: what a held view borrows, which the
    // methods that store or return a Value label too.
    union {
      char empty_;
      tbc::val_a<Value> value_;
    };

    bool full_ = false;
  };

  // NOLINTEND(cppcoreguidelines-pro-type-union-access)

  template <typename Value>
  Option(Value) -> Option<Value>;

  template <typename Type>
  constexpr bool is_option = false;

  template <typename Value>
  constexpr bool is_option<Option<Value>> = true;

  // Compares with a value as std::optional does: an empty Option is unequal to every value and orders
  // before it. Outside the class, so that only an Option deduces its first parameter and comparing
  // anything else never weighs these constraints.
  template <typename Value, typename Other>
    requires(!is_option<Other> && !std::same_as<Other, None> && std::equality_comparable_with<Value, Other>)
  constexpr bool operator==(const Option<Value>& option, const Other& value) {
    return option.hasValue() && option.get() == value;
  }

  template <typename Value, typename Other>
    requires(!is_option<Other> && !std::same_as<Other, None> && std::three_way_comparable_with<Value, Other>)
  constexpr std::compare_three_way_result_t<Value, Other> operator<=>(const Option<Value>& option, const Other& value) {
    return option.hasValue() ? option.get() <=> value : std::compare_three_way_result_t<Value, Other>{std::strong_ordering::less};
  }

  // A value that the objects referring to it read and replace by copy, as Rust's Cell: it hands out no
  // reference to what it holds, so replacing it through a shared reference invalidates nothing. Not
  // synchronized, as a Cell is not Sync: every holder of a reference runs on one thread.
  template <typename Value>
    requires std::is_trivially_copyable_v<Value>
  class TBC_SHARED Cell {
  public:
    constexpr Cell() noexcept = default;

    constexpr explicit Cell(Value value) noexcept
        : value_(value) {}

    Cell(const Cell&) = delete;
    Cell& operator=(const Cell&) = delete;
    Cell(Cell&&) = delete;
    Cell& operator=(Cell&&) = delete;
    constexpr ~Cell() = default;

    [[nodiscard]] constexpr Value get() const noexcept {
      return value_;
    }

    constexpr void set(Value value) const noexcept {
      value_ = value;
    }

    // The value, leaving the default in its place, as Cell::take.
    constexpr Value take() const noexcept {
      return std::exchange(value_, Value{});
    }

  private:
    mutable Value value_{};
  };

}

template <typename Value, std::size_t Count>
struct std::tuple_size<telar::ds::Array<Value, Count>> : std::integral_constant<std::size_t, Count> {};

template <std::size_t Index, typename Value, std::size_t Count>
struct std::tuple_element<Index, telar::ds::Array<Value, Count>> {
  using type = Value;
};
