#include "tbc/view.hpp"

using int_view = tbc::view<int &, tbc::lt::a>;

int global_value = 1;

int_view fromReference(int_view value) {
  return value;
}

int_view fromStatic() {
  static int value = 1;
  return value;
}

int_view fromGlobal() {
  return global_value;
}

int unrelated() {
  int value = 1;
  return value;
}
