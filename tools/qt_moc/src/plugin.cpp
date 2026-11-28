#include "attributes.hpp"

#include <clang/AST/ASTConsumer.h>
#include <clang/AST/ASTContext.h>
#include <clang/AST/Attr.h>
#include <clang/AST/DeclCXX.h>
#include <clang/AST/RecursiveASTVisitor.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/FrontendAction.h>
#include <clang/Frontend/FrontendPluginRegistry.h>
#include <llvm/ADT/StringRef.h>

#include <memory>
#include <string>
#include <vector>

namespace {

  bool hasAnnotation(const clang::Decl* decl, llvm::StringRef annotation) {
    for (const auto* attr : decl->specific_attrs<clang::AnnotateAttr>()) {
      if (attr->getAnnotation() == annotation) {
        return true;
      }
    }

    return false;
  }

  // Validates that every [[qt::object]] class declares the 5 direct meta-object members required by
  // Qt 6.12's HasQ_OBJECT_Macro and QMetaObject linkage.
  class QtObjectValidator final : public clang::RecursiveASTVisitor<QtObjectValidator> {
  public:
    explicit QtObjectValidator(clang::ASTContext& context)
        : context_(context) {}

    bool VisitCXXRecordDecl(clang::CXXRecordDecl* record) {
      if (!record->isThisDeclarationADefinition() || !hasAnnotation(record, "qt::object")) {
        return true;
      }

      if (!context_.getSourceManager().isInMainFile(record->getLocation())) {
        return true;
      }

      bool has_static_meta = false;
      bool has_meta_object = false;
      bool has_metacast = false;
      bool has_metacall = false;
      bool has_static_metacall = false;

      for (const auto* decl : record->decls()) {
        if (const auto* var = llvm::dyn_cast<clang::VarDecl>(decl)) {
          if (var->isStaticDataMember() && var->getName() == "staticMetaObject") {
            has_static_meta = true;
          }
        } else if (const auto* method = llvm::dyn_cast<clang::CXXMethodDecl>(decl)) {
          const auto name = method->getName();
          if (name == "metaObject") {
            has_meta_object = true;
          } else if (name == "qt_metacast") {
            has_metacast = true;
          } else if (name == "qt_metacall") {
            has_metacall = true;
          } else if (name == "qt_static_metacall" && method->isStatic()) {
            has_static_metacall = true;
          }
        }
      }

      auto& diagnostics = context_.getDiagnostics();
      const auto missing = [&](llvm::StringRef member) {
        const auto id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, "[[qt::object]] class '%0' must directly declare '%1'");

        diagnostics.Report(record->getLocation(), id) << record->getName() << member;
      };

      if (!has_static_meta) {
        missing("static const QMetaObject staticMetaObject");
      }

      if (!has_meta_object) {
        missing("const QMetaObject* metaObject() const override");
      }

      if (!has_metacast) {
        missing("void* qt_metacast(const char*) override");
      }

      if (!has_metacall) {
        missing("int qt_metacall(QMetaObject::Call, int, void**) override");
      }

      if (!has_static_metacall) {
        missing("static void qt_static_metacall(QObject*, QMetaObject::Call, int, void**)");
      }

      return true;
    }

  private:
    clang::ASTContext& context_;
  };

  class QtPluginConsumer final : public clang::ASTConsumer {
  public:
    void HandleTranslationUnit(clang::ASTContext& context) override {
      QtObjectValidator validator(context);

      validator.TraverseDecl(context.getTranslationUnitDecl());
    }
  };

  class QtPluginAction final : public clang::PluginASTAction {
  public:
    QtPluginAction() {
      telar::qt_moc::registerAttributes();
    }

    ActionType getActionType() override {
      return AddBeforeMainAction;
    }

  protected:
    bool ParseArgs(const clang::CompilerInstance& /*compiler*/, const std::vector<std::string>& /*arguments*/) override {
      return true;
    }

    std::unique_ptr<clang::ASTConsumer> CreateASTConsumer(clang::CompilerInstance& compiler, llvm::StringRef /*file*/) override {
      if (!compiler.getLangOpts().CPlusPlus) {
        return std::make_unique<clang::ASTConsumer>();
      }

      return std::make_unique<QtPluginConsumer>();
    }
  };

  // NOLINTNEXTLINE(bugprone-throwing-static-initialization)
  const clang::FrontendPluginRegistry::Add<QtPluginAction> registration("telar-qt", "Telar Qt module attribute registration and validation.");

}
