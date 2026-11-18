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
    // Checks each unit on its own: a call into a function another unit defines is known by its
    // declaration, as every call is.
    explicit lifetime_analysis(bool errors);
    ~lifetime_analysis();
    void beginTranslationUnit();
    void analyze(const clang::FunctionDecl& function, clang::ASTContext& context);
    void finishTranslationUnit(clang::ASTContext& context);

  private:
    void add(const clang::FunctionDecl& definition, clang::ASTContext& context);

    struct implementation;
    std::unique_ptr<implementation> implementation_;
    bool errors_;
    llvm::DenseSet<std::uint64_t> reported_;
  };
}

#endif
