#include "ast_extractor.hpp"
#include "attributes.hpp"
#include "meta_model.hpp"

#include <clang/Basic/Stack.h>
#include <clang/Frontend/FrontendAction.h>
#include <clang/Tooling/ArgumentsAdjusters.h>
#include <clang/Tooling/CommonOptionsParser.h>
#include <clang/Tooling/Tooling.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/PrettyStackTrace.h>
#include <llvm/Support/Signals.h>
#include <llvm/Support/JSON.h>
#include <llvm/Support/Path.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/Support/thread.h>

#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace {

  using namespace telar::qt_moc;

  class ExtractAction final : public clang::ASTFrontendAction {
  public:
    explicit ExtractAction(UnitMeta& output)
        : output_(output) {}

  protected:
    std::unique_ptr<clang::ASTConsumer> CreateASTConsumer(clang::CompilerInstance& /*compiler*/, llvm::StringRef file) override {
      output_.input_file = llvm::sys::path::filename(file).str();
      return createExtractorConsumer(output_);
    }

  private:
    UnitMeta& output_;
  };

  class ExtractActionFactory final : public clang::tooling::FrontendActionFactory {
  public:
    explicit ExtractActionFactory(UnitMeta& output)
        : output_(output) {}

    std::unique_ptr<clang::FrontendAction> create() override {
      return std::make_unique<ExtractAction>(output_);
    }

  private:
    UnitMeta& output_;
  };

  std::string readText(const std::string& path) {
    std::ifstream stream(path, std::ios::binary);
    std::ostringstream buf;

    buf << stream.rdbuf();
    return buf.str();
  }

  bool writeText(const std::string& path, const std::string& content) {
    std::filesystem::path target(path);

    if (target.has_parent_path()) {
      std::filesystem::create_directories(target.parent_path());
    }

    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream) {
      llvm::errs() << "telar-moc: cannot write " << path << "\n";
      return false;
    }

    stream << content;
    return static_cast<bool>(stream);
  }

  // Loads module-name -> BMI path mappings from CMake CXXModules.json files (following
  // referenced BMIs' sibling CXXModules.json transitively) so --fragment runs on test
  // files before their own .modmap has been generated.
  std::map<std::string, std::string> loadCxxModulesMaps(const std::vector<std::string>& paths, const std::string& build_root) {
    std::map<std::string, std::string> modules;
    std::vector<std::string> queue = paths;
    std::map<std::string, bool> visited;

    for (std::size_t idx = 0; idx < queue.size(); ++idx) {
      const auto norm = std::filesystem::path(queue[idx]).lexically_normal().string();
      if (!visited.emplace(norm, true).second) {
        continue;
      }

      const auto text = readText(norm);
      if (text.empty()) {
        continue;
      }

      auto parsed = llvm::json::parse(text);
      if (!parsed) {
        llvm::consumeError(parsed.takeError());
        continue;
      }

      const auto* root = parsed->getAsObject();
      if (root == nullptr) {
        continue;
      }

      if (const auto* own = root->getObject("modules")) {
        for (const auto& [name, entry] : *own) {
          if (const auto* obj = entry.getAsObject()) {
            if (const auto bmi = obj->getString("bmi")) {
              std::filesystem::path resolved(bmi->str());

              if (resolved.is_relative() && !build_root.empty()) {
                resolved = std::filesystem::path(build_root) / resolved;
              }

              modules.emplace(name.str(), resolved.lexically_normal().string());
            }
          }
        }
      }

      if (const auto* refs = root->getObject("references")) {
        for (const auto& [name, entry] : *refs) {
          if (const auto* obj = entry.getAsObject()) {
            if (const auto rel = obj->getString("path")) {
              std::filesystem::path resolved(rel->str());

              if (resolved.is_relative() && !build_root.empty()) {
                resolved = std::filesystem::path(build_root) / resolved;
              }

              const auto norm_bmi = resolved.lexically_normal();

              modules.emplace(name.str(), norm_bmi.string());
              const auto sibling = norm_bmi.parent_path() / "CXXModules.json";
              if (std::filesystem::exists(sibling)) {
                queue.push_back(sibling.string());
              }
            }
          }
        }
      }
    }

    return modules;
  }

  // Picks a single non-synthetic compile command per source so CMake's @synth_ BMI
  // entries never cause duplicate AST runs or reference unbuilt consumer BMIs.
  class SingleCommandDatabase final : public clang::tooling::CompilationDatabase {
  public:
    explicit SingleCommandDatabase(const clang::tooling::CompilationDatabase& inner)
        : inner_(inner) {}

    std::vector<clang::tooling::CompileCommand> getCompileCommands(llvm::StringRef file_path) const override {
      auto commands = inner_.getCompileCommands(file_path);
      if (commands.size() <= 1) {
        return commands;
      }

      for (auto& cmd : commands) {
        if (cmd.Output.find("@synth_") == std::string::npos) {
          return {std::move(cmd)};
        }
      }

      return {std::move(commands.front())};
    }

    std::vector<std::string> getAllFiles() const override {
      return inner_.getAllFiles();
    }

    std::vector<clang::tooling::CompileCommand> getAllCompileCommands() const override {
      return inner_.getAllCompileCommands();
    }

  private:
    const clang::tooling::CompilationDatabase& inner_;
  };

  clang::tooling::ArgumentsAdjuster makeAdjuster(const std::map<std::string, std::string>& fallback_modules) {
    return [fallback_modules](const clang::tooling::CommandLineArguments& arguments, llvm::StringRef /*filename*/) {
      clang::tooling::CommandLineArguments filtered;
      const bool use_fallback = !fallback_modules.empty();
      filtered.reserve(arguments.size() + fallback_modules.size());
      for (std::size_t idx = 0; idx < arguments.size(); ++idx) {
        const llvm::StringRef arg(arguments[idx]);

        if (arg.starts_with("-fplugin=") || arg.starts_with("-fplugin-arg-") || arg.starts_with("-fmodule-output")) {
          continue;
        }

        if (arg.starts_with("@") && arg.ends_with(".modmap")) {
          if (use_fallback) {
            continue;
          }
        }

        filtered.push_back(arguments[idx]);
      }

      if (use_fallback) {
        for (const auto& [name, bmi] : fallback_modules) {
          filtered.push_back("-fmodule-file=" + name + "=" + bmi);
        }
      }

      return filtered;
    };
  }

}

