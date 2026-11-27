#include "attributes.hpp"
#include "blank_lines.hpp"
#include "checked_definitions.hpp"
#include "interface_bodies.hpp"
#include "pipeline.hpp"
#include "standard_containers.hpp"

#include <clang/AST/ASTConsumer.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/LangOptions.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/FrontendAction.h>
#include <clang/Frontend/FrontendPluginRegistry.h>
#include <llvm/ADT/SmallString.h>
#include <llvm/ADT/SmallVector.h>
#include <llvm/ADT/StringRef.h>
#include <llvm/ADT/StringSet.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/Regex.h>

#include <array>
#include <cstddef>
#include <cstdlib>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace {
  using plugin_checker = tbc_lint::checker_kind;

  // Owns the unit_pipeline and its backing allowlist/claim stores for the lifetime of the consumer.
  class plugin_consumer final : public clang::ASTConsumer {
  public:
    plugin_consumer(
        const tbc_lint::pipeline_settings& base,
        llvm::StringSet<> allowed_modules,
        const std::vector<std::string>& allowed_folders
    )
        : interfaces_(std::move(allowed_modules)),
          containers_(allowed_folders) {
      auto settings = base;

      settings.fixes = &fixes_;
      settings.interfaces = &interfaces_;
      settings.checked = &checked_;
      settings.containers = &containers_;
      pipeline_ = std::make_unique<tbc_lint::unit_pipeline>(settings);
      inner_ = pipeline_->createConsumer();
    }

    void Initialize(clang::ASTContext& context) override {
      inner_->Initialize(context);
    }

    bool HandleTopLevelDecl(clang::DeclGroupRef group) override {
      return inner_->HandleTopLevelDecl(group);
    }

    void HandleInterestingDecl(clang::DeclGroupRef group) override {
      inner_->HandleInterestingDecl(group);
    }

    void HandleTranslationUnit(clang::ASTContext& context) override {
      inner_->HandleTranslationUnit(context);
    }

  private:
    tbc_lint::blank_line_fixes fixes_;
    tbc_lint::interface_modules interfaces_;
    tbc_lint::checked_definitions checked_;
    tbc_lint::container_allowlist containers_;
    std::unique_ptr<tbc_lint::unit_pipeline> pipeline_;
    std::unique_ptr<clang::ASTConsumer> inner_;
  };

  class tbc_plugin_action final : public clang::PluginASTAction {
  public:
    tbc_plugin_action() {
      tbc_lint::registerAttributes();
    }

    ActionType getActionType() override {
      // Runs before CodeGen/BMI emission so borrow checker errors halt compilation like rustc.
      return AddBeforeMainAction;
    }

  protected:
    bool ParseArgs(const clang::CompilerInstance& compiler, const std::vector<std::string>& arguments) override {
      auto& diagnostics = compiler.getDiagnostics();
      const auto report_error = [&](llvm::StringRef message) {
        const auto id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, "tbc-plugin: %0");

        diagnostics.Report(id) << message;
        return false;
      };

      bool explicit_checks = false;
      bool none_requested = false;

      for (const auto& raw : arguments) {
        llvm::StringRef arg(raw);

        if (arg == "warnings-as-errors") {
          errors_ = true;
          continue;
        }

        if (arg.consume_front("checks=")) {
          explicit_checks = true;
          llvm::SmallVector<llvm::StringRef, 8> parts;

          arg.split(parts, ',', -1, false);
          for (const auto part : parts) {
            if (part == "none") {
              none_requested = true;
              continue;
            }

            const auto check = tbc_lint::checkerNamed(part);
            if (!check) {
              return report_error("unknown check '" + part.str() + "'");
            }

            switch (*check) {
            case plugin_checker::lifetime:
              lifetime_ = true;
              break;
            case plugin_checker::bounds:
              bounds_ = true;
              break;
            case plugin_checker::blank_lines:
              blank_lines_ = true;
              break;
            case plugin_checker::interface_bodies:
              interface_bodies_ = true;
              break;
            case plugin_checker::standard_containers:
              standard_containers_ = true;
              break;
            }
          }

          continue;
        }

        if (arg.consume_front("header-filter=")) {
          if (std::string error; !arg.empty() && !llvm::Regex(arg).isValid(error)) {
            return report_error("invalid header-filter: " + error);
          }

          header_filter_ = arg.str();
          continue;
        }

        if (arg.consume_front("interface-allowlist=")) {
          auto modules = tbc_lint::readInterfaceAllowlist(arg);
          if (!modules) {
            return report_error(llvm::toString(modules.takeError()));
          }

          allowed_modules_ = std::move(*modules);
          continue;
        }

        if (arg.consume_front("standard-containers-allowlist=")) {
          auto folders = tbc_lint::container_allowlist::read(arg);
          if (!folders) {
            return report_error(llvm::toString(folders.takeError()));
          }

          allowed_folders_ = std::move(*folders);
          continue;
        }

        if (arg.consume_front("scope=")) {
          const auto [name, file] = arg.split('=');
          const auto check = tbc_lint::checkerNamed(name);
          if (!check || file.empty()) {
            return report_error("scope expects <check>=<file>, got '" + arg.str() + "'");
          }

          auto listed = llvm::MemoryBuffer::getFile(file, /*IsText=*/true);
          if (!listed) {
            // A scope file may not exist yet during early probe compiles; treat as empty scope.
            scoped_.at(static_cast<std::size_t>(*check)).emplace();
            continue;
          }

          llvm::SmallVector<llvm::StringRef, 256> lines;
          auto& set = scoped_.at(static_cast<std::size_t>(*check)).emplace();

          (*listed)->getBuffer().split(lines, '\n', -1, false);
          for (const auto line : lines) {
            if (!line.empty()) {
              set.insert(line);
            }
          }

          continue;
        }

        return report_error("unknown plugin argument '" + raw + "'");
      }

      if (!explicit_checks) {
        // Standalone `-fplugin=tbc-plugin.so` defaults to borrow checking (lifetime).
        lifetime_ = true;
      } else if (none_requested) {
        lifetime_ = false;
        bounds_ = false;
        blank_lines_ = false;
        interface_bodies_ = false;
        standard_containers_ = false;
      }

      return true;
    }

    std::unique_ptr<clang::ASTConsumer> CreateASTConsumer(clang::CompilerInstance& compiler, llvm::StringRef file) override {
      // Pure C / Objective-C units (and clang-tidy runs setting TBC_PLUGIN_DISABLE) still receive
      // custom ParsedAttrInfo attributes (e.g. [[tbc::raw]]), while C++ AST checks are skipped.
      if (!compiler.getLangOpts().CPlusPlus || std::getenv("TBC_PLUGIN_DISABLE") != nullptr) {
        return std::make_unique<clang::ASTConsumer>();
      }

      std::string canonical_file = file.str();
      llvm::SmallString<256> resolved;

      if (!file.empty() && !llvm::sys::fs::real_path(file, resolved)) {
        canonical_file.assign(resolved.begin(), resolved.end());
      }

      const auto applies = [&](plugin_checker check) {
        const auto& scope = scoped_.at(static_cast<std::size_t>(check));

        return !scope || scope->contains(canonical_file) || scope->contains(file);
      };

      const tbc_lint::pipeline_settings settings{
          .lifetime = lifetime_ && applies(plugin_checker::lifetime),
          .bounds = bounds_ && applies(plugin_checker::bounds),
          .blank_lines = blank_lines_ && applies(plugin_checker::blank_lines),
          .interface_bodies = interface_bodies_ && applies(plugin_checker::interface_bodies),
          .standard_containers = standard_containers_ && applies(plugin_checker::standard_containers),
          .errors = errors_,
          .header_filter = header_filter_,
      };

      if (!settings.lifetime && !settings.bounds && !settings.blank_lines && !settings.interface_bodies && !settings.standard_containers) {
        return std::make_unique<clang::ASTConsumer>();
      }

      return std::make_unique<plugin_consumer>(settings, allowed_modules_, allowed_folders_);
    }

  private:
    bool lifetime_ = false;
    bool bounds_ = false;
    bool blank_lines_ = false;
    bool interface_bodies_ = false;
    bool standard_containers_ = false;
    bool errors_ = false;
    std::string header_filter_;
    llvm::StringSet<> allowed_modules_;
    std::vector<std::string> allowed_folders_;
    std::array<std::optional<llvm::StringSet<>>, 5> scoped_;
  };

  // NOLINTNEXTLINE(bugprone-throwing-static-initialization)
  const clang::FrontendPluginRegistry::Add<tbc_plugin_action> registration("tbc", "Telar borrow checker and module style checks.");
}
