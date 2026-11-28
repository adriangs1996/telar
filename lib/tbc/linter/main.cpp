#include "attributes.hpp"
#include "blank_lines.hpp"
#include "checked_definitions.hpp"
#include "interface_bodies.hpp"
#include "pipeline.hpp"
#include "standard_containers.hpp"

#include <clang/Basic/DiagnosticOptions.h>
#include <clang/Frontend/FrontendAction.h>
#include <clang/Frontend/TextDiagnosticPrinter.h>
#include <clang/Tooling/ArgumentsAdjusters.h>
#include <clang/Tooling/CommonOptionsParser.h>
#include <clang/Tooling/Tooling.h>
#include <llvm/ADT/ArrayRef.h>
#include <llvm/ADT/StringSet.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Regex.h>
#include <llvm/Support/ThreadPool.h>
#include <llvm/Support/VirtualFileSystem.h>
#include <llvm/Support/raw_ostream.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <exception>
#include <memory>
#include <mutex>
#include <numeric>
#include <optional>
#include <string>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/resource.h>
#endif

namespace {
  using checker = tbc_lint::checker_kind;

  struct settings {
    bool lifetime;
    bool bounds;
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

  class unit_action final : public clang::ASTFrontendAction {
  public:
    explicit unit_action(tbc_lint::unit_pipeline& pipeline)
        : pipeline_(pipeline) {}

  protected:
    std::unique_ptr<clang::ASTConsumer> CreateASTConsumer(clang::CompilerInstance&, llvm::StringRef) override {
      return pipeline_.createConsumer();
    }

  private:
    tbc_lint::unit_pipeline& pipeline_;
  };

  class unit_actions final : public clang::tooling::FrontendActionFactory {
  public:
    explicit unit_actions(tbc_lint::unit_pipeline& pipeline)
        : pipeline_(pipeline) {}

    std::unique_ptr<clang::FrontendAction> create() override {
      return std::make_unique<unit_action>(pipeline_);
    }

  private:
    tbc_lint::unit_pipeline& pipeline_;
  };

  // Strips compiler plugin flags that load tbc-plugin or telar-qt-plugin, because tbc-lint
  // registers tbc's custom attributes itself and does not execute compiler plugins.
  clang::tooling::CommandLineArguments stripTbcPluginFlags(const clang::tooling::CommandLineArguments& arguments, llvm::StringRef /*filename*/) {
    clang::tooling::CommandLineArguments filtered;
    bool stripped_qt_plugin = false;

    filtered.reserve(arguments.size() + 1);
    for (std::size_t index = 0; index < arguments.size(); ++index) {
      const llvm::StringRef arg(arguments[index]);

      if (arg.starts_with("-fplugin=") && arg.contains("tbc-plugin")) {
        continue;
      }

      if (arg.starts_with("-fplugin=") && arg.contains("telar-qt-plugin")) {
        stripped_qt_plugin = true;
        continue;
      }

      if (arg.starts_with("-fplugin-arg-tbc-")) {
        continue;
      }

      if (arg == "-Xclang" && index + 1 < arguments.size()) {
        const llvm::StringRef next(arguments[index + 1]);
        if ((next == "-load" || next == "-plugin" || next == "-add-plugin" || next == "-plugin-arg-tbc") && index + 2 < arguments.size()) {
          const llvm::StringRef value(arguments[index + 2]);
          if (value == "tbc" || value.contains("tbc-plugin") || next == "-plugin-arg-tbc") {
            index += 2;
            continue;
          }
        }
      }

      filtered.push_back(arguments[index]);
    }

    if (stripped_qt_plugin) {
      filtered.emplace_back("-Wno-unknown-attributes");
    }

    return filtered;
  }

