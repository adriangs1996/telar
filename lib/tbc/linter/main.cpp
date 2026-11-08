#include "lifetime_analysis.hpp"

#include <clang/ASTMatchers/ASTMatchFinder.h>
#include <clang/Basic/DiagnosticOptions.h>
#include <clang/Frontend/TextDiagnosticPrinter.h>
#include <clang/Tooling/ArgumentsAdjusters.h>
#include <clang/Tooling/CommonOptionsParser.h>
#include <clang/Tooling/Tooling.h>
#include <llvm/ADT/SmallPtrSet.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/ThreadPool.h>
#include <llvm/Support/VirtualFileSystem.h>
#include <llvm/Support/raw_ostream.h>

#include <atomic>
#include <exception>
#include <mutex>
#include <string>

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

  // Checks one translation unit with its own tool and analysis, so units can run on separate threads.
  // Its diagnostics are buffered, so that the output of parallel units never interleaves.
  int checkUnit(const clang::tooling::CompilationDatabase &compilations, const std::string &source, bool errors, bool colors, std::string &output) {
    borrow_check check(errors);
    clang::ast_matchers::MatchFinder finder;
    finder.addMatcher(clang::ast_matchers::translationUnitDecl().bind("unit"), &check);
    finder.addMatcher(clang::ast_matchers::functionDecl(clang::ast_matchers::isDefinition(), clang::ast_matchers::unless(clang::ast_matchers::isExpansionInSystemHeader())).bind("function"), &check);

    llvm::raw_string_ostream stream(output);
    clang::DiagnosticOptions options;
    options.setShowColors(colors ? clang::ShowColorsKind::On : clang::ShowColorsKind::Off);
    clang::TextDiagnosticPrinter printer(stream, options);
    // The process-wide file system changes the process's working directory for each compile command;
    // a physical one keeps its own, which concurrent units need.
    clang::tooling::ClangTool tool(compilations, {source}, std::make_shared<clang::PCHContainerOperations>(), llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(llvm::vfs::createPhysicalFileSystem().release()));
    tool.setDiagnosticConsumer(&printer);
    tool.appendArgumentsAdjuster(clang::tooling::getInsertArgumentAdjuster("-resource-dir=" TBC_CLANG_RESOURCE_DIR, clang::tooling::ArgumentInsertPosition::END));
    return tool.run(clang::tooling::newFrontendActionFactory(&finder).get());
  }
}

int main(int argc, const char **argv) try {
  llvm::cl::OptionCategory category("tbc-lint options");
  const llvm::cl::opt<bool> warnings_as_errors("warnings-as-errors", llvm::cl::desc("Report lifetime warnings as errors"), llvm::cl::cat(category));
  const llvm::cl::opt<unsigned> jobs("j", llvm::cl::desc("Translation units checked in parallel; 0 uses one per physical core"), llvm::cl::init(0), llvm::cl::cat(category));

  auto options = clang::tooling::CommonOptionsParser::create(argc, argv, category);
  if (!options) {
    llvm::errs() << options.takeError();
    return 2;
  }

  const auto &compilations = options->getCompilations();
  const auto &sources = options->getSourcePathList();
  const bool colors = llvm::errs().has_colors();
  std::mutex print;
  std::atomic<bool> failed = false;
  const auto check = [&](const std::string &source) {
    std::string output;
    const bool unit_failed = checkUnit(compilations, source, warnings_as_errors, colors, output) != 0;
    const std::scoped_lock lock(print);
    llvm::errs() << output;
    if (unit_failed) {
      failed = true;
    }
  };

  const auto strategy = llvm::heavyweight_hardware_concurrency(jobs);
  if (sources.size() <= 1 || strategy.compute_thread_count() <= 1) {
    for (const auto &source : sources) {
      check(source);
    }
  } else {
    llvm::DefaultThreadPool pool(strategy);
    for (const auto &source : sources) {
      pool.async([&check, &source] { check(source); });
    }
    pool.wait();
  }
  return failed ? 1 : 0;
} catch (const std::exception &error) {
  llvm::errs() << "tbc-lint: " << error.what() << '\n';
  return 1;
} catch (...) {
  llvm::errs() << "tbc-lint: unknown exception\n";
  return 1;
}
