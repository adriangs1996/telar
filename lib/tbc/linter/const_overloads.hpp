#ifndef TBC_LINTER_CONST_OVERLOADS_HPP
#define TBC_LINTER_CONST_OVERLOADS_HPP

#include "checked_definitions.hpp"

#include <clang/ASTMatchers/ASTMatchFinder.h>

namespace tbc_lint {
  // The const method a non-const one overloads on constness alone, if its class declares one.
  const clang::CXXMethodDecl* constOverload(const clang::CXXMethodDecl& method);

  // Reports a class that overloads a method on constness. C++ picks the non-const overload by the
  // object's constness rather than by its use, so a read through a non-const object would lend it
  // exclusively; a read is a const method, and mutable access has a name of its own, as Rust's `get`
  // and `get_mut`.
  class const_overload_check final : public clang::ast_matchers::MatchFinder::MatchCallback {
  public:
    const_overload_check(bool errors, checked_definitions& checked);

    void registerMatchers(clang::ast_matchers::MatchFinder& finder);
    void run(const clang::ast_matchers::MatchFinder::MatchResult& result) override;

  private:
    bool errors_;
    checked_definitions& checked_;
  };
}

#endif
