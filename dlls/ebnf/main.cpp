#include "lexer.hpp"
#include "parser.hpp"
#include <unordered_map>

// Instantiates every parser member, so the lifetime check covers the library without test code.
template class ebnf::parser<ebnf::Lexer>;

class completion_database {

  std::unordered_map<std::string_view, ebnf::syntax_tree> db_{};
};

int main() {
  return 0;
}
