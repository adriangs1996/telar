#include "blank_lines.hpp"
#include "interface_bodies.hpp"
#include "lifetime_analysis.hpp"

#include <clang/ASTMatchers/ASTMatchFinder.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/DiagnosticOptions.h>
#include <clang/Frontend/FrontendAction.h>
#include <clang/Frontend/MultiplexConsumer.h>
#include <clang/Frontend/TextDiagnosticPrinter.h>
#include <clang/Tooling/ArgumentsAdjusters.h>
#include <clang/Tooling/CommonOptionsParser.h>
#include <clang/Tooling/Tooling.h>
#include <llvm/ADT/ArrayRef.h>
#include <llvm/ADT/SmallPtrSet.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/Regex.h>
#include <llvm/Support/ThreadPool.h>
#include <llvm/Support/VirtualFileSystem.h>
#include <llvm/Support/raw_ostream.h>

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <functional>
#include <memory>
#include <mutex>
#include <numeric>
#include <optional>
#include <string>
#include <vector>

namespace {
  class borrow_check final : public clang::ast_matchers::MatchFinder::MatchCallback {
  public:
    borrow_check(bool errors, const tbc_lint::summary_index* index)
        : analysis_(errors, index) {}

    explicit borrow_check(tbc_lint::unit_summaries& output)
        : analysis_(output) {}

    void run(const clang::ast_matchers::MatchFinder::MatchResult& result) override {
      if (result.Nodes.getNodeAs<clang::TranslationUnitDecl>("unit") != nullptr) {
        visited_.clear();
        context_ = result.Context;
        analysis_.beginTranslationUnit();
        return;
      }

      const auto* function = result.Nodes.getNodeAs<clang::FunctionDecl>("function");
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
    clang::ASTContext* context_ = nullptr;
    tbc_lint::lifetime_analysis analysis_;
    llvm::SmallPtrSet<const clang::FunctionDecl*, 32> visited_;
  };

  enum class checker : std::uint8_t {
    lifetime,
    blank_lines,
    interface_bodies,
  };

  struct settings {
    bool lifetime;
    bool blank_lines;
    bool interface_bodies;
    bool errors;
    bool colors;
    std::string header_filter;
    tbc_lint::blank_line_fixes& fixes;
    tbc_lint::interface_modules& interfaces;
    // What the functions of every checked unit invalidate; null with a single unit, which sees all it defines.
    const tbc_lint::summary_index* summaries;
  };

  // Runs the matchers of the lifetime and blank-lines checks, when there are any, after the
  // interface-bodies check, which walks only what the unit parsed before the matchers load the rest.
  class unit_action final : public clang::ASTFrontendAction {
  public:
    unit_action(clang::ast_matchers::MatchFinder* finder, const settings& settings)
        : finder_(finder),
          settings_(settings) {}

  protected:
    std::unique_ptr<clang::ASTConsumer> CreateASTConsumer(clang::CompilerInstance&, llvm::StringRef) override {
      std::vector<std::unique_ptr<clang::ASTConsumer>> consumers;

      if (settings_.interface_bodies) {
        consumers.push_back(std::make_unique<tbc_lint::interface_body_check>(settings_.interfaces, settings_.errors));
      }

      if (finder_ != nullptr) {
        consumers.push_back(finder_->newASTConsumer());
      }

      return std::make_unique<clang::MultiplexConsumer>(std::move(consumers));
    }

  private:
    clang::ast_matchers::MatchFinder* finder_;
    const settings& settings_;
  };

  class unit_actions final : public clang::tooling::FrontendActionFactory {
  public:
    unit_actions(clang::ast_matchers::MatchFinder* finder, const settings& settings)
        : finder_(finder),
          settings_(settings) {}

    std::unique_ptr<clang::FrontendAction> create() override {
      return std::make_unique<unit_action>(finder_, settings_);
    }

  private:
    clang::ast_matchers::MatchFinder* finder_;
    const settings& settings_;
  };

