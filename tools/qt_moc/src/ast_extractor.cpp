#include "ast_extractor.hpp"

#include <clang/AST/APValue.h>
#include <clang/AST/ASTContext.h>
#include <clang/AST/Attr.h>
#include <clang/AST/DeclCXX.h>
#include <clang/AST/Expr.h>
#include <clang/AST/PrettyPrinter.h>
#include <clang/AST/RecursiveASTVisitor.h>
#include <clang/Basic/Module.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/StringRef.h>

#include <string>

namespace {

  using namespace telar::qt_moc;

  std::string compactPointerSpacing(std::string text) {
    std::string out;

    out.reserve(text.size());
    for (std::size_t idx = 0; idx < text.size(); ++idx) {
      if (text[idx] == ' ' && idx + 1 < text.size() && (text[idx + 1] == '*' || text[idx + 1] == '&')) {
        continue;
      }

      out.push_back(text[idx]);
    }

    return out;
  }

  std::string formatType(const clang::ASTContext& context, clang::QualType type) {
    clang::PrintingPolicy policy(context.getLangOpts());

    policy.SuppressTagKeyword = true;
    policy.Bool = true;
    policy.UseVoidForZeroParams = false;
    policy.FullyQualifiedName = true;
    return compactPointerSpacing(type.getAsString(policy));
  }

  std::string normalizeQtType(const clang::ASTContext& context, clang::QualType type) {
    const auto base = type.getNonReferenceType().getUnqualifiedType();

    // An alias of an enum names the enum where it is declared, where QML finds it registered.
    if (base->getAs<clang::TypedefType>() != nullptr && base.getCanonicalType()->isEnumeralType()) {
      return formatType(context, base.getCanonicalType());
    }

    return formatType(context, base);
  }

  bool derivesFrom(const clang::CXXRecordDecl* record, llvm::StringRef target_name) {
    if (record == nullptr) {
      return false;
    }

    const auto* def = record->getDefinition();
    if (def == nullptr) {
      return false;
    }

    if (def->getName() == target_name) {
      return true;
    }

    for (const auto& base : def->bases()) {
      if (const auto* base_rec = base.getType()->getAsCXXRecordDecl()) {
        if (derivesFrom(base_rec, target_name)) {
          return true;
        }
      }
    }

    return false;
  }

  bool isQObjectPointer(clang::QualType type) {
    const auto non_ref = type.getNonReferenceType().getUnqualifiedType();
    if (!non_ref->isPointerType()) {
      return false;
    }

    const auto pointee = non_ref->getPointeeType().getUnqualifiedType();

    return derivesFrom(pointee->getAsCXXRecordDecl(), "QObject");
  }

  std::string stripAnonymousPrefix(std::string qualified) {
    constexpr std::string_view anon = "(anonymous namespace)::";

    for (auto pos = qualified.find(anon); pos != std::string::npos; pos = qualified.find(anon)) {
      qualified.erase(pos, anon.size());
    }

    return qualified;
  }

  Access toAccess(clang::AccessSpecifier spec) {
    switch (spec) {
    case clang::AS_public:
      return Access::public_;
    case clang::AS_protected:
      return Access::protected_;
    default:
      return Access::private_;
    }
  }

  bool hasAnnotation(const clang::Decl* decl, llvm::StringRef annotation) {
    for (const auto* attr : decl->specific_attrs<clang::AnnotateAttr>()) {
      if (attr->getAnnotation() == annotation) {
        return true;
      }
    }

    return false;
  }

  std::string extractStringLiteral(const clang::APValue& value) {
    if (!value.isLValue()) {
      return {};
    }

    const auto base = value.getLValueBase();
    const auto* expr = base.dyn_cast<const clang::Expr*>();
    if (expr == nullptr) {
      return {};
    }

    if (const auto* literal = llvm::dyn_cast<clang::StringLiteral>(expr->IgnoreParenImpCasts())) {
      return literal->getString().str();
    }

    return {};
  }

