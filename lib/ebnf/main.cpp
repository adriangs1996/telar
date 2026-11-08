#ifdef __clangd__
static_assert(true);
#endif
#include <tbc/view.hpp>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string_view>
#include <optional>
#include <utility>
#include <vector>


#include <unordered_map>

import telar.ebnf.lexer;
import telar.ebnf.parser;

// Instantiates every parser member, so the lifetime check covers the library without test code.
template class ebnf::parser<ebnf::Lexer>;

class completion_database {

  std::unordered_map<std::string_view, ebnf::syntax_tree> db_{};
};

int main() {
  return 0;
}