  // The process-wide file system changes the process's working directory for each compile command;
  // a physical one keeps its own, which concurrent units need.
  std::unique_ptr<clang::tooling::ClangTool> unitTool(const clang::tooling::CompilationDatabase& compilations, const std::string& source) {
    auto tool = std::make_unique<clang::tooling::ClangTool>(compilations, std::vector<std::string>{source}, std::make_shared<clang::PCHContainerOperations>(), llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(llvm::vfs::createPhysicalFileSystem().release()));

    tool->appendArgumentsAdjuster(clang::tooling::getInsertArgumentAdjuster("-resource-dir=" TBC_CLANG_RESOURCE_DIR, clang::tooling::ArgumentInsertPosition::END));
    return tool;
  }

  // Summarizes what the functions one translation unit defines invalidate. Its diagnostics are left to
  // the check that follows.
  void summarizeUnit(const clang::tooling::CompilationDatabase& compilations, const std::string& source, tbc_lint::unit_summaries& output) {
    clang::ast_matchers::MatchFinder finder;
    borrow_check summaries(output);

    finder.addMatcher(clang::ast_matchers::translationUnitDecl().bind("unit"), &summaries);
    finder.addMatcher(clang::ast_matchers::functionDecl(clang::ast_matchers::isDefinition(), clang::ast_matchers::unless(clang::ast_matchers::isExpansionInSystemHeader())).bind("function"), &summaries);

    clang::IgnoringDiagConsumer ignored;
    const auto tool = unitTool(compilations, source);

    tool->setDiagnosticConsumer(&ignored);
    tool->run(clang::tooling::newFrontendActionFactory(&finder).get());
  }

  // Runs one task per source, in the given order, in parallel unless one thread is all there is.
  template <typename task>
  void eachSource(llvm::ArrayRef<std::size_t> order, unsigned jobs, const task& run) {
    const auto strategy = llvm::heavyweight_hardware_concurrency(jobs);
    if (order.size() <= 1 || strategy.compute_thread_count() <= 1) {
      for (const auto index : order) {
        run(index);
      }

      return;
    }

    llvm::DefaultThreadPool pool(strategy);

    for (const auto index : order) {
      pool.async([&run, index] {
        run(index);
      });
    }

    pool.wait();
  }

