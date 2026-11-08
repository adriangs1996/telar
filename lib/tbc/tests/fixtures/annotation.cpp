#include "tbc/view.hpp"

using int_view = tbc::view<const int &, tbc::lt::a>;

int_view annotated() {
  int value = 1;
  return value;
}

const int &unannotated() {
  int value = 1;
  return value;
}
