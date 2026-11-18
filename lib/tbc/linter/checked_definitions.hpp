#ifndef TBC_LINTER_CHECKED_DEFINITIONS_HPP
#define TBC_LINTER_CHECKED_DEFINITIONS_HPP

#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/StringSet.h>

#include <mutex>
#include <string>
#include <vector>

namespace tbc_lint {
  // The definitions outside its own file that some unit of the run already checks: those of headers and
  // the instantiations of templates, which every unit that includes or instantiates them sees alike.
  class checked_definitions {
  public:
    // Whether this unit is the first of the run to claim a definition, by a name every unit agrees on.
    bool claim(std::string name) {
      const std::scoped_lock lock(mutex_);
      const bool first = names_.insert(name).second;

      if (first && unit_claims != nullptr) {
        unit_claims->push_back(std::move(name));
      }

      return first;
    }

    // Registers what a unit claimed in an earlier run whose report is replayed, so that no unit checked
    // now reports it again.
    void preclaim(llvm::StringRef name) {
      const std::scoped_lock lock(mutex_);

      names_.insert(name);
    }

    // The claims of the unit the calling thread checks, which its stamp keeps; a unit is checked on
    // one thread from start to end.
    static inline thread_local std::vector<std::string>* unit_claims = nullptr;

    // A place in a file every unit spells the same, whatever path included the file.
    static std::string place(const clang::SourceManager& sources, clang::SourceLocation location) {
      const auto file = sources.getFileEntryRefForID(sources.getFileID(location));
      const auto path = file ? file->getFileEntry().tryGetRealPathName() : llvm::StringRef{};

      return (path.empty() ? sources.getFilename(location) : path).str() + ":" + std::to_string(sources.getFileOffset(location));
    }

  private:
    std::mutex mutex_;
    llvm::StringSet<> names_;
  };
}

#endif