  // Checks one translation unit with its own tool and analysis, so units can run on separate threads.
  // Its diagnostics are buffered, so that the output of parallel units never interleaves.
  int checkUnit(const clang::tooling::CompilationDatabase& compilations, const std::string& source, const settings& settings, std::string& output) {
    clang::ast_matchers::MatchFinder finder;
    std::optional<borrow_check> borrows;

    if (settings.lifetime) {
      borrows.emplace(settings.errors, settings.summaries);
      finder.addMatcher(clang::ast_matchers::translationUnitDecl().bind("unit"), &*borrows);
      finder.addMatcher(clang::ast_matchers::functionDecl(clang::ast_matchers::isDefinition(), clang::ast_matchers::unless(clang::ast_matchers::isExpansionInSystemHeader())).bind("function"), &*borrows);
    }

    std::optional<tbc_lint::blank_line_check> blank_lines;

    if (settings.blank_lines) {
      blank_lines.emplace(settings.fixes, settings.errors, settings.header_filter);
      blank_lines->registerMatchers(finder);
    }

    llvm::raw_string_ostream stream(output);
    clang::DiagnosticOptions options;

    options.setShowColors(settings.colors ? clang::ShowColorsKind::On : clang::ShowColorsKind::Off);
    clang::TextDiagnosticPrinter printer(stream, options);
    const auto tool = unitTool(compilations, source);

    tool->setDiagnosticConsumer(&printer);
    unit_actions actions(settings.lifetime || settings.blank_lines ? &finder : nullptr, settings);

    return tool->run(&actions);
  }
}

int main(int argc, const char** argv) try {
  llvm::cl::OptionCategory category("tbc-lint options");
  const llvm::cl::opt<bool> warnings_as_errors("warnings-as-errors", llvm::cl::desc("Report warnings as errors"), llvm::cl::cat(category));
  const llvm::cl::opt<unsigned> jobs("j", llvm::cl::desc("Translation units checked in parallel; 0 uses one per physical core"), llvm::cl::init(0), llvm::cl::cat(category));
  llvm::cl::bits<checker> checks(
      "checks",
      llvm::cl::desc("Comma-separated checks to run; lifetime when none is given"),
      llvm::cl::values(
          clEnumValN(checker::lifetime, "lifetime", "Borrow checking"),
          clEnumValN(checker::blank_lines, "blank-lines", "Blank lines between the statements of a block"),
          clEnumValN(checker::interface_bodies, "interface-bodies", "Function bodies in module interface units")
      ),
      llvm::cl::CommaSeparated,
      llvm::cl::cat(category)
  );
  const llvm::cl::opt<bool> fix("fix", llvm::cl::desc("Insert the blank lines that blank-lines asks for"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> header_filter("header-filter", llvm::cl::desc("Regular expression for the headers blank-lines checks besides each main file"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> interface_allowlist("interface-allowlist", llvm::cl::desc("File naming the modules interface-bodies allows to keep bodies, one per line"), llvm::cl::cat(category));

  auto options = clang::tooling::CommonOptionsParser::create(argc, argv, category);
  if (!options) {
    llvm::errs() << options.takeError();
    return 2;
  }

  const bool blank_lines = checks.isSet(checker::blank_lines);
  if (fix && !blank_lines) {
    llvm::errs() << "tbc-lint: --fix needs --checks=blank-lines\n";
    return 2;
  }

  if (std::string error; !header_filter.empty() && !llvm::Regex(header_filter).isValid(error)) {
    llvm::errs() << "tbc-lint: invalid --header-filter: " << error << '\n';
    return 2;
  }

  const bool interface_bodies = checks.isSet(checker::interface_bodies);
  if (!interface_allowlist.empty() && !interface_bodies) {
    llvm::errs() << "tbc-lint: --interface-allowlist needs --checks=interface-bodies\n";
    return 2;
  }

  llvm::StringSet<> allowed;

  if (!interface_allowlist.empty()) {
    auto modules = tbc_lint::readInterfaceAllowlist(interface_allowlist);
    if (!modules) {
      llvm::errs() << "tbc-lint: " << llvm::toString(modules.takeError()) << '\n';
      return 2;
    }

    allowed = std::move(*modules);
  }

  const auto& compilations = options->getCompilations();
  const auto& sources = options->getSourcePathList();
  const bool lifetime = checks.getBits() == 0 || checks.isSet(checker::lifetime);
  // A first pass summarizes what the functions each unit defines invalidate, once per unit, so that a
  // call into another unit is known by its body's effects rather than by its declaration alone.
  std::optional<tbc_lint::summary_index> summaries;
  std::vector<std::size_t> order(sources.size());

  std::ranges::iota(order, 0);
  if (lifetime && sources.size() > 1) {
    std::vector<tbc_lint::unit_summaries> units(sources.size());

    eachSource(order, jobs, [&](std::size_t index) {
      summarizeUnit(compilations, sources[index], units[index]);
    });

    summaries.emplace();
    for (const auto& unit : units) {
      summaries->add(unit);
    }

    // The units with the most definitions take longest to check, so they start first and the last
    // one to finish is a short one.
    std::ranges::stable_sort(order, std::greater{}, [&](std::size_t index) {
      return units[index].definitions();
    });
  }

  tbc_lint::blank_line_fixes fixes;
  tbc_lint::interface_modules interfaces(std::move(allowed));
  const settings configuration{
      .lifetime = lifetime,
      .blank_lines = blank_lines,
      .interface_bodies = interface_bodies,
      .errors = warnings_as_errors,
      .colors = llvm::errs().has_colors(),
      .header_filter = header_filter,
      .fixes = fixes,
      .interfaces = interfaces,
      .summaries = summaries ? &*summaries : nullptr,
  };

  std::mutex print;
  std::atomic<bool> failed = false;

  eachSource(order, jobs, [&](std::size_t index) {
    std::string output;
    const bool unit_failed = checkUnit(compilations, sources[index], configuration, output) != 0;
    const std::scoped_lock lock(print);

    llvm::errs() << output;
    if (unit_failed) {
      failed = true;
    }
  });

  if (fix && !fixes.apply(llvm::errs())) {
    return 1;
  }

  if (!interface_allowlist.empty() && interfaces.reportStale(llvm::errs(), warnings_as_errors, interface_allowlist) && warnings_as_errors) {
    return 1;
  }

  return failed ? 1 : 0;
} catch (const std::exception& error) {
  llvm::errs() << "tbc-lint: " << error.what() << '\n';
  return 1;
} catch (...) {
  llvm::errs() << "tbc-lint: unknown exception\n";
  return 1;
}
