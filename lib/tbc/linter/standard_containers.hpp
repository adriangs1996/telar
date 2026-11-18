#ifndef TBC_LINTER_STANDARD_CONTAINERS_HPP
#define TBC_LINTER_STANDARD_CONTAINERS_HPP

#include "checked_definitions.hpp"

#include <clang/ASTMatchers/ASTMatchFinder.h>
#include <llvm/ADT/DenseSet.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/raw_ostream.h>

#include <mutex>
#include <string>
#include <vector>

namespace tbc_lint {
  // The folders and files still allowed to use the containers telar::ds replaces, one path from the
  // repository root per line: a folder ends in a slash, as `src/gui/`. Blank lines and lines that
  // start with # are ignored. An entry stays while its migration lasts.
  class container_allowlist {
  public:
    static llvm::Expected<std::vector<std::string>> read(llvm::StringRef path);

    explicit container_allowlist(const std::vector<std::string>& folders);

    // Whether a file may use them, which counts as a use of the folder that allows it.
    [[nodiscard]] bool allowed(llvm::StringRef file);

    // Records that a checked unit's own file lies in an allowed folder, so that a folder whose
    // checked files use none of them can be reported.
    void seen(llvm::StringRef file);

    // Reports each folder that was checked and used none of them. Returns whether there was one.
    bool reportStale(llvm::raw_ostream& output, bool errors, llvm::StringRef path) const;

    // Applies what a unit recorded, `seen <file>` or `used <file>`, when its stamp is replayed.
    void replay(llvm::StringRef event);

    // What the unit the calling thread checks records, which its stamp keeps; a unit is checked on
    // one thread from start to end.
    static inline thread_local std::vector<std::string>* unit_events = nullptr;

  private:
    struct folder {
      std::string path;
      bool seen = false;
      bool used = false;
    };

    [[nodiscard]] folder* match(llvm::StringRef file);

    mutable std::mutex mutex_;
    std::vector<folder> folders_;
  };

  // Reports a type that names a container telar::ds replaces: std::vector, std::array, std::optional,
  // std::basic_string, std::map and std::unordered_map, std::function, and a C array. telar's own
  // containers follow the rules tbc checks; the standard ones overload their accessors on constness.
  class standard_container_check final : public clang::ast_matchers::MatchFinder::MatchCallback {
  public:
    standard_container_check(bool errors, checked_definitions& checked, container_allowlist& allowlist);

    void registerMatchers(clang::ast_matchers::MatchFinder& finder);
    void run(const clang::ast_matchers::MatchFinder::MatchResult& result) override;

  private:
    bool errors_;
    checked_definitions& checked_;
    container_allowlist& allowlist_;
    llvm::DenseSet<clang::SourceLocation::UIntTy> reported_;
  };
}

#endif
