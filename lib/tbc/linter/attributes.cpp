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
  // Translates a zero-argument custom `[[tbc::<name>]]` attribute (and GNU `__attribute__((tbc_<name>))`
  // for C/Objective-C headers) into a standard `clang::AnnotateAttr` so it serializes into C++23
  // module BMIs and is read uniformly by every tbc pass.
  template <typename spec>
  class tbc_flag_attr_info final : public clang::ParsedAttrInfo {
  public:
    tbc_flag_attr_info() {
      static constexpr std::array<Spelling, 3> spellings{{
          {.Syntax = clang::ParsedAttr::AS_CXX11, .NormalizedFullName = spec::scoped},
          {.Syntax = clang::ParsedAttr::AS_C23, .NormalizedFullName = spec::scoped},
          {.Syntax = clang::ParsedAttr::AS_GNU, .NormalizedFullName = spec::gnu},
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

        diagnostics.Report(attribute.getLoc(), id) << spec::scoped;
        return AttributeNotApplied;
      }

      declaration->addAttr(clang::AnnotateAttr::CreateImplicit(sema.Context, spec::scoped, attribute));
      return AttributeApplied;
    }
  };

  // Translates `[[tbc_outlives("longer", "shorter")]]` (or GNU `__attribute__((tbc_outlives(...)))`)
  // into `AnnotateAttr("tbc::outlives:<longer>:<shorter>")`.
  class tbc_outlives_attr_info final : public clang::ParsedAttrInfo {
  public:
    tbc_outlives_attr_info() {
      OptArgs = 15;
      static constexpr std::array<Spelling, 3> spellings{{
          {.Syntax = clang::ParsedAttr::AS_CXX11, .NormalizedFullName = "tbc_outlives"},
          {.Syntax = clang::ParsedAttr::AS_C23, .NormalizedFullName = "tbc_outlives"},
          {.Syntax = clang::ParsedAttr::AS_GNU, .NormalizedFullName = "tbc_outlives"},
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
        const auto id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, R"('tbc_outlives' requires two string literal region names, e.g. [[tbc_outlives("b", "a")]])");

        diagnostics.Report(attribute.getLoc(), id);
        return AttributeNotApplied;
      }

      const auto* first = llvm::dyn_cast_or_null<clang::StringLiteral>(attribute.getArgAsExpr(0)->IgnoreParenImpCasts());
      const auto* second = llvm::dyn_cast_or_null<clang::StringLiteral>(attribute.getArgAsExpr(1)->IgnoreParenImpCasts());
      if (first == nullptr || second == nullptr || first->getString().empty() || second->getString().empty()) {
        const auto id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Error, "'tbc_outlives' arguments must be non-empty string literals");

        diagnostics.Report(attribute.getLoc(), id);
        return AttributeNotApplied;
      }

      const std::string encoded = "tbc::outlives:" + first->getString().str() + ":" + second->getString().str();

      declaration->addAttr(clang::AnnotateAttr::CreateImplicit(sema.Context, encoded, attribute));
      return AttributeApplied;
    }
  };

  struct shared_spec {
    static constexpr const char* scoped = "tbc::shared";
    static constexpr const char* gnu = "tbc_shared";
  };

  struct owner_spec {
    static constexpr const char* scoped = "tbc::owner";
    static constexpr const char* gnu = "tbc_owner";
  };

  struct raw_spec {
    static constexpr const char* scoped = "tbc::raw";
    static constexpr const char* gnu = "tbc_raw";
  };

  struct hot_path_spec {
    static constexpr const char* scoped = "tbc::hot_path";
    static constexpr const char* gnu = "tbc_hot_path";
  };

  struct generic_spec {
    static constexpr const char* scoped = "tbc::generic";
    static constexpr const char* gnu = "tbc_generic";
  };

  struct constructs_spec {
    static constexpr const char* scoped = "tbc::constructs";
    static constexpr const char* gnu = "tbc_constructs";
  };

  struct swaps_spec {
    static constexpr const char* scoped = "tbc::swaps";
    static constexpr const char* gnu = "tbc_swaps";
  };

  struct uninitialized_spec {
    static constexpr const char* scoped = "tbc::uninitialized";
    static constexpr const char* gnu = "tbc_uninitialized";
  };

  struct initializes_spec {
    static constexpr const char* scoped = "tbc::initializes";
    static constexpr const char* gnu = "tbc_initializes";
  };

  // NOLINTBEGIN(bugprone-throwing-static-initialization)
  const clang::ParsedAttrInfoRegistry::Add<tbc_flag_attr_info<shared_spec>> reg_shared("tbc_shared", "Marks a type with interior mutability.");
  const clang::ParsedAttrInfoRegistry::Add<tbc_flag_attr_info<owner_spec>> reg_owner("tbc_owner", "Marks an owning smart-pointer template.");
  const clang::ParsedAttrInfoRegistry::Add<tbc_flag_attr_info<raw_spec>> reg_raw("tbc_raw", "Marks an untracked raw/FFI boundary.");
  const clang::ParsedAttrInfoRegistry::Add<tbc_flag_attr_info<hot_path_spec>> reg_hot_path("tbc_hot_path", "Marks an inline hot path in a module interface.");
  const clang::ParsedAttrInfoRegistry::Add<tbc_flag_attr_info<generic_spec>> reg_generic("tbc_generic", "Marks a caller-instantiated template in a module interface.");
  const clang::ParsedAttrInfoRegistry::Add<tbc_flag_attr_info<constructs_spec>> reg_constructs("tbc_constructs", "Marks a forwarding factory function or constructor.");
  const clang::ParsedAttrInfoRegistry::Add<tbc_flag_attr_info<swaps_spec>> reg_swaps("tbc_swaps", "Marks an ownership-exchanging swap function.");
  const clang::ParsedAttrInfoRegistry::Add<tbc_flag_attr_info<uninitialized_spec>> reg_uninitialized("tbc_uninitialized", "Marks a function returning uninitialized storage.");
  const clang::ParsedAttrInfoRegistry::Add<tbc_flag_attr_info<initializes_spec>> reg_initializes("tbc_initializes", "Marks a function initializing its buffer argument.");
  const clang::ParsedAttrInfoRegistry::Add<tbc_outlives_attr_info> reg_outlives("tbc_outlives", "Declares a directional lifetime outlives bound.");
  // NOLINTEND(bugprone-throwing-static-initialization)
}

namespace tbc_lint {
  void registerAttributes() noexcept {}
}
