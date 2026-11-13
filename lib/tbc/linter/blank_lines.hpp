#ifndef TBC_LINTER_BLANK_LINES_HPP
#define TBC_LINTER_BLANK_LINES_HPP

#include <clang/ASTMatchers/ASTMatchFinder.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/DenseMap.h>
#include <llvm/ADT/DenseSet.h>
#include <llvm/ADT/StringMap.h>
#include <llvm/Support/Regex.h>
#include <llvm/Support/raw_ostream.h>

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace tbc_lint {
  // The blank lines every translation unit asks for, keyed by the file's real path and the offset of
  // the line that receives a blank line above it. Shared by the units checked in parallel, so that a
  // header included by several of them is reported and fixed once.
  class blank_line_fixes {
  public:
    // True when no other unit claimed this insertion first.
    bool claim(llvm::StringRef path, unsigned offset);

    // Inserts every claimed blank line. Returns false and explains why when a file cannot be written.
    bool apply(llvm::raw_ostream& errors) const;

  private:
    mutable std::mutex mutex_;
    llvm::StringMap<llvm::DenseSet<unsigned>> insertions_;
  };

  // Checks the blank lines that docs/code-style.md asks for between the statements of a block:
  // after a statement that ends on its own closing brace, and after a run of declarations.
  class blank_line_check final : public clang::ast_matchers::MatchFinder::MatchCallback {
  public:
    // Headers are checked only when their path matches header_filter; an empty filter checks main files only.
    blank_line_check(blank_line_fixes& fixes, bool errors, const std::string& header_filter);

    void registerMatchers(clang::ast_matchers::MatchFinder& finder);
    void run(const clang::ast_matchers::MatchFinder::MatchResult& result) override;
    void onEndOfTranslationUnit() override;

  private:
    enum class rule : std::uint8_t {
      after_block,
      after_declarations,
    };

    struct gap {
      clang::SourceLocation statement;
      clang::FileID file;
      unsigned insertion;
      rule kind;
    };

    bool selected(clang::FileID file, const clang::SourceManager& sources);
    void inspect(const clang::Stmt& previous, const clang::Stmt& next, const clang::SourceManager& sources);

    blank_line_fixes& fixes_;
    bool errors_;
    llvm::Regex header_filter_;
    bool filter_headers_;
    clang::ASTContext* context_ = nullptr;
    llvm::DenseMap<clang::FileID, bool> selected_;
    std::vector<gap> gaps_;
  };
}

#endif
