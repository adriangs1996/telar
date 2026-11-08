#include "tbc/view.hpp"

using int_view = tbc::view<const int &, tbc::lt::a>;

int_view fromLocal() {
  int value = 1;
  return value;
}

int_view fromValue(int value) {
  return value;
}

int_view parenthesized() {
  int value = 1;
  return (value);
}