  // The process-wide file system changes the process's working directory for each compile command;
  // a physical one keeps its own, which concurrent units need.
  std::unique_ptr<clang::tooling::ClangTool> unitTool(const clang::tooling::CompilationDatabase& compilations, const std::string& source) {
    auto tool = std::make_unique<clang::tooling::ClangTool>(compilations, std::vector<std::string>{source}, std::make_shared<clang::PCHContainerOperations>(), llvm::IntrusiveRefCntPtr<llvm::vfs::FileSystem>(llvm::vfs::createPhysicalFileSystem().release()));

    tool->appendArgumentsAdjuster(stripTbcPluginFlags);
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
    const tbc_lint::pipeline_settings pipeline_config{
        .lifetime = settings.lifetime,
        .bounds = settings.bounds,
        .blank_lines = settings.blank_lines,
        .interface_bodies = settings.interface_bodies,
        .standard_containers = settings.standard_containers,
        .errors = settings.errors,
        .header_filter = settings.header_filter,
        .fixes = &settings.fixes,
        .interfaces = &settings.interfaces,
        .checked = &settings.checked,
        .containers = &settings.containers,
    };

    tbc_lint::unit_pipeline pipeline(pipeline_config);
    llvm::raw_string_ostream stream(output);
    clang::DiagnosticOptions options;

    options.setShowColors(settings.colors ? clang::ShowColorsKind::On : clang::ShowColorsKind::Off);
    clang::TextDiagnosticPrinter printer(stream, options);
    const auto tool = unitTool(compilations, source);

    tool->setDiagnosticConsumer(&printer);
    unit_actions actions(pipeline);

    return tool->run(&actions);
  }
}

int main(int argc, const char** argv) try {
  tbc_lint::registerAttributes();
#if defined(__unix__) || defined(__APPLE__)
  // Parallel C++23 module checking opens many BMIs and headers simultaneously; macOS defaults to
  // 256 descriptors per process, which causes EMFILE / Clang preprocessor failures under `-j`.
  rlimit fd_limit{};

  if (getrlimit(RLIMIT_NOFILE, &fd_limit) == 0) {
    constexpr rlim_t target = 10240;
    const rlim_t desired = fd_limit.rlim_max == RLIM_INFINITY ? target : std::min(fd_limit.rlim_max, target);
    if (fd_limit.rlim_cur < desired) {
      fd_limit.rlim_cur = desired;
      static_cast<void>(setrlimit(RLIMIT_NOFILE, &fd_limit));
    }
  }
#endif

  llvm::cl::OptionCategory category("tbc-lint options");
  const llvm::cl::opt<bool> warnings_as_errors("warnings-as-errors", llvm::cl::desc("Report warnings as errors"), llvm::cl::cat(category));
  const llvm::cl::opt<unsigned> jobs("j", llvm::cl::desc("Translation units checked in parallel; 0 uses one per physical core"), llvm::cl::init(0), llvm::cl::cat(category));
  llvm::cl::bits<checker> checks(
      "checks",
      llvm::cl::desc("Comma-separated checks to run; lifetime and bounds when none is given"),
      llvm::cl::values(
          clEnumValN(checker::lifetime, "lifetime", "Borrow checking"),
          clEnumValN(checker::bounds, "bounds", "Static bounds checking"),
          clEnumValN(checker::blank_lines, "blank-lines", "Blank lines between the statements of a block"),
          clEnumValN(checker::interface_bodies, "interface-bodies", "Function bodies in module interface units"),
          clEnumValN(checker::standard_containers, "standard-containers", "Standard containers that telar::ds replaces")
      ),
      llvm::cl::CommaSeparated,
      llvm::cl::cat(category)
  );
  const llvm::cl::opt<bool> fix("fix", llvm::cl::desc("Insert the blank lines that blank-lines asks for"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> header_filter("header-filter", llvm::cl::desc("Regular expression for the headers blank-lines checks besides each main file"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> stamps("stamps", llvm::cl::desc("Directory where each checked unit leaves a stamp named after its source, '/' spelled '%': what it claimed and reported, and whether it failed"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> replay("replay", llvm::cl::desc("File naming the sources, one per line, whose stamps are reported again instead of checking them"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> container_allowlist("standard-containers-allowlist", llvm::cl::desc("File naming the folders standard-containers still allows, one per line"), llvm::cl::cat(category));
  const llvm::cl::list<std::string> scopes("scope", llvm::cl::desc("<check>=<file>, where the file names, one per line, the sources the check applies to; a check with no scope applies to every source, so that one run parses each source once for checks of different scopes"), llvm::cl::cat(category));
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

  // The sources each check applies to, for the checks given a scope.
  std::array<std::optional<llvm::StringSet<>>, 5> scoped;

  for (const auto& scope : scopes) {
    const auto [name, file] = llvm::StringRef(scope).split('=');
    const auto check = tbc_lint::checkerNamed(name);
    auto listed = llvm::MemoryBuffer::getFile(file, /*IsText=*/true);
    if (!check || !listed) {
      llvm::errs() << "tbc-lint: --scope needs <check>=<file> with a check of --checks and a file that can be read, not " << scope << '\n';
      return 2;
    }

    llvm::SmallVector<llvm::StringRef, 256> lines;
    auto& selected = scoped.at(static_cast<std::size_t>(*check)).emplace();

    (*listed)->getBuffer().split(lines, '\n', -1, false);
    for (const auto line : lines) {
      selected.insert(line);
    }
  }

  const auto& compilations = options->getCompilations();
  const auto& sources = options->getSourcePathList();
  const bool lifetime = checks.getBits() == 0 || checks.isSet(checker::lifetime);
  const bool bounds = checks.getBits() == 0 || checks.isSet(checker::bounds);
  std::vector<std::size_t> order(sources.size());

  std::ranges::iota(order, 0);

  tbc_lint::blank_line_fixes fixes;
  tbc_lint::interface_modules interfaces(std::move(allowed));
  tbc_lint::checked_definitions checked;
  const settings configuration{
      .lifetime = lifetime,
      .bounds = bounds,
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

      // What the unit recorded, one line each, up to the line that says its output follows: a recorded
      // name may itself end in that word.
      auto output = (*stamp)->getBuffer();
      llvm::SmallVector<llvm::StringRef, 16> names;

      while (!output.empty()) {
        const auto [line, rest] = output.split('\n');

        output = rest;
        if (line == "output") {
          break;
        }

        names.push_back(line);
      }

      // The unit fails again only when it failed then: a compiler warning, or a warning without
      // --warnings-as-errors, is reported without failing it.
      for (auto line : names) {
        if (line.consume_front("claim ")) {
          checked.preclaim(line);
        } else if (line.consume_front("allow ")) {
          containers.replay(line);
        } else if (line.consume_front("blank ")) {
          fixes.replay(line);
        } else if (line.consume_front("module ")) {
          interfaces.replay(line);
        } else if (line == "failed") {
          failed = true;
        }
      }

      llvm::errs() << output;
    }
  }

  eachSource(order, jobs, [&](std::size_t index) {
    std::string output;
    std::vector<std::string> claimed;
    std::vector<std::string> allowed_uses;
    std::vector<std::string> blank_lines_claimed;
    std::vector<std::string> modules_recorded;

    tbc_lint::checked_definitions::unit_claims = &claimed;
    tbc_lint::container_allowlist::unit_events = &allowed_uses;
    tbc_lint::blank_line_fixes::unit_claims = &blank_lines_claimed;
    tbc_lint::interface_modules::unit_records = &modules_recorded;

    // The unit runs the checks whose scope names it.
    const auto applies = [&](checker check) {
      const auto& scope = scoped.at(static_cast<std::size_t>(check));

      return !scope || scope->contains(sources[index]);
    };

    auto unit = configuration;

    unit.lifetime = configuration.lifetime && applies(checker::lifetime);
    unit.bounds = configuration.bounds && applies(checker::bounds);
    unit.blank_lines = configuration.blank_lines && applies(checker::blank_lines);
    unit.interface_bodies = configuration.interface_bodies && applies(checker::interface_bodies);
    unit.standard_containers = configuration.standard_containers && applies(checker::standard_containers);
    const bool unit_failed = checkUnit(compilations, sources[index], unit, output) != 0;

    tbc_lint::checked_definitions::unit_claims = nullptr;
    tbc_lint::container_allowlist::unit_events = nullptr;
    tbc_lint::blank_line_fixes::unit_claims = nullptr;
    tbc_lint::interface_modules::unit_records = nullptr;
    const std::scoped_lock lock(print);

    llvm::errs() << output;
    if (unit_failed) {
      failed = true;
    }

    // A unit whose object and tbc-lint stay unchanged reports the same next time, so its stamp keeps
    // it, with what it claimed and recorded for the run.
    if (!stamps.empty()) {
      std::error_code error;
      llvm::raw_fd_ostream stamp(stampOf(sources[index]), error);

      for (const auto& name : claimed) {
        stamp << "claim " << name << '\n';
      }

      for (const auto& event : allowed_uses) {
        stamp << "allow " << event << '\n';
      }

      for (const auto& claim : blank_lines_claimed) {
        stamp << "blank " << claim << '\n';
      }

      for (const auto& record : modules_recorded) {
        stamp << "module " << record << '\n';
      }

      if (unit_failed) {
        stamp << "failed\n";
      }

      stamp << "output\n"
            << output;
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