  const clang::CXXMethodDecl* extractMemberMethod(const clang::APValue& value) {
    if (value.isMemberPointer()) {
      return llvm::dyn_cast_or_null<clang::CXXMethodDecl>(value.getMemberPointerDecl());
    }

    if (value.isLValue()) {
      const auto* decl = value.getLValueBase().dyn_cast<const clang::ValueDecl*>();

      return llvm::dyn_cast_or_null<clang::CXXMethodDecl>(decl);
    }

    return nullptr;
  }

  void extractPropertyList(
      const clang::ASTContext& context,
      const clang::CXXRecordDecl* owner,
      const clang::APValue& value,
      unsigned line,
      std::vector<PropertyMeta>& out
  ) {
    if (!value.isStruct() || value.getStructNumFields() == 0) {
      return;
    }

    if (value.getStructNumFields() == 2) {
      const auto& head = value.getStructField(0);
      const auto& tail = value.getStructField(1);

      if (head.isStruct() && head.getStructNumFields() >= 8) {
        PropertyMeta prop;

        prop.name = extractStringLiteral(head.getStructField(0));
        prop.line = line;
        if (const auto* reader = extractMemberMethod(head.getStructField(1))) {
          const auto ret = reader->getReturnType();
          const auto ret_base = ret.getNonReferenceType().getUnqualifiedType();

          prop.read = reader->getNameAsString();
          prop.type = formatType(context, ret_base);
          prop.normalized_type = normalizeQtType(context, ret);
          prop.string_type = prop.normalized_type;
          prop.is_qobject_ptr = isQObjectPointer(ret);

          if (const auto* enum_type = ret_base->getAs<clang::EnumType>()) {
            const auto* enum_decl = enum_type->getDecl();
            if (enum_decl != nullptr && enum_decl->getDeclContext() == owner) {
              prop.string_type = enum_decl->getNameAsString();
            }
          }
        }

        if (const auto* writer = extractMemberMethod(head.getStructField(2))) {
          prop.write = writer->getNameAsString();
        }

        if (const auto* notifier = extractMemberMethod(head.getStructField(3))) {
          prop.notify = notifier->getNameAsString();
        }

        if (const auto* resetter = extractMemberMethod(head.getStructField(4))) {
          prop.reset = resetter->getNameAsString();
        }

        if (head.getStructField(5).isInt()) {
          prop.constant = head.getStructField(5).getInt().getBoolValue();
        }

        if (head.getStructField(6).isInt()) {
          prop.is_final = head.getStructField(6).getInt().getBoolValue();
        }

        if (head.getStructField(7).isInt()) {
          prop.required = head.getStructField(7).getInt().getBoolValue();
        }

        if (!prop.name.empty() && !prop.read.empty()) {
          out.push_back(std::move(prop));
        }
      }

      extractPropertyList(context, owner, tail, line, out);
    }
  }

  void extractClassInfos(const clang::Decl* decl, ClassMeta& meta) {
    for (const auto* attr : decl->specific_attrs<clang::AnnotateAttr>()) {
      llvm::StringRef text = attr->getAnnotation();

      if (text == "qt::qml_element") {
        meta.class_infos.push_back({"QML.Element", "auto"});
        meta.qml_exposed = true;
      } else if (text == "qt::qml_singleton") {
        meta.class_infos.push_back({"QML.Singleton", "true"});
        meta.qml_exposed = true;
      } else if (text.consume_front("qt::qml_named:")) {
        meta.class_infos.push_back({"QML.Element", text.str()});
        meta.qml_exposed = true;
      } else if (text.consume_front("qt::qml_uncreatable:")) {
        meta.class_infos.push_back({"QML.Creatable", "false"});
        meta.class_infos.push_back({"QML.UncreatableReason", text.str()});
      } else if (text.consume_front("qt::classinfo:")) {
        const auto [key, val] = text.split('=');

        meta.class_infos.push_back({key.str(), val.str()});
      }
    }
  }

