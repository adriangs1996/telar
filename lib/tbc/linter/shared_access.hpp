#ifndef TBC_LINTER_SHARED_ACCESS_HPP
#define TBC_LINTER_SHARED_ACCESS_HPP

#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>

namespace tbc_lint {
  // Reports a mutation of an object reached through shared access: a const method's receiver or a
  // reference or pointer to const, followed through a field that refers to a non-const object or a
  // smart pointer's object. C++ const stops at the field; tbc's goes through it, as Rust's `&T` does,
  // because callers know a const method or a reference to const by its declaration, which lends shared
  // everything the object reaches. A shared type, a synchronization primitive and an opaque C handle
  // may change through shared access, as Rust's interior mutability and raw pointers do.
  void checkSharedAccess(const clang::FunctionDecl& definition, clang::ASTContext& context, bool errors);
}

#endif
