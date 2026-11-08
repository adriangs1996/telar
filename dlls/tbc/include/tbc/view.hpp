#ifndef TBC_VIEW_HPP
#define TBC_VIEW_HPP

#include <type_traits>

namespace tbc {
  namespace detail {
    struct region_tag {};
  }

  namespace lt {
    struct elided : detail::region_tag {};

    struct a : detail::region_tag {};

    struct b : detail::region_tag {};

    struct c : detail::region_tag {};

    struct d : detail::region_tag {};

    // Storage that outlives every caller: string literals and objects with static storage
    // duration. Only results take it; the referent never depends on an argument or receiver.
    struct static_storage : detail::region_tag {};

    // A field that borrows only the object holding it, such as an allocator reference to a sibling
    // arena. Its borrows are internal to that object, so they never count as the object's borrows.
    // Like a raw pointer behind Rust's Pin, this is a promise: the checker only requires the object
    // to be neither copyable nor movable.
    struct self : detail::region_tag {};
  }

  namespace detail {
    template <typename region>
    concept lifetime_region = std::is_base_of_v<region_tag, region>;
  }

  // Region labels are scoped contract variables for the linter, not C++ type barriers.
  template <typename type, detail::lifetime_region region = lt::elided>
    requires(std::is_object_v<type> || std::is_reference_v<type>)
  using view = type;
}

#endif
