module;
#include "tbc/view.hpp"

export module telar.tbc;

// The declarations of tbc/view.hpp for module units, so that they import them instead of
// including the header and its standard library in each global module fragment. A module
// exports no macros: the annotations stay in tbc/annotations.hpp.
export namespace tbc {
  using tbc::raw;
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
