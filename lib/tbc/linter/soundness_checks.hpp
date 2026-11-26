#ifndef TBC_LINTER_SOUNDNESS_CHECKS_HPP
#define TBC_LINTER_SOUNDNESS_CHECKS_HPP

#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>
#include <clang/AST/DeclCXX.h>

namespace tbc_lint {
  // Checks that all redeclarations of a function agree on explicit tbc::view region contracts.
  void checkRedeclarationSoundness(const clang::FunctionDecl& function, clang::ASTContext& context, bool errors);

  // Checks soundness invariants needed for Rust-grade aliasing and immutability guarantees:
  // conflicting redeclaration contracts, unaudited const_cast, and unsynchronized mutable globals.
  void checkFunctionSoundness(const clang::FunctionDecl& function, clang::ASTContext& context, bool errors);

  // Checks that non-TBC_SHARED project records declare no `mutable` fields except synchronization
  // primitives or TBC_SHARED types (preserving Rust's `Freeze` boundary).
  void checkRecordSoundness(const clang::CXXRecordDecl& record, clang::ASTContext& context, bool errors);
}

#endif
