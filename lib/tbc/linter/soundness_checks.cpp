#include "soundness_checks.hpp"

#include "view_type.hpp"

#include <clang/AST/Expr.h>
#include <clang/AST/ExprCXX.h>
#include <clang/AST/RecursiveASTVisitor.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/DenseSet.h>

namespace tbc_lint {
  namespace {
    bool isRawContext(const clang::FunctionDecl& function) {
      if (isRawFunction(function)) {
        return true;
      }

      if (const auto* method = llvm::dyn_cast<clang::CXXMethodDecl>(&function)) {
        if (sharedRecord(*method->getParent()) || ownerRecord(*method->getParent())) {
          return true;
        }
      }

      return false;
    }

    bool isAllowedMutableType(clang::QualType type, const clang::ASTContext& context) {
      type = type.getNonReferenceType();
      if (isSynchronizationType(type)) {
        return true;
      }

      const auto* record = recordOf(type);
      if (record == nullptr) {
        return false;
      }

      if (sharedRecord(*record)) {
        return true;
      }

      const auto& sources = context.getSourceManager();

      return record->isCLike() && sources.isInSystemHeader(sources.getExpansionLoc(record->getLocation()));
    }

    bool sameRegionContract(const annotation& left, const annotation& right) {
      if (!left.present || !right.present) {
        return true;
      }

      if (left.region != nullptr && right.region != nullptr && left.region != right.region) {
        return false;
      }

      if (left.inner_region != nullptr && right.inner_region != nullptr && left.inner_region != right.inner_region) {
        return false;
      }

      if (left.region != nullptr && right.region != nullptr && left.held != right.held) {
        return false;
      }

      return true;
    }

