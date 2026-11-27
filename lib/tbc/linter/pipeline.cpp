#include "pipeline.hpp"

#include "shared_access.hpp"
#include "soundness_checks.hpp"
#include "view_type.hpp"

#include <clang/AST/ASTContext.h>
#include <clang/AST/GlobalDecl.h>
#include <clang/AST/Mangle.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/SourceManager.h>
#include <clang/Frontend/MultiplexConsumer.h>
#include <llvm/ADT/SmallPtrSet.h>
#include <llvm/Support/raw_ostream.h>

#include <vector>

namespace tbc_lint {
  class unit_pipeline::borrow_check final : public clang::ast_matchers::MatchFinder::MatchCallback {
  public:
    borrow_check(lifetime_options options, checked_definitions& checked)
        : analysis_(options),
          options_(options),
          checked_(checked) {}

    void run(const clang::ast_matchers::MatchFinder::MatchResult& result) override {
      if (result.Nodes.getNodeAs<clang::TranslationUnitDecl>("unit") != nullptr) {
        visited_.clear();
        visited_redecls_.clear();
        context_ = result.Context;
        mangler_.reset(context_->createMangleContext());
        // A unit that does not compile has an invalid AST. The question is asked before any check of
        // this run reports, since a reported diagnostic counts as an error under --warnings-as-errors.
        compiled_ = !context_->getDiagnostics().hasUncompilableErrorOccurred();
        analysis_.beginTranslationUnit();
        return;
      }

      if (const auto* record = result.Nodes.getNodeAs<clang::CXXRecordDecl>("record")) {
        if (compiled_ && options_.check_lifetime) {
          checkRecordSoundness(*record, *result.Context, options_.errors);
        }

        return;
      }

      if (const auto* redecl = result.Nodes.getNodeAs<clang::FunctionDecl>("redecl")) {
        if (compiled_ && options_.check_lifetime && redecl->getPreviousDecl() != nullptr && visited_redecls_.insert(redecl->getCanonicalDecl()).second) {
          checkRedeclarationSoundness(*redecl, *result.Context, options_.errors);
        }

        return;
      }

      const auto* function = result.Nodes.getNodeAs<clang::FunctionDecl>("function");
      // An owner's implementation is trusted, as the standard library's is.
      if (compiled_ && function != nullptr && !ownerMember(*function) && visited_.insert(function->getCanonicalDecl()).second && claim(*function, *result.Context)) {
        analysis_.analyze(*function, *result.Context);
        if (options_.check_lifetime) {
          if (const auto* definition = function->getDefinition()) {
            checkSharedAccess(*definition, *result.Context, options_.errors);
          }

          checkFunctionSoundness(*function, *result.Context, options_.errors);
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

      // A constructor or destructor names one of its variants; GlobalDecl's plain form refuses them.
      const auto global = [&] {
        if (const auto* constructor = llvm::dyn_cast<clang::CXXConstructorDecl>(&function)) {
          return clang::GlobalDecl(constructor, clang::Ctor_Complete);
        }

        if (const auto* destructor = llvm::dyn_cast<clang::CXXDestructorDecl>(&function)) {
          return clang::GlobalDecl(destructor, clang::Dtor_Complete);
        }

        return clang::GlobalDecl(&function);
      }();

      std::string name;
      llvm::raw_string_ostream stream(name);

      mangler_->mangleName(global, stream);
      return checked_.claim(std::move(name));
    }

    clang::ASTContext* context_ = nullptr;
    bool compiled_ = false;
    std::unique_ptr<clang::MangleContext> mangler_;
    lifetime_analysis analysis_;
    lifetime_options options_;
    checked_definitions& checked_;
    llvm::SmallPtrSet<const clang::FunctionDecl*, 32> visited_;
    llvm::SmallPtrSet<const clang::FunctionDecl*, 32> visited_redecls_;
  };

  namespace {
    // Limits the matchers to what a unit parses itself outside system headers: its own file, the
    // project headers it includes and the template instantiations it performs. Restores the prior
    // traversal scope on exit so subsequent compiler phases (CodeGen, BMI writing) see the full AST.
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

      // A declaration a module hands over as it is read, such as an inline function, belongs to the
      // unit that defines it.
      void HandleInterestingDecl(clang::DeclGroupRef group) override {
        matchers_->HandleInterestingDecl(group);
      }

      void HandleTranslationUnit(clang::ASTContext& context) override {
        const auto prior = context.getTraversalScope();
        const std::vector<clang::Decl*> previous(prior.begin(), prior.end());

        context.setTraversalScope(declarations_);
        matchers_->HandleTranslationUnit(context);
        context.setTraversalScope(previous);
      }

    private:
      clang::ASTContext* context_ = nullptr;
      std::unique_ptr<clang::ASTConsumer> matchers_;
      std::vector<clang::Decl*> declarations_;
    };
  }

  unit_pipeline::unit_pipeline(pipeline_settings settings)
      : settings_(std::move(settings)) {
    if ((settings_.lifetime || settings_.bounds) && settings_.checked != nullptr) {
      borrows_ = std::make_unique<borrow_check>(lifetime_options{.errors = settings_.errors, .check_lifetime = settings_.lifetime, .check_bounds = settings_.bounds}, *settings_.checked);
      finder_.addMatcher(clang::ast_matchers::translationUnitDecl().bind("unit"), borrows_.get());
      if (settings_.lifetime) {
        finder_.addMatcher(clang::ast_matchers::cxxRecordDecl(clang::ast_matchers::isDefinition(), clang::ast_matchers::unless(clang::ast_matchers::isExpansionInSystemHeader())).bind("record"), borrows_.get());
        finder_.addMatcher(clang::ast_matchers::functionDecl(clang::ast_matchers::unless(clang::ast_matchers::isExpansionInSystemHeader()), clang::ast_matchers::unless(clang::ast_matchers::isImplicit())).bind("redecl"), borrows_.get());
        overloads_.emplace(settings_.errors, *settings_.checked);
        overloads_->registerMatchers(finder_);
      }

      finder_.addMatcher(clang::ast_matchers::functionDecl(clang::ast_matchers::isDefinition(), clang::ast_matchers::unless(clang::ast_matchers::isExpansionInSystemHeader())).bind("function"), borrows_.get());
      has_matchers_ = true;
    }

    if (settings_.blank_lines && settings_.fixes != nullptr) {
      blank_lines_.emplace(*settings_.fixes, settings_.errors, settings_.header_filter);
      blank_lines_->registerMatchers(finder_);
      has_matchers_ = true;
    }

    if (settings_.standard_containers && settings_.checked != nullptr && settings_.containers != nullptr) {
      containers_.emplace(settings_.errors, *settings_.checked, *settings_.containers);
      containers_->registerMatchers(finder_);
      has_matchers_ = true;
    }
  }

  unit_pipeline::~unit_pipeline() = default;

  std::unique_ptr<clang::ASTConsumer> unit_pipeline::createConsumer() {
    std::vector<std::unique_ptr<clang::ASTConsumer>> consumers;

    if (settings_.interface_bodies && settings_.interfaces != nullptr) {
      consumers.push_back(std::make_unique<interface_body_check>(*settings_.interfaces, settings_.errors));
    }

    if (has_matchers_) {
      consumers.push_back(std::make_unique<parsed_scope>(finder_.newASTConsumer()));
    }

    return std::make_unique<clang::MultiplexConsumer>(std::move(consumers));
  }
}
