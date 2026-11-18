#include "shared_access.hpp"

#include "const_overloads.hpp"
#include "view_type.hpp"

#include <clang/AST/DeclCXX.h>
#include <clang/AST/Expr.h>
#include <clang/AST/ExprCXX.h>
#include <clang/AST/RecursiveASTVisitor.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/DenseSet.h>

#include <initializer_list>
#include <string>

namespace tbc_lint {
  namespace {
    // What may change through shared access: a type with interior mutability, a synchronization
    // primitive, and what the analysis cannot see into, such as an opaque C handle's object or a C
    // struct, which a raw pointer reaches in Rust.
    bool mayChangeShared(clang::QualType type, const clang::ASTContext& context) {
      type = type.getNonReferenceType();
      if (type.isConstQualified() || type->isFunctionType() || type->isVoidType() || type->isIncompleteType()) {
        return true;
      }

      const auto* record = recordOf(type);
      if (record == nullptr) {
        return false;
      }

      if (sharedRecord(*record)) {
        return true;
      }

      for (const auto* name : {"mutex", "recursive_mutex", "shared_mutex", "timed_mutex", "condition_variable", "condition_variable_any", "atomic", "atomic_flag", "once_flag"}) {
        if (standardType(type, name)) {
          return true;
        }
      }

      const auto& sources = context.getSourceManager();

      return record->isCLike() && sources.isInSystemHeader(sources.getExpansionLoc(record->getLocation()));
    }

    // Whether the object an expression holding a field denotes is reached through shared access.
    bool sharedHolder(const clang::MemberExpr& member) {
      const auto type = member.getBase()->getType();

      return member.isArrow() ? type->getPointeeType().isConstQualified() : type.isConstQualified();
    }

    // A standard method that differs from a const one only in its constness hands out access, as
    // std::vector::front does, which C++ picks by the object's constness: what is done with its
    // result counts, not the call. A project type has no such pair (tbc-const-overload).
    bool standardAccessor(const clang::CXXMethodDecl* method) {
      return method != nullptr && !method->isConst() && standardDeclaration(*method) && constOverload(*method) != nullptr;
    }

    class shared_access final : public clang::RecursiveASTVisitor<shared_access> {
    public:
      shared_access(clang::ASTContext& context, bool errors)
          : context_(context),
            errors_(errors) {}

      bool VisitCXXMemberCallExpr(clang::CXXMemberCallExpr* call) {
        const auto* method = call->getMethodDecl();
        if (method != nullptr && !method->isConst() && method->isInstance() && !standardAccessor(method)) {
          if (const auto* object = call->getImplicitObjectArgument()) {
            object->getType()->isPointerType() ? pointee(*object) : mutated(*object);
          }
        }

        arguments(call->getDirectCallee(), llvm::ArrayRef(call->getArgs(), call->getNumArgs()));
        return true;
      }

      bool VisitCXXOperatorCallExpr(clang::CXXOperatorCallExpr* call) {
        const auto* method = llvm::dyn_cast_or_null<clang::CXXMethodDecl>(call->getDirectCallee());
        if (method == nullptr) {
          arguments(call->getDirectCallee(), llvm::ArrayRef(call->getArgs(), call->getNumArgs()));
          return true;
        }

        if (!method->isConst() && method->isInstance() && !standardAccessor(method) && call->getNumArgs() != 0) {
          mutated(*call->getArg(0));
        }

        if (call->getNumArgs() > 1) {
          arguments(method, llvm::ArrayRef(call->getArgs() + 1, call->getNumArgs() - 1));
        }

        return true;
      }

      bool VisitCallExpr(clang::CallExpr* call) {
        if (!llvm::isa<clang::CXXMemberCallExpr, clang::CXXOperatorCallExpr>(call)) {
          arguments(call->getDirectCallee(), llvm::ArrayRef(call->getArgs(), call->getNumArgs()));
        }

        return true;
      }

      bool VisitCXXConstructExpr(clang::CXXConstructExpr* construction) {
        arguments(construction->getConstructor(), llvm::ArrayRef(construction->getArgs(), construction->getNumArgs()));
        return true;
      }

      bool VisitBinaryOperator(clang::BinaryOperator* operation) {
        if (operation->isAssignmentOp()) {
          mutated(*operation->getLHS());
        }

        return true;
      }

      bool VisitUnaryOperator(clang::UnaryOperator* operation) {
        if (operation->isIncrementDecrementOp()) {
          mutated(*operation->getSubExpr());
        }

        return true;
      }

    private:
      // An argument bound to a non-const reference may be mutated, and so may what a pointer to
      // non-const designates.
      void arguments(const clang::FunctionDecl* callee, llvm::ArrayRef<const clang::Expr*> arguments) {
        if (callee == nullptr) {
          return;
        }

        for (unsigned index = 0; index < callee->getNumParams() && index < arguments.size(); ++index) {
          const auto type = callee->getParamDecl(index)->getType();

          if (type->isReferenceType() && !type.getNonReferenceType().isConstQualified()) {
            mutated(*arguments[index]);
          } else if (type->isPointerType() && !type->getPointeeType().isConstQualified()) {
            pointee(*arguments[index]);
          }
        }
      }