    // Checks that all redeclarations of a function agree on explicit tbc::view region contracts.
    void checkRedeclarationContracts(const clang::FunctionDecl& function, clang::ASTContext& context, bool errors) {
      const auto& sources = context.getSourceManager();
      llvm::SmallVector<const clang::FunctionDecl*, 4> decls;

      for (const auto* redecl : function.redecls()) {
        if (!sources.isInSystemHeader(sources.getExpansionLoc(redecl->getLocation()))) {
          decls.push_back(redecl);
        }
      }

      // FunctionDecl::redecls() yields most-recent first; reverse so the earliest declaration is baseline.
      std::ranges::reverse(decls);

      const clang::FunctionDecl* baseline = nullptr;
      annotation base_return;

      for (const auto* redecl : decls) {
        const auto ret = viewAnnotation(redecl->getDeclaredReturnType(), context);

        if (baseline == nullptr) {
          baseline = redecl;
          base_return = ret;
          continue;
        }

        auto& diagnostics = context.getDiagnostics();
        const auto severity = errors ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning;

        if (!sameRegionContract(base_return, ret)) {
          const auto id = diagnostics.getCustomDiagID(severity, "redeclaration conflicts with earlier return lifetime contract [tbc-contract-violation]");
          const auto note_id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Note, "earlier contract declared here");

          diagnostics.Report(sources.getExpansionLoc(redecl->getLocation()), id);
          diagnostics.Report(sources.getExpansionLoc(baseline->getLocation()), note_id);
        }

        if (ret.present && ret.region != nullptr && base_return.region == nullptr) {
          base_return = ret;
        }

        const auto count = std::min(baseline->getNumParams(), redecl->getNumParams());

        for (unsigned index = 0; index < count; ++index) {
          const auto base_param = viewAnnotation(baseline->getParamDecl(index)->getType(), context);
          const auto curr_param = viewAnnotation(redecl->getParamDecl(index)->getType(), context);

          if (!sameRegionContract(base_param, curr_param)) {
            const auto id = diagnostics.getCustomDiagID(severity, "redeclaration conflicts with earlier parameter lifetime contract [tbc-contract-violation]");
            const auto note_id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Note, "earlier contract declared here");

            diagnostics.Report(sources.getExpansionLoc(redecl->getParamDecl(index)->getLocation()), id);
            diagnostics.Report(sources.getExpansionLoc(baseline->getParamDecl(index)->getLocation()), note_id);
          }
        }
      }
    }

    // Checks whether a const_cast is directly consumed by a raw/FFI boundary (tbc::raw, a system
    // header C API call, or a system C struct field such as iovec/z_stream/nghttp2_nv).
    class soundness_visitor final : public clang::RecursiveASTVisitor<soundness_visitor> {
    public:
      soundness_visitor(clang::ASTContext& context, bool errors)
          : context_(context),
            errors_(errors) {}

      bool VisitCallExpr(clang::CallExpr* call) {
        const auto* callee = call->getDirectCallee();
        if (callee == nullptr) {
          return true;
        }

        const auto& sources = context_.getSourceManager();
        const bool allowed_boundary = isRawFunction(*callee) || sources.isInSystemHeader(sources.getExpansionLoc(callee->getLocation()));

        if (allowed_boundary) {
          for (const auto* argument : call->arguments()) {
            markAllowedConstCasts(argument);
          }
        }

        return true;
      }

      bool VisitBinaryOperator(clang::BinaryOperator* operation) {
        if (!operation->isAssignmentOp()) {
          return true;
        }

        if (const auto* member = llvm::dyn_cast<clang::MemberExpr>(operation->getLHS()->IgnoreParenImpCasts())) {
          if (const auto* field = llvm::dyn_cast<clang::FieldDecl>(member->getMemberDecl())) {
            const auto* parent = llvm::dyn_cast<clang::CXXRecordDecl>(field->getParent());
            const auto& sources = context_.getSourceManager();
            if (parent != nullptr && parent->isCLike() && sources.isInSystemHeader(sources.getExpansionLoc(parent->getLocation()))) {
              markAllowedConstCasts(operation->getRHS());
            }
          }
        }

        return true;
      }

      bool VisitInitListExpr(clang::InitListExpr* list) {
        const auto* record = recordOf(list->getType());
        const auto& sources = context_.getSourceManager();
        if (record != nullptr && record->isCLike() && sources.isInSystemHeader(sources.getExpansionLoc(record->getLocation()))) {
          for (const auto* init : list->inits()) {
            markAllowedConstCasts(init);
          }

          if (const auto* syntactic = list->getSyntacticForm(); syntactic != nullptr && syntactic != list) {
            for (const auto* init : syntactic->inits()) {
              markAllowedConstCasts(init);
            }
          }
        }

        return true;
      }

      bool VisitCXXConstCastExpr(clang::CXXConstCastExpr* cast) {
        if (allowed_casts_.contains(cast)) {
          return true;
        }

        const auto& sources = context_.getSourceManager();
        const auto location = sources.getExpansionLoc(cast->getOperatorLoc());
        const auto spelling = sources.getSpellingLoc(cast->getOperatorLoc());
        if (location.isInvalid() || sources.isInSystemHeader(location) || (spelling.isValid() && sources.isInSystemHeader(spelling)) || !reported_.insert(location.getRawEncoding()).second) {
          return true;
        }

        auto& diagnostics = context_.getDiagnostics();
        const auto id = diagnostics.getCustomDiagID(errors_ ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning, "const_cast breaks shared immutability; wrap intentional FFI casts in tbc::raw() [tbc-const-cast]");

        diagnostics.Report(location, id);
        return true;
      }

      bool VisitDeclRefExpr(clang::DeclRefExpr* ref) {
        const auto* variable = llvm::dyn_cast<clang::VarDecl>(ref->getDecl());
        if (variable == nullptr || !variable->hasGlobalStorage() || variable->isConstexpr()) {
          return true;
        }

        // POSIX `extern char** environ;` is an OS-owned global declared in user code on macOS.
        if (variable->isExternC() && variable->getIdentifier() != nullptr && variable->getName() == "environ") {
          return true;
        }

        const auto type = variable->getType();
        if (type.isConstQualified() || type->isReferenceType() || isAllowedMutableType(type, context_)) {
          return true;
        }

        const auto& sources = context_.getSourceManager();
        const auto var_loc = sources.getExpansionLoc(variable->getLocation());
        if (var_loc.isInvalid() || sources.isInSystemHeader(var_loc)) {
          return true;
        }

        // Thread-local storage cannot race across threads, but still breaks noalias across calls.
        const auto use_loc = sources.getExpansionLoc(ref->getLocation());
        const auto spell_loc = sources.getSpellingLoc(ref->getLocation());
        if (use_loc.isInvalid() || sources.isInSystemHeader(use_loc) || (spell_loc.isValid() && sources.isInSystemHeader(spell_loc)) || !reported_.insert(use_loc.getRawEncoding()).second) {
          return true;
        }

        auto& diagnostics = context_.getDiagnostics();
        const auto id = diagnostics.getCustomDiagID(errors_ ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning, "accesses unsynchronized mutable global '%0'; use a [[tbc::shared]] or atomic type, or pass state explicitly [tbc-mutable-global]");

        diagnostics.Report(use_loc, id) << variable->getName();
        return true;
      }

    private:
      void markAllowedConstCasts(const clang::Expr* expr) {
        if (expr == nullptr) {
          return;
        }

        expr = expr->IgnoreParenImpCasts();
        if (const auto* cast = llvm::dyn_cast<clang::CXXConstCastExpr>(expr)) {
          allowed_casts_.insert(cast);
          return;
        }

        if (const auto* explicit_cast = llvm::dyn_cast<clang::ExplicitCastExpr>(expr)) {
          markAllowedConstCasts(explicit_cast->getSubExpr());
        } else if (const auto* init = llvm::dyn_cast<clang::InitListExpr>(expr)) {
          for (const auto* item : init->inits()) {
            markAllowedConstCasts(item);
          }
        }
      }

      clang::ASTContext& context_;
      bool errors_;
      llvm::SmallPtrSet<const clang::CXXConstCastExpr*, 8> allowed_casts_;
      llvm::DenseSet<clang::SourceLocation::UIntTy> reported_;
    };
  }

  void checkRedeclarationSoundness(const clang::FunctionDecl& function, clang::ASTContext& context, bool errors) {
    if (function.isDependentContext() || function.isImplicit()) {
      return;
    }

    checkRedeclarationContracts(function, context, errors);
  }

  void checkFunctionSoundness(const clang::FunctionDecl& function, clang::ASTContext& context, bool errors) {
    if (function.isDependentContext() || function.isImplicit()) {
      return;
    }

    const auto* definition = function.getDefinition();
    if (definition == nullptr || definition->getBody() == nullptr || isRawContext(*definition)) {
      return;
    }

    soundness_visitor visitor(context, errors);

    visitor.TraverseStmt(definition->getBody());
  }

  void checkRecordSoundness(const clang::CXXRecordDecl& record, clang::ASTContext& context, bool errors) {
    if (!record.isThisDeclarationADefinition() || record.isDependentContext() || record.isImplicit() || record.isLambda() || sharedRecord(record) || ownerRecord(record)) {
      return;
    }

    const auto& sources = context.getSourceManager();
    if (sources.isInSystemHeader(sources.getExpansionLoc(record.getLocation()))) {
      return;
    }

    for (const auto* field : record.fields()) {
      if (!field->isMutable() || isAllowedMutableType(field->getType(), context)) {
        continue;
      }

      const auto location = sources.getExpansionLoc(field->getLocation());
      if (location.isInvalid()) {
        continue;
      }

      auto& diagnostics = context.getDiagnostics();
      const auto id = diagnostics.getCustomDiagID(errors ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning, "mutable field '%0' breaks shared immutability (Freeze); wrap it in telar::ds::Cell, a synchronization primitive, or mark the class [[tbc::shared]] [tbc-mutable-member]");

      diagnostics.Report(location, id) << field->getName();
    }
  }
}
