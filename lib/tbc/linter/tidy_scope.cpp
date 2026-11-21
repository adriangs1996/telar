// A clang-tidy plugin, loaded with --load, with one check: tbc-parsed-scope. It reports nothing. It
// limits what the other checks traverse to what the unit parses itself outside system headers, as
// tbc-lint's parsed_scope does for its own checks.
//
// A check that asks for a node's parents, or walks the unit with a visitor of its own, makes clang
// read every declaration of every module the unit imports, the standard library's among them. What
// a unit imports is checked with the unit that defines it, so reading it only costs time: a second
// rather than a few hundredths for a unit of twenty lines, and several times its memory.
//
// A precompiled header is read the same way a module is, so the checks skip what it declares: one
// that held a project's own headers would leave them unchecked.
//
// A header a unit includes is parsed by every unit that includes it, and checked by each of them. A
// run that gives each header to one unit names, in TBC_PARSED_SCOPE_HEADERS, a file that lists the
// headers this unit checks besides its own file, one real path per line. The unit then leaves the
// other headers to the units that have them. Without the variable it checks every header it parses.

#include <clang-tidy/ClangTidyCheck.h>
#include <clang-tidy/ClangTidyModule.h>
#include <clang/AST/ASTContext.h>
#include <clang/ASTMatchers/ASTMatchFinder.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Lex/Preprocessor.h>
#include <llvm/ADT/StringSet.h>
#include <llvm/Support/MemoryBuffer.h>

#include <cstdlib>
#include <optional>
#include <vector>

namespace {
  class parsed_scope_check final : public clang::tidy::ClangTidyCheck {
  public:
    using ClangTidyCheck::ClangTidyCheck;

    void registerPPCallbacks(const clang::SourceManager& /*sources*/, clang::Preprocessor* preprocessor, clang::Preprocessor* /*expander*/) override {
      preprocessor_ = preprocessor;
    }

    // The matcher is what makes clang-tidy call onStartOfTranslationUnit for this check.
    void registerMatchers(clang::ast_matchers::MatchFinder* finder) override {
      finder->addMatcher(clang::ast_matchers::translationUnitDecl(), this);
    }

    // Before any check sees a node, which is when clang-tidy hands a check nothing of the unit but
    // the preprocessor: the one of a compilation loads modules through the compiler that owns it.
    void onStartOfTranslationUnit() override {
      if (preprocessor_ == nullptr) {
        return;
      }

      auto& compiler = static_cast<clang::CompilerInstance&>(preprocessor_->getModuleLoader());
      auto& context = compiler.getASTContext();
      const auto& sources = context.getSourceManager();
      const auto headers = ownedHeaders();
      std::vector<clang::Decl*> parsed;

      for (auto* declaration : context.getTranslationUnitDecl()->noload_decls()) {
        const auto place = sources.getExpansionLoc(declaration->getLocation());
        if (!declaration->isFromASTFile() && !sources.isInSystemHeader(place) && (!headers || owned(*headers, sources, place))) {
          parsed.push_back(declaration);
        }
      }

      context.setTraversalScope(parsed);
    }

  private:
    // The headers the run gave this unit, or nothing when the run gives headers to no unit.
    static std::optional<llvm::StringSet<>> ownedHeaders() {
      const char* list = std::getenv("TBC_PARSED_SCOPE_HEADERS");
      if (list == nullptr) {
        return std::nullopt;
      }

      // A list that cannot be read leaves the unit every header it parses: checking one twice costs
      // time, and checking none of them would pass for a clean unit.
      auto listed = llvm::MemoryBuffer::getFile(list, /*IsText=*/true);
      if (!listed) {
        return std::nullopt;
      }

      llvm::StringSet<> headers;
      llvm::SmallVector<llvm::StringRef, 64> lines;

      (*listed)->getBuffer().split(lines, '\n', -1, false);
      for (const auto line : lines) {
        headers.insert(line);
      }

      return headers;
    }

    // Whether a declaration at `place` is the unit's to check: in its own file, in a header the run
    // gave it, or nowhere a file names, as what the compiler declares by itself.
    static bool owned(const llvm::StringSet<>& headers, const clang::SourceManager& sources, clang::SourceLocation place) {
      if (place.isInvalid() || sources.isInMainFile(place)) {
        return true;
      }

      const auto file = sources.getFileEntryRefForID(sources.getFileID(place));
      if (!file) {
        return true;
      }

      const auto real = file->getFileEntry().tryGetRealPathName();

      return headers.contains(real.empty() ? file->getName() : real);
    }

    clang::Preprocessor* preprocessor_ = nullptr;
  };

  class tbc_module final : public clang::tidy::ClangTidyModule {
  public:
    void addCheckFactories(clang::tidy::ClangTidyCheckFactories& factories) override {
      factories.registerCheck<parsed_scope_check>("tbc-parsed-scope");
    }
  };

  // clang-tidy finds a plugin's module through this registration, which is a static object by design.
  // NOLINTNEXTLINE(bugprone-throwing-static-initialization)
  const clang::tidy::ClangTidyModuleRegistry::Add<tbc_module> registration("tbc-module", "Limits the checks to what a unit parses itself.");
}
