#include "tbc/lifetime.hpp"

#include <gtest/gtest.h>
#include <type_traits>

namespace {
  struct first_scope;
  struct second_scope;
  using scope = tbc::lifetime<first_scope>;
  using other_scope = tbc::lifetime<second_scope>;
  using borrow_type = tbc::borrow<int, scope>;

  static_assert(__cplusplus > 202002L);
  static_assert(std::is_trivially_copyable_v<borrow_type>);
  static_assert(sizeof(borrow_type) == sizeof(int *));
  static_assert(!std::is_default_constructible_v<borrow_type>);
  static_assert(!std::is_constructible_v<borrow_type, int &&>);
  static_assert(!std::is_constructible_v<tbc::borrow<const int, scope>, int &&>);
  static_assert(!std::is_constructible_v<borrow_type, tbc::borrow<int, other_scope>>);
  static_assert(std::is_same_v<borrow_type::lifetime_type, scope>);

  TEST(lifetime, refersToTheOriginalObject) {
    int value = 7;
    const borrow_type borrowed(value);
    borrowed.get() = 9;
    EXPECT_EQ(value, 9);
    EXPECT_EQ(std::addressof(borrowed.get()), std::addressof(value));
  }

  TEST(lifetime, canBorrowAConstObject) {
    const int value = 7;
    const tbc::borrow<const int, scope> borrowed(value);
    static_assert(std::is_same_v<decltype(borrowed.get()), const int &>);
    EXPECT_EQ(borrowed.get(), 7);
  }

  TEST(lifetime, doesNotInvokeAnOverloadedAddressOperator) {
    struct value_type {
      value_type *operator&() {
        return nullptr;
      }
    } value;

    const tbc::borrow<value_type, scope> borrowed(value);
    EXPECT_EQ(std::addressof(borrowed.get()), std::addressof(value));
  }

  TEST(lifetime, supportsConstantEvaluation) {
    constexpr bool valid = [] {
      int value = 3;
      const borrow_type borrowed(value);
      borrowed.get() = 4;
      return value == 4;
    }();
    static_assert(valid);
    EXPECT_TRUE(valid);
  }
}
