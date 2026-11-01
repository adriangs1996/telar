#include "lifetime_analysis.hpp"

#include <clang/ASTMatchers/ASTMatchFinder.h>
#include <clang/Tooling/ArgumentsAdjusters.h>
#include <clang/Tooling/CommonOptionsParser.h>
#include <clang/Tooling/Tooling.h>
#include <llvm/ADT/SmallPtrSet.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/raw_ostream.h>

#include <exception>

namespace {
  class borrow_check final : public clang::ast_matchers::MatchFinder::MatchCallback {
  public:
    explicit borrow_check(bool errors)
        : analysis_(errors) {}

    void run(const clang::ast_matchers::MatchFinder::MatchResult &result) override {
      if (result.Nodes.getNodeAs<clang::TranslationUnitDecl>("unit") != nullptr) {
        visited_.clear();
        context_ = result.Context;
        analysis_.beginTranslationUnit();
        return;
      }
      const auto *function = result.Nodes.getNodeAs<clang::FunctionDecl>("function");
      if (function != nullptr && visited_.insert(function->getCanonicalDecl()).second) {
        analysis_.analyze(*function, *result.Context);
      }
    }

    void onEndOfTranslationUnit() override {
      if (context_ != nullptr) {
        analysis_.finishTranslationUnit(*context_);
      }
    }

  private:
    clang::ASTContext *context_ = nullptr;
    tbc_lint::lifetime_analysis analysis_;
    llvm::SmallPtrSet<const clang::FunctionDecl *, 32> visited_;
  };
}

int main(int argc, const char **argv) try {
  llvm::cl::OptionCategory category("tbc-lint options");
  const llvm::cl::opt<bool> warnings_as_errors("warnings-as-errors", llvm::cl::desc("Report lifetime warnings as errors"), llvm::cl::cat(category));

  auto options = clang::tooling::CommonOptionsParser::create(argc, argv, category);
  if (!options) {
    llvm::errs() << options.takeError();
    return 2;
  }

  borrow_check check(warnings_as_errors);
  clang::ast_matchers::MatchFinder finder;
  finder.addMatcher(clang::ast_matchers::translationUnitDecl().bind("unit"), &check);
  finder.addMatcher(clang::ast_matchers::functionDecl(clang::ast_matchers::isDefinition(), clang::ast_matchers::unless(clang::ast_matchers::isExpansionInSystemHeader())).bind("function"), &check);

  clang::tooling::ClangTool tool(options->getCompilations(), options->getSourcePathList());
  tool.appendArgumentsAdjuster(clang::tooling::getInsertArgumentAdjuster("-resource-dir=" TBC_CLANG_RESOURCE_DIR, clang::tooling::ArgumentInsertPosition::END));
  return tool.run(clang::tooling::newFrontendActionFactory(&finder).get());
} catch (const std::exception &error) {
  llvm::errs() << "tbc-lint: " << error.what() << '\n';
  return 1;
} catch (...) {
  llvm::errs() << "tbc-lint: unknown exception\n";
  return 1;
}