  EnumMeta extractEnum(const clang::ASTContext& context, const clang::EnumDecl* decl) {
    EnumMeta meta;

    meta.name = decl->getNameAsString();
    meta.qualified_name = stripAnonymousPrefix(decl->getQualifiedNameAsString());
    meta.underlying_type = formatType(context, decl->getIntegerType());
    meta.is_scoped = decl->isScoped();
    meta.line = context.getSourceManager().getSpellingLineNumber(decl->getLocation());
    for (const auto* enumerator : decl->enumerators()) {
      meta.values.push_back({enumerator->getNameAsString(), enumerator->getInitVal().getExtValue()});
    }

    return meta;
  }

  void appendMethodWithDefaults(const clang::ASTContext& context, const clang::CXXMethodDecl* method, MethodKind kind, std::vector<MethodMeta>& target) {
    MethodMeta base_item;

    base_item.kind = kind;
    base_item.access = toAccess(method->getAccess());
    base_item.name = method->getNameAsString();
    base_item.return_type = formatType(context, method->getReturnType());
    base_item.normalized_return_type = normalizeQtType(context, method->getReturnType());
    base_item.is_const = method->isConst();
    base_item.is_static = method->isStatic();
    base_item.line = context.getSourceManager().getSpellingLineNumber(method->getLocation());

    std::size_t min_args = method->param_size();

    for (std::size_t idx = 0; idx < method->param_size(); ++idx) {
      const auto* param = method->getParamDecl(static_cast<unsigned>(idx));
      if (param->hasDefaultArg() && min_args == method->param_size()) {
        min_args = idx;
      }

      base_item.params.push_back({
          .name = param->getNameAsString(),
          .type = formatType(context, param->getType()),
          .normalized_type = normalizeQtType(context, param->getType()),
          .is_qobject_ptr = isQObjectPointer(param->getType()),
      });
    }

    target.push_back(base_item);
    for (std::size_t count = base_item.params.size(); count > min_args; --count) {
      MethodMeta cloned = base_item;

      cloned.params.resize(count - 1);
      cloned.is_cloned = true;
      target.push_back(std::move(cloned));
    }
  }

  class ExtractorVisitor final : public clang::RecursiveASTVisitor<ExtractorVisitor> {
  public:
    ExtractorVisitor(clang::ASTContext& context, UnitMeta& output)
        : context_(context),
          output_(output) {}

    bool VisitNamespaceDecl(clang::NamespaceDecl* ns) {
      if (!context_.getSourceManager().isInMainFile(ns->getLocation()) || !hasAnnotation(ns, "qt::ns")) {
        return true;
      }

      ClassMeta meta;

      meta.module_name = output_.module_name;
      meta.class_name = ns->getNameAsString();
      meta.qualified_name = ns->getQualifiedNameAsString();
      meta.is_namespace = true;
      meta.line = context_.getSourceManager().getSpellingLineNumber(ns->getLocation());
      extractClassInfos(ns, meta);
      for (const auto* decl : ns->decls()) {
        if (const auto* enum_decl = llvm::dyn_cast<clang::EnumDecl>(decl)) {
          if (enum_decl->isThisDeclarationADefinition() && hasAnnotation(enum_decl, "qt::qenum")) {
            meta.enums.push_back(extractEnum(context_, enum_decl));
          }
        }
      }

      output_.classes.push_back(std::move(meta));
      return true;
    }

