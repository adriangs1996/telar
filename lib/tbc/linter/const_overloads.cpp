#include "const_overloads.hpp"

#include <clang/AST/ASTContext.h>
#include <clang/AST/DeclCXX.h>
#include <clang/AST/DeclTemplate.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/SmallVector.h>

#include <string>

namespace tbc_lint {
  namespace {
    // The member functions a class declares itself, member templates included.
    void declaredMethods(const clang::CXXRecordDecl& record, llvm::SmallVectorImpl<const clang::CXXMethodDecl*>& methods) {
      for (const auto* declaration : record.decls()) {
        if (const auto* method = llvm::dyn_cast<clang::CXXMethodDecl>(declaration)) {
          methods.push_back(method);
        } else if (const auto* pattern = llvm::dyn_cast<clang::FunctionTemplateDecl>(declaration)) {
          if (const auto* templated = llvm::dyn_cast<clang::CXXMethodDecl>(pattern->getTemplatedDecl())) {
            methods.push_back(templated);
          }
        }
      }
    }

    // A non-const method that an rvalue receiver does not select and whose signature no base chose.
    bool candidate(const clang::CXXMethodDecl& method) {
      return method.isInstance() && !method.isImplicit() && !method.isConst() && method.getRefQualifier() != clang::RQ_RValue && method.size_overridden_methods() == 0 && !llvm::isa<clang::CXXConstructorDecl, clang::CXXDestructorDecl, clang::CXXConversionDecl>(method);
    }

    bool sameParameters(const clang::CXXMethodDecl& left, const clang::CXXMethodDecl& right) {
      if (left.getNumParams() != right.getNumParams() || (left.getDescribedFunctionTemplate() == nullptr) != (right.getDescribedFunctionTemplate() == nullptr)) {
        return false;
      }

      for (unsigned index = 0; index < left.getNumParams(); ++index) {
        if (left.getParamDecl(index)->getType().getCanonicalType() != right.getParamDecl(index)->getType().getCanonicalType()) {
          return false;
        }
      }

      return true;
    }

    // The const method a non-const one overloads on constness alone.
    const clang::CXXMethodDecl* constTwin(const clang::CXXMethodDecl& method, llvm::ArrayRef<const clang::CXXMethodDecl*> methods) {
      for (const auto* other : methods) {
        if (other != &method && other->isConst() && other->getRefQualifier() != clang::RQ_RValue && other->getDeclName() == method.getDeclName() && sameParameters(method, *other)) {
          return other;
        }
      }

      return nullptr;
    }
  }

  const clang::CXXMethodDecl* constOverload(const clang::CXXMethodDecl& method) {
    llvm::SmallVector<const clang::CXXMethodDecl*, 16> methods;

    declaredMethods(*method.getParent(), methods);
    return constTwin(method, methods);
  }

  const_overload_check::const_overload_check(bool errors, checked_definitions& checked)
      : errors_(errors),
        checked_(checked) {}

  void const_overload_check::registerMatchers(clang::ast_matchers::MatchFinder& finder) {
    using namespace clang::ast_matchers;

    finder.addMatcher(cxxRecordDecl(isDefinition(), unless(isExpansionInSystemHeader()), unless(isLambda())).bind("record"), this);
  }

  void const_overload_check::run(const clang::ast_matchers::MatchFinder::MatchResult& result) {
    const auto* record = result.Nodes.getNodeAs<clang::CXXRecordDecl>("record");
    if (record == nullptr || record->getInstantiatedFromMemberClass() != nullptr) {
      return;
    }

    // A class template is checked once, as written, never per instantiation.
    if (const auto* specialization = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(record); specialization != nullptr && specialization->getSpecializationKind() != clang::TSK_ExplicitSpecialization) {
      return;
    }

    auto& context = *result.Context;
    const auto& sources = context.getSourceManager();
    const auto location = sources.getExpansionLoc(record->getLocation());
    if (!sources.isInMainFile(location) && !checked_.claim("class:" + checked_definitions::place(sources, location))) {
      return;
    }

    llvm::SmallVector<const clang::CXXMethodDecl*, 16> methods;

    declaredMethods(*record, methods);
    auto& diagnostics = context.getDiagnostics();
    const auto id = diagnostics.getCustomDiagID(errors_ ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning, "%0 overloads a const method on constness; give mutable access its own name [tbc-const-overload]");
    const auto note = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Note, "const overload declared here");

    for (const auto* method : methods) {
      if (!candidate(*method)) {
        continue;
      }

      if (const auto* twin = constTwin(*method, methods)) {
        diagnostics.Report(method->getLocation(), id) << method;
        diagnostics.Report(twin->getLocation(), note);
      }
    }
  }
}
