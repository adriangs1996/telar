#ifndef TBC_LINTER_ACCESS_VALIDITY_HPP
#define TBC_LINTER_ACCESS_VALIDITY_HPP

#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>
#include <clang/Analysis/CFG.h>
#include <llvm/ADT/DenseSet.h>

#include <cstdint>

namespace tbc_lint {
  struct access_options {
    bool errors = false;
    bool check_bounds = true;
  };

  // Path-sensitive CFG checks for pointer nullability (`tbc-nullable-dereference`),
  // container/span indexing bounds (`tbc-unproven-bounds`), and definite initialization
  // (`tbc-uninitialized-read`), reusing the CFG already built for lifetime analysis.
  void checkAccessValidity(
      const clang::FunctionDecl& definition,
      const clang::CFG& graph,
      clang::ASTContext& context,
      access_options options,
      llvm::DenseSet<std::uint64_t>& reported
  );
}

#endif