    bool VisitCXXRecordDecl(clang::CXXRecordDecl* record) {
      if (!record->isThisDeclarationADefinition() || !hasAnnotation(record, "qt::object")) {
        return true;
      }

      if (!context_.getSourceManager().isInMainFile(record->getLocation())) {
        return true;
      }

      ClassMeta meta;

      meta.module_name = output_.module_name;
      meta.class_name = record->getNameAsString();
      meta.is_anonymous_ns = record->isInAnonymousNamespace();
      meta.qualified_name = stripAnonymousPrefix(record->getQualifiedNameAsString());
      meta.inherits_quick_item = derivesFrom(record, "QQuickItem");
      meta.line = context_.getSourceManager().getSpellingLineNumber(record->getLocation());
      if (record->getNumBases() > 0) {
        const auto& base = *record->bases_begin();

        meta.super_class = formatType(context_, base.getType());
      }

      extractClassInfos(record, meta);

      for (const auto* decl : record->decls()) {
        if (const auto* method = llvm::dyn_cast<clang::CXXMethodDecl>(decl)) {
          if (hasAnnotation(method, "qt::signal")) {
            appendMethodWithDefaults(context_, method, MethodKind::signal, meta.signals);
          } else if (hasAnnotation(method, "qt::slot")) {
            appendMethodWithDefaults(context_, method, MethodKind::slot, meta.slots);
          } else if (hasAnnotation(method, "qt::invokable")) {
            appendMethodWithDefaults(context_, method, MethodKind::invokable, meta.invokables);
          }
        } else if (const auto* enum_decl = llvm::dyn_cast<clang::EnumDecl>(decl)) {
          if (enum_decl->isThisDeclarationADefinition() && hasAnnotation(enum_decl, "qt::qenum")) {
            meta.enums.push_back(extractEnum(context_, enum_decl));
          }
        } else if (const auto* var = llvm::dyn_cast<clang::VarDecl>(decl)) {
          if (var->isStaticDataMember() && var->getName() == "qt_properties") {
            if (const auto* value = var->evaluateValue()) {
              const auto line = context_.getSourceManager().getSpellingLineNumber(var->getLocation());

              extractPropertyList(context_, record, *value, line, meta.properties);
            }
          }
        }
      }

      for (auto& prop : meta.properties) {
        if (!prop.notify.empty()) {
          for (std::size_t idx = 0; idx < meta.signals.size(); ++idx) {
            if (meta.signals[idx].name == prop.notify && !meta.signals[idx].is_cloned) {
              prop.notify_index = static_cast<int>(idx);
              break;
            }
          }
        }
      }

      output_.classes.push_back(std::move(meta));
      return true;
    }

  private:
    clang::ASTContext& context_;
    UnitMeta& output_;
  };

  class ExtractorConsumer final : public clang::ASTConsumer {
  public:
    explicit ExtractorConsumer(UnitMeta& output)
        : output_(output) {}

    void HandleTranslationUnit(clang::ASTContext& context) override {
      if (const auto* mod = context.getCurrentNamedModule()) {
        output_.module_name = mod->getFullModuleName();
      }

      const auto self_primary = primaryModuleName(output_.module_name);
      const auto& sources = context.getSourceManager();

      for (const auto* decl : context.getTranslationUnitDecl()->noload_decls()) {
        const auto* import_decl = llvm::dyn_cast<clang::ImportDecl>(decl);
        if (import_decl == nullptr || !sources.isInMainFile(import_decl->getLocation())) {
          continue;
        }

        if (const auto* imported = import_decl->getImportedModule()) {
          const auto full = imported->getFullModuleName();
          const auto primary = primaryModuleName(full);
          if (!primary.empty() && primary != self_primary && full.find(':') == std::string::npos) {
            output_.imported_modules.push_back(primary);
          }
        }
      }

      ExtractorVisitor visitor(context, output_);

      visitor.TraverseDecl(context.getTranslationUnitDecl());
    }

  private:
    UnitMeta& output_;
  };

}

namespace telar::qt_moc {

  std::unique_ptr<clang::ASTConsumer> createExtractorConsumer(UnitMeta& output) {
    return std::make_unique<ExtractorConsumer>(output);
  }

}