      // Follows the object an expression denotes up to where shared access would reach it through a
      // field that refers to another object.
      void mutated(const clang::Expr& expression) {
        const auto* current = expression.IgnoreParenImpCasts();

        while (current != nullptr) {
          if (const auto* member = llvm::dyn_cast<clang::MemberExpr>(current)) {
            const auto* field = llvm::dyn_cast<clang::FieldDecl>(member->getMemberDecl());
            if (field == nullptr) {
              return;
            }

            if (field->getType()->isReferenceType() && sharedHolder(*member) && !mayChangeShared(field->getType(), context_)) {
              report(*member, *field);
              return;
            }

            if (member->isArrow()) {
              pointee(*member->getBase());
              return;
            }

            current = member->getBase()->IgnoreParenImpCasts();
            continue;
          }

          if (const auto* operation = llvm::dyn_cast<clang::UnaryOperator>(current); operation != nullptr && operation->getOpcode() == clang::UO_Deref) {
            pointee(*operation->getSubExpr());
            return;
          }

          // What a smart pointer or another owner hands out through `*` or `->`.
          if (const auto* call = llvm::dyn_cast<clang::CXXOperatorCallExpr>(current); call != nullptr && (call->getOperator() == clang::OO_Star || call->getOperator() == clang::OO_Arrow) && call->getNumArgs() != 0) {
            leaked(*call, *call->getArg(0));
            return;
          }

          // Mutating what an accessor hands out mutates the object it was asked of.
          if (const auto* call = llvm::dyn_cast<clang::CXXOperatorCallExpr>(current); call != nullptr && call->getNumArgs() != 0 && standardAccessor(llvm::dyn_cast_or_null<clang::CXXMethodDecl>(call->getDirectCallee()))) {
            current = call->getArg(0)->IgnoreParenImpCasts();
            continue;
          }

          if (const auto* call = llvm::dyn_cast<clang::CXXMemberCallExpr>(current)) {
            const auto* object = call->getImplicitObjectArgument();
            if (object != nullptr && standardAccessor(call->getMethodDecl())) {
              if (object->getType()->isPointerType()) {
                pointee(*object);
                return;
              }

              current = object->IgnoreParenImpCasts();
              continue;
            }

            if (object != nullptr) {
              leaked(*call, *object);
            }

            return;
          }

          return;
        }
      }

      // The object a pointer designates is mutated: shared access reaches it when the pointer is a
      // field of an object reached through shared access.
      void pointee(const clang::Expr& pointer) {
        const auto* current = pointer.IgnoreParenImpCasts();

        if (const auto* address = llvm::dyn_cast<clang::UnaryOperator>(current); address != nullptr && address->getOpcode() == clang::UO_AddrOf) {
          mutated(*address->getSubExpr());
          return;
        }

        if (const auto* member = llvm::dyn_cast<clang::MemberExpr>(current)) {
          const auto* field = llvm::dyn_cast<clang::FieldDecl>(member->getMemberDecl());
          if (field == nullptr) {
            return;
          }

          if (field->getType()->isPointerType() && sharedHolder(*member) && !mayChangeShared(field->getType()->getPointeeType(), context_)) {
            report(*member, *field);
            return;
          }

          member->isArrow() ? pointee(*member->getBase()) : mutated(*member->getBase());
          return;
        }

        if (const auto* call = llvm::dyn_cast<clang::CXXMemberCallExpr>(current)) {
          if (const auto* object = call->getImplicitObjectArgument()) {
            leaked(*call, *object);
          }

          return;
        }

        if (const auto* call = llvm::dyn_cast<clang::CXXOperatorCallExpr>(current); call != nullptr && call->getOperator() == clang::OO_Arrow && call->getNumArgs() != 0) {
          leaked(*call, *call->getArg(0));
        }
      }

      // A smart pointer reached through shared access owns its object as a Rust `Box` does, so the
      // mutable access its const `get`, `*` and `->` hand out does not leave shared access.
      void leaked(const clang::CallExpr& call, const clang::Expr& object) {
        const auto* method = llvm::dyn_cast_or_null<clang::CXXMethodDecl>(call.getDirectCallee());
        const auto result = call.getCallReturnType(context_);
        const auto target = result->isPointerType() ? result->getPointeeType() : result.getNonReferenceType();
        if (method == nullptr || !method->isConst() || !(result->isPointerType() || result->isReferenceType()) || mayChangeShared(target, context_)) {
          return;
        }

        // The object a const method is called on is converted to const; whether it was is what counts.
        const auto type = object.IgnoreParenImpCasts()->getType();
        const auto owner = type->isPointerType() ? type->getPointeeType() : type;

        if (owner.isConstQualified() && smartPointer(owner)) {
          report(call.getExprLoc(), method->getNameAsString());
        }
      }

      void report(const clang::MemberExpr& member, const clang::FieldDecl& field) {
        report(member.getMemberLoc(), field.getNameAsString());
      }

      void report(clang::SourceLocation location, const std::string& name) {
        location = context_.getSourceManager().getExpansionLoc(location);
        if (location.isInvalid() || !reported_.insert(location.getRawEncoding()).second) {
          return;
        }

        auto& diagnostics = context_.getDiagnostics();
        const auto id = diagnostics.getCustomDiagID(errors_ ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning, "mutates what '%0' reaches through shared access, which lends it shared as Rust's `&T` does; make the access non-const, or the type shared [tbc-contract-violation]");

        diagnostics.Report(location, id) << name;
      }

      clang::ASTContext& context_;
      bool errors_;
      llvm::DenseSet<clang::SourceLocation::UIntTy> reported_;
    };
  }

  void checkSharedAccess(const clang::FunctionDecl& definition, clang::ASTContext& context, bool errors) {
    if (definition.getBody() == nullptr || definition.isDependentContext() || definition.isImplicit()) {
      return;
    }

    shared_access visitor(context, errors);

    visitor.TraverseStmt(definition.getBody());
  }
}
