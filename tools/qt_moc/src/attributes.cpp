#include "attributes.hpp"

#include <clang/AST/ASTContext.h>
#include <clang/AST/Attr.h>
#include <clang/AST/Decl.h>
#include <clang/AST/Expr.h>
#include <clang/Basic/AttributeCommonInfo.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/ParsedAttrInfo.h>
#include <clang/Sema/ParsedAttr.h>
#include <clang/Sema/Sema.h>
#include <llvm/ADT/StringRef.h>

#include <array>
#include <cstddef>
#include <string>

namespace {

  // Lowers a zero-argument [[qt::<name>]] attribute into clang::AnnotateAttr so it serializes into C++23 module BMIs.
  template <typename Spec>
  class QtFlagAttrInfo final : public clang::ParsedAttrInfo {
  public:
    QtFlagAttrInfo() {
      static constexpr std::array<Spelling, 1> spellings{{
          {.Syntax = clang::ParsedAttr::AS_CXX11, .NormalizedFullName = Spec::scoped},
      }};

      Spellings = spellings;
    }

    AttrHandling handleDeclAttribute(clang::Sema& sema, clang::Decl* declaration, const clang::ParsedAttr& attribute) const override {
      if (declaration == nullptr) {
        return AttributeNotApplied;
      }

      if (attribute.getNumArgs() != 0) {
        auto& diagnostics = sema.getDiagnostics();
        const auto id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, "'%0' attribute takes no arguments");

        diagnostics.Report(attribute.getLoc(), id) << Spec::scoped;
        return AttributeNotApplied;
      }

