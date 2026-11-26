#ifndef TBC_LINTER_EXCLUSIVE_BORROWS_HPP
#define TBC_LINTER_EXCLUSIVE_BORROWS_HPP

#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>
#include <clang/Analysis/CFG.h>
#include <llvm/ADT/DenseSet.h>

#include <cstdint>

namespace tbc_lint {
  // Enforces Rust-style local exclusive aliasing (with NLL backward liveness, derived reborrows,
  // two-phase method borrows, and disjoint-field granularity) and use-after-move / partial moves
  // over the CFG already constructed for lifetime analysis.
  void checkExclusiveBorrowsAndMoves(
      const clang::FunctionDecl& definition,
      const clang::CFG& graph,
      clang::ASTContext& context,
      bool errors,
      llvm::DenseSet<std::uint64_t>& reported
  );
}

#endif
