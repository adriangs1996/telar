#include "lexer.hpp"
#include "parser.hpp"

// Instantiates every parser member, so the lifetime check covers the library without test code.
template class ebnf::parser<ebnf::Lexer>;

int main() {
  return 0;
}
