#ifndef TBC_LINTER_LIFETIME_ANALYSIS_HPP
#define TBC_LINTER_LIFETIME_ANALYSIS_HPP

#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>
#include <llvm/ADT/DenseSet.h>

#include <cstdint>
#include <memory>

namespace tbc_lint {
  struct lifetime_options {
    bool errors = false;
    bool check_lifetime = true;
    bool check_bounds = true;
  };

  class lifetime_analysis {
  public:
    // Checks each unit on its own: a call into a function another unit defines is known by its
    // declaration, as every call is.
    explicit lifetime_analysis(lifetime_options options);
    ~lifetime_analysis();
    void beginTranslationUnit();
    void analyze(const clang::FunctionDecl& function, clang::ASTContext& context);
    void finishTranslationUnit(clang::ASTContext& context);

  private:
    void add(const clang::FunctionDecl& definition, clang::ASTContext& context);

    struct implementation;
    std::unique_ptr<implementation> implementation_;
    bool errors_;
    bool check_lifetime_;
    bool check_bounds_;
    llvm::DenseSet<std::uint64_t> reported_;
  };
}

#endif
