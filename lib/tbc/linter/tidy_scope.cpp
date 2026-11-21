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

#include <clang-tidy/ClangTidyCheck.h>
#include <clang-tidy/ClangTidyModule.h>
#include <clang/AST/ASTContext.h>
#include <clang/ASTMatchers/ASTMatchFinder.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Lex/Preprocessor.h>

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
      std::vector<clang::Decl*> parsed;

      for (auto* declaration : context.getTranslationUnitDecl()->noload_decls()) {
        if (!declaration->isFromASTFile() && !sources.isInSystemHeader(sources.getExpansionLoc(declaration->getLocation()))) {
          parsed.push_back(declaration);
        }
      }

      context.setTraversalScope(parsed);
    }

  private:
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
