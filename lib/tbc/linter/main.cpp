#include "blank_lines.hpp"
#include "checked_definitions.hpp"
#include "const_overloads.hpp"
#include "interface_bodies.hpp"
#include "lifetime_analysis.hpp"
#include "shared_access.hpp"
#include "standard_containers.hpp"

#include <clang/AST/GlobalDecl.h>
#include <clang/AST/Mangle.h>
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
#include <llvm/Support/MemoryBuffer.h>
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
    borrow_check(bool errors, tbc_lint::checked_definitions& checked)
        : analysis_(errors),
          errors_(errors),
          checked_(checked) {}

    void run(const clang::ast_matchers::MatchFinder::MatchResult& result) override {
      if (result.Nodes.getNodeAs<clang::TranslationUnitDecl>("unit") != nullptr) {
        visited_.clear();
        context_ = result.Context;
        mangler_.reset(context_->createMangleContext());
        // A unit that does not compile has an invalid AST. The question is asked before any check of
        // this run reports, since a reported diagnostic counts as an error under --warnings-as-errors.
        compiled_ = !context_->getDiagnostics().hasUncompilableErrorOccurred();
        analysis_.beginTranslationUnit();
        return;
      }

      const auto* function = result.Nodes.getNodeAs<clang::FunctionDecl>("function");
      if (compiled_ && function != nullptr && visited_.insert(function->getCanonicalDecl()).second && claim(*function, *result.Context)) {
        analysis_.analyze(*function, *result.Context);
        if (const auto* definition = function->getDefinition()) {
          tbc_lint::checkSharedAccess(*definition, *result.Context, errors_);
        }
      }
    }

    void onEndOfTranslationUnit() override {
      if (context_ != nullptr && compiled_) {
        analysis_.finishTranslationUnit(*context_);
      }
    }

  private:
    // A unit checks every definition its own file holds, and a definition from a header or an
    // instantiation only when no other unit of the run has.
    bool claim(const clang::FunctionDecl& function, clang::ASTContext& context) {
      const auto& sources = context.getSourceManager();
      if (sources.isInMainFile(sources.getExpansionLoc(function.getLocation())) || !mangler_->shouldMangleDeclName(&function)) {
        return true;
      }

      clang::GlobalDecl global(&function);

      if (const auto* constructor = llvm::dyn_cast<clang::CXXConstructorDecl>(&function)) {
        global = clang::GlobalDecl(constructor, clang::Ctor_Complete);
      } else if (const auto* destructor = llvm::dyn_cast<clang::CXXDestructorDecl>(&function)) {
        global = clang::GlobalDecl(destructor, clang::Dtor_Complete);
      }

      std::string name;
      llvm::raw_string_ostream stream(name);

      mangler_->mangleName(global, stream);
      return checked_.claim(std::move(name));
    }

    clang::ASTContext* context_ = nullptr;
    bool compiled_ = false;
    std::unique_ptr<clang::MangleContext> mangler_;
    tbc_lint::lifetime_analysis analysis_;
    bool errors_;
    tbc_lint::checked_definitions& checked_;
    llvm::SmallPtrSet<const clang::FunctionDecl*, 32> visited_;
  };

  // Limits the matchers to what a unit parses itself outside system headers: its own file, the project
  // headers it includes and the template instantiations it performs. What a unit imports from a module
  // is checked with the unit that defines it, so the matchers never deserialize it, and the parents
  // the analysis asks for are those of this scope alone.
  class parsed_scope final : public clang::ASTConsumer {
  public:
    explicit parsed_scope(std::unique_ptr<clang::ASTConsumer> matchers)
        : matchers_(std::move(matchers)) {}

    void Initialize(clang::ASTContext& context) override {
      context_ = &context;
      matchers_->Initialize(context);
    }

    bool HandleTopLevelDecl(clang::DeclGroupRef group) override {
      const auto& sources = context_->getSourceManager();

      for (auto* declaration : group) {
        if (!sources.isInSystemHeader(sources.getExpansionLoc(declaration->getLocation()))) {
          declarations_.push_back(declaration);
        }
      }

      return matchers_->HandleTopLevelDecl(group);
    }

    // A declaration a module hands over as it is read, such as an inline function, belongs to the unit
    // that defines it.
    void HandleInterestingDecl(clang::DeclGroupRef group) override {
      matchers_->HandleInterestingDecl(group);
    }

    void HandleTranslationUnit(clang::ASTContext& context) override {
      context.setTraversalScope(declarations_);
      matchers_->HandleTranslationUnit(context);
    }

  private:
    clang::ASTContext* context_ = nullptr;
    std::unique_ptr<clang::ASTConsumer> matchers_;
    std::vector<clang::Decl*> declarations_;
  };

  enum class checker : std::uint8_t {
    lifetime,
    blank_lines,
    interface_bodies,
    standard_containers,
  };

  struct settings {
    bool lifetime;
    bool blank_lines;
    bool interface_bodies;
    bool standard_containers;
    bool errors;
    bool colors;
    std::string header_filter;
    tbc_lint::blank_line_fixes& fixes;
    tbc_lint::interface_modules& interfaces;
    tbc_lint::checked_definitions& checked;
    tbc_lint::container_allowlist& containers;
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
        consumers.push_back(std::make_unique<parsed_scope>(finder_->newASTConsumer()));
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
    std::optional<tbc_lint::const_overload_check> overloads;

    if (settings.lifetime) {
      borrows.emplace(settings.errors, settings.checked);
      finder.addMatcher(clang::ast_matchers::translationUnitDecl().bind("unit"), &*borrows);
      finder.addMatcher(clang::ast_matchers::functionDecl(clang::ast_matchers::isDefinition(), clang::ast_matchers::unless(clang::ast_matchers::isExpansionInSystemHeader())).bind("function"), &*borrows);
      overloads.emplace(settings.errors, settings.checked);
      overloads->registerMatchers(finder);
    }

    std::optional<tbc_lint::blank_line_check> blank_lines;

    if (settings.blank_lines) {
      blank_lines.emplace(settings.fixes, settings.errors, settings.header_filter);
      blank_lines->registerMatchers(finder);
    }

    std::optional<tbc_lint::standard_container_check> containers;

    if (settings.standard_containers) {
      containers.emplace(settings.errors, settings.checked, settings.containers);
      containers->registerMatchers(finder);
    }

    llvm::raw_string_ostream stream(output);
    clang::DiagnosticOptions options;

    options.setShowColors(settings.colors ? clang::ShowColorsKind::On : clang::ShowColorsKind::Off);
    clang::TextDiagnosticPrinter printer(stream, options);
    const auto tool = unitTool(compilations, source);

    tool->setDiagnosticConsumer(&printer);
    unit_actions actions(settings.lifetime || settings.blank_lines || settings.standard_containers ? &finder : nullptr, settings);

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
          clEnumValN(checker::interface_bodies, "interface-bodies", "Function bodies in module interface units"),
          clEnumValN(checker::standard_containers, "standard-containers", "Standard containers that telar::ds replaces")
      ),
      llvm::cl::CommaSeparated,
      llvm::cl::cat(category)
  );
  const llvm::cl::opt<bool> fix("fix", llvm::cl::desc("Insert the blank lines that blank-lines asks for"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> header_filter("header-filter", llvm::cl::desc("Regular expression for the headers blank-lines checks besides each main file"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> stamps("stamps", llvm::cl::desc("Directory where each checked unit leaves a stamp named after its source, '/' spelled '%': what it claimed and reported"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> replay("replay", llvm::cl::desc("File naming the sources, one per line, whose stamps are reported again instead of checking them"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> container_allowlist("standard-containers-allowlist", llvm::cl::desc("File naming the folders standard-containers still allows, one per line"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> interface_allowlist("interface-allowlist", llvm::cl::desc("File naming the modules interface-bodies allows to keep bodies, one per line"), llvm::cl::cat(category));

  // A run that only replays stamps checks no source.
  auto options = clang::tooling::CommonOptionsParser::create(argc, argv, category, llvm::cl::ZeroOrMore);
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

  const bool standard_containers = checks.isSet(checker::standard_containers);
  if (!container_allowlist.empty() && !standard_containers) {
    llvm::errs() << "tbc-lint: --standard-containers-allowlist needs --checks=standard-containers\n";
    return 2;
  }

  std::vector<std::string> folders;

  if (!container_allowlist.empty()) {
    auto read = tbc_lint::container_allowlist::read(container_allowlist);
    if (!read) {
      llvm::errs() << "tbc-lint: " << llvm::toString(read.takeError()) << '\n';
      return 2;
    }

    folders = std::move(*read);
  }

  tbc_lint::container_allowlist containers(folders);

  const auto& compilations = options->getCompilations();
  const auto& sources = options->getSourcePathList();
  const bool lifetime = checks.getBits() == 0 || checks.isSet(checker::lifetime);
  std::vector<std::size_t> order(sources.size());

  std::ranges::iota(order, 0);

  tbc_lint::blank_line_fixes fixes;
  tbc_lint::interface_modules interfaces(std::move(allowed));
  tbc_lint::checked_definitions checked;
  const settings configuration{
      .lifetime = lifetime,
      .blank_lines = blank_lines,
      .interface_bodies = interface_bodies,
      .standard_containers = standard_containers,
      .errors = warnings_as_errors,
      .colors = llvm::errs().has_colors(),
      .header_filter = header_filter,
      .fixes = fixes,
      .interfaces = interfaces,
      .checked = checked,
      .containers = containers,
  };

  std::mutex print;
  std::atomic<bool> failed = false;
  const auto stampOf = [&](std::string source) {
    std::ranges::replace(source, '/', '%');
    return stamps + "/" + source;
  };

  // A unit unchanged since its stamp reports what it reported then, and keeps what it claimed then.
  if (!replay.empty()) {
    auto listed = llvm::MemoryBuffer::getFile(replay, /*IsText=*/true);
    if (!listed) {
      llvm::errs() << "tbc-lint: cannot read " << replay << '\n';
      return 2;
    }

    llvm::SmallVector<llvm::StringRef, 256> lines;

    (*listed)->getBuffer().split(lines, '\n', -1, false);
    for (const auto source : lines) {
      auto stamp = llvm::MemoryBuffer::getFile(stampOf(source.str()), /*IsText=*/true);
      if (!stamp) {
        llvm::errs() << "tbc-lint: no stamp for " << source << '\n';
        return 2;
      }

      const auto [claims, output] = (*stamp)->getBuffer().split("output\n");
      llvm::SmallVector<llvm::StringRef, 16> names;

      claims.split(names, '\n', -1, false);
      for (auto line : names) {
        if (line.consume_front("claim ")) {
          checked.preclaim(line);
        } else if (line.consume_front("allow ")) {
          containers.replay(line);
        }
      }

      llvm::errs() << output;
      if (output.contains(": warning: ") || output.contains(": error: ")) {
        failed = true;
      }
    }
  }

  eachSource(order, jobs, [&](std::size_t index) {
    std::string output;
    std::vector<std::string> claimed;
    std::vector<std::string> allowed_uses;

    tbc_lint::checked_definitions::unit_claims = &claimed;
    tbc_lint::container_allowlist::unit_events = &allowed_uses;
    const bool unit_failed = checkUnit(compilations, sources[index], configuration, output) != 0;

    tbc_lint::checked_definitions::unit_claims = nullptr;
    tbc_lint::container_allowlist::unit_events = nullptr;
    const std::scoped_lock lock(print);

    llvm::errs() << output;
    if (unit_failed) {
      failed = true;
    }

    // A unit whose object and tbc-lint stay unchanged reports the same next time, so its stamp keeps
    // it, with the definitions it claimed for the run.
    if (!stamps.empty()) {
      std::error_code error;
      llvm::raw_fd_ostream stamp(stampOf(sources[index]), error);

      for (const auto& name : claimed) {
        stamp << "claim " << name << '\n';
      }

      for (const auto& event : allowed_uses) {
        stamp << "allow " << event << '\n';
      }

      stamp << "output\n" << output;
    }
  });

  if (fix && !fixes.apply(llvm::errs())) {
    return 1;
  }

  if (!interface_allowlist.empty() && interfaces.reportStale(llvm::errs(), warnings_as_errors, interface_allowlist) && warnings_as_errors) {
    return 1;
  }

  if (!container_allowlist.empty() && containers.reportStale(llvm::errs(), warnings_as_errors, container_allowlist) && warnings_as_errors) {
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
