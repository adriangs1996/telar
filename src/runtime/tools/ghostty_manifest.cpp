#include <cstdio>
#include <ghostty/vt.h>

int main() {
  return std::puts(ghostty_type_json()) < 0 ? 1 : 0;
}
