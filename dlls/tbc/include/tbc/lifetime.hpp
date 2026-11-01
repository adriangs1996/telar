#ifndef TBC_LIFETIME_HPP
#define TBC_LIFETIME_HPP

#include "tbc/detail/attributes.hpp"
#include "tbc/view.hpp"

#include <memory>

namespace tbc {
  template <typename tag>
  struct lifetime : detail::region_tag {};

  // scope is a nominal tag, not proof that the referent is still alive.
  template <typename type, typename scope>
  class borrow {
  public:
    using value_type = type;
    using lifetime_type = scope;

    explicit constexpr borrow(type &value TBC_DETAIL_LIFETIME_BOUND) noexcept
        : value_(std::addressof(value)) {}

    borrow(type &&) = delete;

    [[nodiscard]] constexpr type &get() const noexcept {
      return *value_;
    }

  private:
    type *value_;
  };
}

#endif
