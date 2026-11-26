module;
#include "tbc/view.hpp"

export module telar.tbc;

// The declarations of tbc/view.hpp for module units, so that they import them instead of
// including headers in each global module fragment.
export namespace tbc {
  using tbc::holds;
  using tbc::mut_a;
  using tbc::mut_b;
  using tbc::mut_c;
  using tbc::mut_d;
  using tbc::mut_self;
  using tbc::mut_static;
  using tbc::outlives;
  using tbc::raw;
  using tbc::ref_a;
  using tbc::ref_b;
  using tbc::ref_c;
  using tbc::ref_d;
  using tbc::ref_self;
  using tbc::ref_static;
  using tbc::val_a;
  using tbc::val_b;
  using tbc::val_c;
  using tbc::val_d;
  using tbc::val_self;
  using tbc::val_static;
  using tbc::view;
}

export namespace tbc::lt {
  using tbc::lt::a;
  using tbc::lt::b;
  using tbc::lt::c;
  using tbc::lt::d;
  using tbc::lt::elided;
  using tbc::lt::self;
  using tbc::lt::static_storage;
}
