#include "tbc/view.hpp"

#include <string>
#include <string_view>

using text_a = tbc::view<std::string_view, tbc::lt::a>;

text_a longerText(text_a first, text_a second) {
  return first.size() > second.size() ? first : second;
}

int main() try {
  const std::string first{"short"};
  const std::string second{"a longer string"};
  const auto selected = longerText(first, second);
  return selected == second ? 0 : 1;
} catch (...) {
  return 1;
}