      declaration->addAttr(clang::AnnotateAttr::CreateImplicit(sema.Context, Spec::scoped, attribute));
      return AttributeApplied;
    }
  };

  // Lowers a single-string-argument [[qt::<name>("value")]] attribute into AnnotateAttr("qt::<name>:<value>").
  template <typename Spec>
  class QtStringAttrInfo final : public clang::ParsedAttrInfo {
  public:
    QtStringAttrInfo() {
      OptArgs = 15;
      static constexpr std::array<Spelling, 1> spellings{{
          {.Syntax = clang::ParsedAttr::AS_CXX11, .NormalizedFullName = Spec::unscoped},
      }};

      Spellings = spellings;
    }

    [[nodiscard]] bool isParamExpr(std::size_t /*index*/) const override {
      return true;
    }

    AttrHandling handleDeclAttribute(clang::Sema& sema, clang::Decl* declaration, const clang::ParsedAttr& attribute) const override {
      if (declaration == nullptr) {
        return AttributeNotApplied;
      }

      auto& diagnostics = sema.getDiagnostics();

      if (attribute.getNumArgs() != 1 || attribute.isArgIdent(0)) {
        const auto id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, "'%0' requires one string literal argument");

        diagnostics.Report(attribute.getLoc(), id) << Spec::unscoped;
        return AttributeNotApplied;
      }

      const auto* literal = llvm::dyn_cast_or_null<clang::StringLiteral>(attribute.getArgAsExpr(0)->IgnoreParenImpCasts());
      if (literal == nullptr || literal->getString().empty()) {
        const auto id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, "'%0' argument must be a non-empty string literal");

        diagnostics.Report(attribute.getLoc(), id) << Spec::unscoped;
        return AttributeNotApplied;
      }

      const std::string encoded = std::string(Spec::scoped) + ":" + literal->getString().str();

      declaration->addAttr(clang::AnnotateAttr::CreateImplicit(sema.Context, encoded, attribute));
      return AttributeApplied;
    }
  };

  // Lowers [[qt_classinfo("key", "value")]] into AnnotateAttr("qt::classinfo:<key>=<value>").
  class QtClassInfoAttrInfo final : public clang::ParsedAttrInfo {
  public:
    QtClassInfoAttrInfo() {
      OptArgs = 15;
      static constexpr std::array<Spelling, 1> spellings{{
          {.Syntax = clang::ParsedAttr::AS_CXX11, .NormalizedFullName = "qt_classinfo"},
      }};

      Spellings = spellings;
    }

    [[nodiscard]] bool isParamExpr(std::size_t /*index*/) const override {
      return true;
    }

    AttrHandling handleDeclAttribute(clang::Sema& sema, clang::Decl* declaration, const clang::ParsedAttr& attribute) const override {
      if (declaration == nullptr) {
        return AttributeNotApplied;
      }

      auto& diagnostics = sema.getDiagnostics();

      if (attribute.getNumArgs() != 2 || attribute.isArgIdent(0) || attribute.isArgIdent(1)) {
        const auto id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, "'qt_classinfo' requires two string literal arguments");

        diagnostics.Report(attribute.getLoc(), id);
        return AttributeNotApplied;
      }

      const auto* key = llvm::dyn_cast_or_null<clang::StringLiteral>(attribute.getArgAsExpr(0)->IgnoreParenImpCasts());
      const auto* value = llvm::dyn_cast_or_null<clang::StringLiteral>(attribute.getArgAsExpr(1)->IgnoreParenImpCasts());
      if (key == nullptr || value == nullptr || key->getString().empty()) {
        const auto id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, "'qt_classinfo' arguments must be string literals with a non-empty key");

        diagnostics.Report(attribute.getLoc(), id);
        return AttributeNotApplied;
      }

      const std::string encoded = "qt::classinfo:" + key->getString().str() + "=" + value->getString().str();

      declaration->addAttr(clang::AnnotateAttr::CreateImplicit(sema.Context, encoded, attribute));
      return AttributeApplied;
    }
  };

  struct ObjectSpec {
    static constexpr const char* scoped = "qt::object";
  };

  struct NamespaceSpec {
    static constexpr const char* scoped = "qt::ns";
  };

  struct SignalSpec {
    static constexpr const char* scoped = "qt::signal";
  };

  struct SlotSpec {
    static constexpr const char* scoped = "qt::slot";
  };

  struct InvokableSpec {
    static constexpr const char* scoped = "qt::invokable";
  };

  struct EnumSpec {
    static constexpr const char* scoped = "qt::qenum";
  };

  struct QmlElementSpec {
    static constexpr const char* scoped = "qt::qml_element";
  };

  struct QmlSingletonSpec {
    static constexpr const char* scoped = "qt::qml_singleton";
  };

  struct QmlNamedSpec {
    static constexpr const char* scoped = "qt::qml_named";
    static constexpr const char* unscoped = "qt_qml_named";
  };

  struct QmlUncreatableSpec {
    static constexpr const char* scoped = "qt::qml_uncreatable";
    static constexpr const char* unscoped = "qt_qml_uncreatable";
  };

  // NOLINTBEGIN(bugprone-throwing-static-initialization)
  const clang::ParsedAttrInfoRegistry::Add<QtFlagAttrInfo<ObjectSpec>> reg_object("qt_object", "Marks a Qt QObject subclass.");
  const clang::ParsedAttrInfoRegistry::Add<QtFlagAttrInfo<NamespaceSpec>> reg_ns("qt_ns", "Marks a Qt meta-object namespace.");
  const clang::ParsedAttrInfoRegistry::Add<QtFlagAttrInfo<SignalSpec>> reg_signal("qt_signal", "Marks a Qt signal method.");
  const clang::ParsedAttrInfoRegistry::Add<QtFlagAttrInfo<SlotSpec>> reg_slot("qt_slot", "Marks a Qt slot method.");
  const clang::ParsedAttrInfoRegistry::Add<QtFlagAttrInfo<InvokableSpec>> reg_invokable("qt_invokable", "Marks a Qt invokable method.");
  const clang::ParsedAttrInfoRegistry::Add<QtFlagAttrInfo<EnumSpec>> reg_qenum("qt_qenum", "Marks a Qt meta-object enum.");
  const clang::ParsedAttrInfoRegistry::Add<QtFlagAttrInfo<QmlElementSpec>> reg_qml_element("qt_qml_element", "Exposes a Qt class to QML.");
  const clang::ParsedAttrInfoRegistry::Add<QtFlagAttrInfo<QmlSingletonSpec>> reg_qml_singleton("qt_qml_singleton", "Exposes a Qt class as a QML singleton.");
  const clang::ParsedAttrInfoRegistry::Add<QtStringAttrInfo<QmlNamedSpec>> reg_qml_named("qt_qml_named", "Exposes a Qt class to QML under an explicit name.");
  const clang::ParsedAttrInfoRegistry::Add<QtStringAttrInfo<QmlUncreatableSpec>> reg_qml_uncreatable("qt_qml_uncreatable", "Marks a QML type as uncreatable.");
  const clang::ParsedAttrInfoRegistry::Add<QtClassInfoAttrInfo> reg_classinfo("qt_classinfo", "Attaches a Qt Q_CLASSINFO key/value pair.");
  // NOLINTEND(bugprone-throwing-static-initialization)

}

namespace telar::qt_moc {

  void registerAttributes() noexcept {}

}
