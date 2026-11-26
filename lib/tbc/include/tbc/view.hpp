#ifndef TBC_VIEW_HPP
#define TBC_VIEW_HPP

// Module units import these declarations from telar.tbc and include tbc/annotations.hpp for
// the macros; this header is for code that cannot import.
#include "tbc/annotations.hpp"

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

  template <typename type>
  TBC_RAW constexpr type* raw(type* pointer) noexcept {
    return pointer;
  }

  // Region labels are scoped contract variables for the linter, not C++ type barriers.
  // An optional second region names what a referent holds separately from the outer borrow, as Rust's
  // `&'outer Stream<'inner>` does.
  template <typename type, detail::lifetime_region region = lt::elided, detail::lifetime_region inner = lt::elided>
    requires(std::is_object_v<type> || std::is_reference_v<type>)
  using view = type;

  // Directional outlives bound (`longer: shorter`) for template `requires` clauses.
  template <typename longer, typename shorter>
  concept outlives = detail::lifetime_region<longer> && detail::lifetime_region<shorter>;

  // A reference whose referent holds borrows of `region`, the reference itself lent for the call
  // alone, as Rust's `&Pane<'a>`: a result or a holder in `region` takes what the referent holds,
  // never the referent.
  template <typename type, detail::lifetime_region region>
    requires std::is_reference_v<type>
  using holds = type;

  // Shorthands of view for each region r, after Rust: ref_r<T> is `&'r T`, mut_r<T> is
  // `&'r mut T`, and val_r<T> a value of T that holds borrows of r, as a string_view or a span.
  // An elided contract stays tbc::view<T>, and tbc::holds has no shorthand.
  template <typename type>
  using ref_a = view<const type&, lt::a>;

  template <typename type>
  using mut_a = view<type&, lt::a>;

  template <typename type>
  using val_a = view<type, lt::a>;

  template <typename type>
  using ref_b = view<const type&, lt::b>;

  template <typename type>
  using mut_b = view<type&, lt::b>;

  template <typename type>
  using val_b = view<type, lt::b>;

  template <typename type>
  using ref_c = view<const type&, lt::c>;

  template <typename type>
  using mut_c = view<type&, lt::c>;

  template <typename type>
  using val_c = view<type, lt::c>;

  template <typename type>
  using ref_d = view<const type&, lt::d>;

  template <typename type>
  using mut_d = view<type&, lt::d>;

  template <typename type>
  using val_d = view<type, lt::d>;

  template <typename type>
  using ref_static = view<const type&, lt::static_storage>;

  template <typename type>
  using mut_static = view<type&, lt::static_storage>;

  template <typename type>
  using val_static = view<type, lt::static_storage>;

  template <typename type>
  using ref_self = view<const type&, lt::self>;

  template <typename type>
  using mut_self = view<type&, lt::self>;

  template <typename type>
  using val_self = view<type, lt::self>;
}

#endif
