#ifndef TBC_LINTER_LIFETIME_ANALYSIS_HPP
#define TBC_LINTER_LIFETIME_ANALYSIS_HPP

#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>
#include <llvm/ADT/DenseSet.h>

#include <cstdint>
#include <memory>

namespace tbc_lint {
  class lifetime_analysis {
  public:
    explicit lifetime_analysis(bool errors);
    ~lifetime_analysis();
    void beginTranslationUnit();
    void analyze(const clang::FunctionDecl &function, clang::ASTContext &context);
    void finishTranslationUnit(clang::ASTContext &context);

  private:
    struct implementation;
    std::unique_ptr<implementation> implementation_;
    bool errors_;
    llvm::DenseSet<std::uint64_t> reported_;
  };
}

#endif
