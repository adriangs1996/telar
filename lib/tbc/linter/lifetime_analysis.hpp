#ifndef TBC_LINTER_LIFETIME_ANALYSIS_HPP
#define TBC_LINTER_LIFETIME_ANALYSIS_HPP

#include <clang/AST/ASTContext.h>
#include <clang/AST/Decl.h>
#include <llvm/ADT/DenseSet.h>

#include <cstddef>
#include <cstdint>
#include <memory>

namespace tbc_lint {
  // What the functions one translation unit defines can invalidate, keyed by linkage name, so that a
  // unit that sees only their declarations can read them.
  class unit_summaries {
  public:
    unit_summaries();
    ~unit_summaries();
    unit_summaries(unit_summaries&&) noexcept;
    unit_summaries& operator=(unit_summaries&&) noexcept;
    // How many definitions the unit holds, which is about how long checking it takes.
    [[nodiscard]] std::size_t definitions() const;

  private:
    friend class lifetime_analysis;
    friend class summary_index;
    struct implementation;
    std::unique_ptr<implementation> implementation_;
  };

  // The summaries of every unit, read concurrently once they are all added.
  class summary_index {
  public:
    summary_index();
    ~summary_index();
    // A function that several units define, such as an inline one, invalidates what any of them does.
    void add(const unit_summaries& unit);

  private:
    friend class lifetime_analysis;
    struct implementation;
    std::unique_ptr<implementation> implementation_;
  };

  class lifetime_analysis {
  public:
    // Checks each unit, reading what a callee defined in another unit invalidates from the index.
    lifetime_analysis(bool errors, const summary_index* index);
    // Summarizes the functions each unit defines into the output, without diagnostics.
    explicit lifetime_analysis(unit_summaries& output);
    ~lifetime_analysis();
    void beginTranslationUnit();
    void analyze(const clang::FunctionDecl& function, clang::ASTContext& context);
    void finishTranslationUnit(clang::ASTContext& context);

  private:
    void add(const clang::FunctionDecl& definition, clang::ASTContext& context);
    void exportSummaries(clang::ASTContext& context, unit_summaries::implementation& output);

    struct implementation;
    std::unique_ptr<implementation> implementation_;
    bool errors_;
    llvm::DenseSet<std::uint64_t> reported_;
  };
}

#endif