namespace {
  int run(int argc, const char** argv);
}

int main(int argc, const char** argv) {
  // A crash prints where it happened, as clang does.
  llvm::sys::PrintStackTraceOnErrorSignal(argv[0]);
  const llvm::PrettyStackTraceProgram program(argc, argv);
  int status = 1;
  // Clang parses a unit of the GUI with Qt's headers and every BMI it imports, deeper than the
  // main thread's stack holds; clang's driver grows its stack for that, and a tool has to ask.
  constexpr unsigned stack_bytes = 256U << 20U;
  llvm::thread worker(std::optional<unsigned>{stack_bytes}, [&] {
    clang::noteBottomOfStack();
    status = run(argc, argv);
  });

  worker.join();
  return status;
}

namespace {

int run(int argc, const char** argv) {
  registerAttributes();

  llvm::cl::OptionCategory category("telar-moc options");
  const llvm::cl::opt<std::string> moc_out("moc-out", llvm::cl::desc("Output path for generated module implementation unit or fragment"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> json_out("json-out", llvm::cl::desc("Output path for Qt 6.12 metatypes JSON"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> qml_meta_out("qml-meta-out", llvm::cl::desc("Output path for per-unit QML module registration metadata"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> reg_out("reg-out", llvm::cl::desc("Output path for QML type registration C++"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> merge_json("merge-json", llvm::cl::desc("Output path for merged metatypes JSON (in --collect mode)"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> qt_module("qt-module", llvm::cl::desc("Qt wrapper module name to import"), llvm::cl::init("telar.gui.qt"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> qml_uri("uri", llvm::cl::desc("QML module URI"), llvm::cl::init("Telar.Gui"), llvm::cl::cat(category));
  const llvm::cl::opt<int> qml_major("major", llvm::cl::desc("QML module major version"), llvm::cl::init(1), llvm::cl::cat(category));
  const llvm::cl::opt<int> qml_minor("minor", llvm::cl::desc("QML module minor version"), llvm::cl::init(0), llvm::cl::cat(category));
  const llvm::cl::opt<bool> fragment("fragment", llvm::cl::desc("Emit a #include-able fragment without module/import header"), llvm::cl::init(false), llvm::cl::cat(category));
  const llvm::cl::opt<bool> collect("collect", llvm::cl::desc("Collect per-unit .qmlmeta / .json files without running Clang"), llvm::cl::init(false), llvm::cl::cat(category));
  const llvm::cl::list<std::string> cxx_modules_json("cxx-modules-json", llvm::cl::desc("CMake CXXModules.json paths providing BMI mappings when .modmap does not exist yet"), llvm::cl::cat(category));
  const llvm::cl::opt<std::string> build_root("build-root", llvm::cl::desc("Build root directory for resolving relative paths in CXXModules.json"), llvm::cl::cat(category));

  auto options = clang::tooling::CommonOptionsParser::create(argc, argv, category, llvm::cl::ZeroOrMore);
  if (!options) {
    llvm::errs() << options.takeError();
    return 2;
  }

  const auto& sources = options->getSourcePathList();

  if (collect) {
    std::vector<UnitMeta> units;
    std::vector<std::string> json_texts;

    for (const auto& path : sources) {
      if (llvm::StringRef(path).ends_with(".json")) {
        json_texts.push_back(readText(path));
      } else {
        UnitMeta unit;

        parseQmlMeta(readText(path), unit);
        units.push_back(std::move(unit));
      }
    }

    if (!reg_out.empty()) {
      if (!writeText(reg_out, emitQmlRegistrations(units, qt_module, qml_uri, qml_major, qml_minor))) {
        return 1;
      }
    }

    if (!merge_json.empty()) {
      if (!writeText(merge_json, mergeMetatypesJson(json_texts))) {
        return 1;
      }
    }

    return 0;
  }

  std::vector<std::string> json_paths(cxx_modules_json.begin(), cxx_modules_json.end());
  const auto fallback_modules = loadCxxModulesMaps(json_paths, build_root);

  SingleCommandDatabase single_db(options->getCompilations());
  std::vector<UnitMeta> units;

  units.reserve(sources.size());
  for (const auto& source : sources) {
    UnitMeta unit;
    clang::tooling::ClangTool tool(single_db, {source});

    tool.appendArgumentsAdjuster(makeAdjuster(fallback_modules));
    tool.appendArgumentsAdjuster(clang::tooling::getInsertArgumentAdjuster("-DTELAR_MOC_RUN=1", clang::tooling::ArgumentInsertPosition::END));
    tool.appendArgumentsAdjuster(clang::tooling::getInsertArgumentAdjuster("-Wno-unknown-attributes", clang::tooling::ArgumentInsertPosition::END));
    if (fragment) {
      tool.appendArgumentsAdjuster(clang::tooling::getInsertArgumentAdjuster("-Wno-undefined-internal", clang::tooling::ArgumentInsertPosition::END));
      tool.appendArgumentsAdjuster(clang::tooling::getInsertArgumentAdjuster("-Wno-unused-const-variable", clang::tooling::ArgumentInsertPosition::END));
    }
    tool.appendArgumentsAdjuster(clang::tooling::getInsertArgumentAdjuster("-resource-dir=" TELAR_QT_MOC_RESOURCE_DIR, clang::tooling::ArgumentInsertPosition::END));
    ExtractActionFactory factory(unit);

    if (tool.run(&factory) != 0) {
      return 1;
    }

    units.push_back(std::move(unit));
  }

  if (!moc_out.empty() && !units.empty()) {
    if (!writeText(moc_out, emitMocCpp(units.front(), qt_module, fragment))) {
      return 1;
    }
  }

  if (!json_out.empty() && !units.empty()) {
    if (!writeText(json_out, emitMetatypesJson(units.front()))) {
      return 1;
    }
  }

  if (!qml_meta_out.empty() && !units.empty()) {
    if (!writeText(qml_meta_out, emitQmlMeta(units.front()))) {
      return 1;
    }
  }

  if (!reg_out.empty()) {
    if (!writeText(reg_out, emitQmlRegistrations(units, qt_module, qml_uri, qml_major, qml_minor))) {
      return 1;
    }
  }

  return 0;
}

}
