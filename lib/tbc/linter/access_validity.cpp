#include "access_validity.hpp"

#include "view_type.hpp"

#include <clang/AST/Expr.h>
#include <clang/AST/ExprCXX.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/DenseMap.h>
#include <llvm/ADT/SmallPtrSet.h>
#include <llvm/ADT/SmallVector.h>

#include <algorithm>
#include <cstdint>
#include <optional>
#include <tuple>
#include <utility>

namespace tbc_lint {
  namespace {
    const clang::Expr* stripExpr(const clang::Expr* expr) {
      while (expr != nullptr) {
        const auto* next = expr->IgnoreParenImpCasts();
        if (const auto* cleanups = llvm::dyn_cast<clang::ExprWithCleanups>(next)) {
          next = cleanups->getSubExpr();
        } else if (const auto* bind = llvm::dyn_cast<clang::CXXBindTemporaryExpr>(next)) {
          next = bind->getSubExpr();
        }

        if (next == expr) {
          break;
        }

        expr = next;
      }

      return expr;
    }

    // Identifies a variable or a field chain (e.g. `values`, `this->slots_`, `state.values`,
    // `client.session.log`) as a single stable pointer for O(1) lookup. For a member chain whose root
    // is a variable/field, the leaf FieldDecl is used when the root is `this` or a single-owner param.
    const clang::ValueDecl* baseDecl(const clang::Expr* expr) {
      expr = stripExpr(expr);
      while (const auto* ctor = llvm::dyn_cast_or_null<clang::CXXConstructExpr>(expr)) {
        if (ctor->getNumArgs() == 1 && (ctor->getConstructor()->isCopyOrMoveConstructor() || viewType(ctor->getType()))) {
          expr = stripExpr(ctor->getArg(0));
        } else {
          break;
        }
      }

      if (const auto* ref = llvm::dyn_cast_or_null<clang::DeclRefExpr>(expr)) {
        return ref->getDecl();
      }

      if (const auto* member = llvm::dyn_cast_or_null<clang::MemberExpr>(expr)) {
        return member->getMemberDecl();
      }

      return nullptr;
    }

    bool isNullLiteral(const clang::Expr* expr) {
      expr = stripExpr(expr);
      if (expr == nullptr) {
        return false;
      }

      if (llvm::isa<clang::CXXNullPtrLiteralExpr>(expr) || llvm::isa<clang::GNUNullExpr>(expr)) {
        return true;
      }

      if (const auto* integer = llvm::dyn_cast<clang::IntegerLiteral>(expr)) {
        return integer->getValue() == 0;
      }

      return false;
    }

    bool isZeroLiteral(const clang::Expr* expr) {
      expr = stripExpr(expr);
      if (const auto* integer = llvm::dyn_cast_or_null<clang::IntegerLiteral>(expr)) {
        return integer->getValue() == 0;
      }

      return false;
    }

    std::optional<std::uint64_t> constantUnsigned(const clang::Expr* expr, const clang::ASTContext& context) {
      expr = stripExpr(expr);
      if (expr == nullptr || expr->isValueDependent()) {
        return std::nullopt;
      }

      clang::Expr::EvalResult eval;
      if (expr->EvaluateAsInt(eval, context)) {
        const auto value = eval.Val.getInt();
        if (!value.isNegative()) {
          return value.getZExtValue();
        }
      }

      return std::nullopt;
    }

    // Fixed static extent of an array, std::array, telar::ds::Array, fixed-extent std::span,
    // or a constexpr std::string_view initialized from a string literal.
    std::optional<std::uint64_t> staticExtent(clang::QualType type) {
      type = type.getNonReferenceType().getCanonicalType();
      if (const auto* constant_array = llvm::dyn_cast<clang::ConstantArrayType>(type.getTypePtr())) {
        return constant_array->getSize().getZExtValue();
      }

      const auto* specialization = llvm::dyn_cast_or_null<clang::ClassTemplateSpecializationDecl>(recordOf(type));
      if (specialization == nullptr) {
        return std::nullopt;
      }

      const auto name = specialization->getName();
      const auto args = specialization->getTemplateArgs().asArray();
      if ((name == "array" || name == "Array" || name == "span") && args.size() >= 2 && args[1].getKind() == clang::TemplateArgument::Integral) {
        const auto extent = args[1].getAsIntegral();
        // std::dynamic_extent is static_cast<size_t>(-1).
        if (!extent.isAllOnes() && !extent.isNegative()) {
          return extent.getZExtValue();
        }
      }

      return std::nullopt;
    }

    std::optional<std::uint64_t> exprStaticExtent(const clang::Expr* expr) {
      if (expr == nullptr) {
        return std::nullopt;
      }

      if (const auto extent = staticExtent(expr->getType())) {
        return extent;
      }

      expr = stripExpr(expr);
      if (const auto* ref = llvm::dyn_cast_or_null<clang::DeclRefExpr>(expr)) {
        if (const auto* var = llvm::dyn_cast<clang::VarDecl>(ref->getDecl()); var != nullptr && var->isConstexpr() && var->hasInit()) {
          const auto* init = stripExpr(var->getInit());
          if (const auto* ctor = llvm::dyn_cast_or_null<clang::CXXConstructExpr>(init); ctor != nullptr && ctor->getNumArgs() >= 1) {
            init = stripExpr(ctor->getArg(0));
          }

          if (const auto* literal = llvm::dyn_cast_or_null<clang::StringLiteral>(init)) {
            return literal->getLength();
          }
        }
      }

      return std::nullopt;
    }

    // Whether `expr` is a call to `<container>.size()` or `<container>.length()`, returning the container decl.
    const clang::ValueDecl* sizeCallContainer(const clang::Expr* expr) {
      const auto* call = llvm::dyn_cast_or_null<clang::CXXMemberCallExpr>(stripExpr(expr));
      if (call == nullptr || call->getNumArgs() != 0) {
        return nullptr;
      }

      const auto* method = call->getMethodDecl();
      if (method == nullptr || method->getIdentifier() == nullptr) {
        return nullptr;
      }

      const auto name = method->getName();
      if (name != "size" && name != "length") {
        return nullptr;
      }

      return baseDecl(call->getImplicitObjectArgument());
    }

    // Whether `expr` is `<container>.empty()`, returning the container decl.
    const clang::ValueDecl* emptyCallContainer(const clang::Expr* expr) {
      const auto* call = llvm::dyn_cast_or_null<clang::CXXMemberCallExpr>(stripExpr(expr));
      if (call == nullptr || call->getNumArgs() != 0) {
        return nullptr;
      }

      const auto* method = call->getMethodDecl();
      if (method == nullptr || method->getIdentifier() == nullptr || method->getName() != "empty") {
        return nullptr;
      }

      return baseDecl(call->getImplicitObjectArgument());
    }

    bool isIndexedContainerType(clang::QualType type) {
      type = type.getNonReferenceType();
      if (type->isArrayType()) {
        return true;
      }

      const auto* record = recordOf(type);
      if (record == nullptr || record->getIdentifier() == nullptr) {
        return false;
      }

      const auto name = record->getName();

      return standardType(type, "span") || standardType(type, "vector") || standardType(type, "array") || standardType(type, "basic_string") || standardType(type, "basic_string_view") || name == "Vec" || name == "Array" || name == "String";
    }

    bool isUninitializedProducer(const clang::FunctionDecl* callee) {
      if (callee == nullptr) {
        return false;
      }

      if (annotated(*callee, "tbc::uninitialized")) {
        return true;
      }

      if (const auto* pattern = callee->getTemplateInstantiationPattern(); pattern != nullptr && annotated(*pattern, "tbc::uninitialized")) {
        return true;
      }

      return false;
    }

    bool isBufferInitializer(const clang::FunctionDecl* callee) {
      if (callee == nullptr) {
        return false;
      }

      if (annotated(*callee, "tbc::initializes")) {
        return true;
      }

      if (const auto* pattern = callee->getTemplateInstantiationPattern(); pattern != nullptr && annotated(*pattern, "tbc::initializes")) {
        return true;
      }

      if (callee->getIdentifier() == nullptr) {
        return false;
      }

      const auto name = callee->getName();

      return name == "memcpy" || name == "memset" || name == "memmove" || name == "fill" || name == "fill_n" || name == "copy" || name == "copy_n";
    }

    // Dataflow state tracked per CFG block.
    // Must-analysis for non_null and bounds (intersection at joins), may-analysis for uninitialized
    // and nullable_vars (union at joins).
    struct access_state {
      bool initialized = false;
      llvm::SmallPtrSet<const clang::ValueDecl*, 8> non_null;
      llvm::SmallPtrSet<const clang::ValueDecl*, 8> nullable_vars;
      // Pairs (index_decl, container_decl) proven to satisfy index < container.size().
      llvm::SmallVector<std::pair<const clang::ValueDecl*, const clang::ValueDecl*>, 8> bounded;
      // Triples (index_decl, container_decl, offset) proven to satisfy index + offset < container.size().
      llvm::SmallVector<std::tuple<const clang::ValueDecl*, const clang::ValueDecl*, std::uint64_t>, 4> plus_bounded;
      // Pairs (size_var, container_decl) where size_var <= container_decl.size() (e.g. `n = c.size()`).
      llvm::SmallVector<std::pair<const clang::ValueDecl*, const clang::ValueDecl*>, 4> size_aliases;
      // Post-increment expressions `i++` whose pre-increment value was proven < container.size().
      llvm::SmallVector<std::pair<const clang::Expr*, const clang::ValueDecl*>, 4> bounded_exprs;
      // Known constant upper bound on unsigned integer variables (e.g. `slot = 0` -> upper 0).
      llvm::DenseMap<const clang::ValueDecl*, std::uint64_t> max_value;
      // Known constant lower bound on unsigned integer variables (e.g. `index != 0` -> lower 1).
      llvm::DenseMap<const clang::ValueDecl*, std::uint64_t> min_value;
      // Containers proven to have size >= min_known_size.
      llvm::DenseMap<const clang::ValueDecl*, std::uint64_t> min_size;
      // Variables that may currently hold uninitialized values or uninitialized writable buffers.
      llvm::SmallPtrSet<const clang::ValueDecl*, 8> uninitialized;

      [[nodiscard]] bool hasBound(const clang::ValueDecl* index, const clang::ValueDecl* container) const {
        return llvm::any_of(bounded, [&](const auto& pair) {
          return pair.first == index && pair.second == container;
        });
      }

      void addBound(const clang::ValueDecl* index, const clang::ValueDecl* container) {
        if (index != nullptr && container != nullptr && !hasBound(index, container)) {
          bounded.emplace_back(index, container);
        }
      }

      [[nodiscard]] bool hasPlusBound(const clang::ValueDecl* index, const clang::ValueDecl* container, std::uint64_t offset) const {
        if (offset == 0 && hasBound(index, container)) {
          return true;
        }

        return llvm::any_of(plus_bounded, [&](const auto& entry) {
          return std::get<0>(entry) == index && std::get<1>(entry) == container && std::get<2>(entry) >= offset;
        });
      }

      void addPlusBound(const clang::ValueDecl* index, const clang::ValueDecl* container, std::uint64_t offset) {
        if (index == nullptr || container == nullptr) {
          return;
        }

        addBound(index, container);
        if (offset == 0) {
          return;
        }

        for (auto& entry : plus_bounded) {
          if (std::get<0>(entry) == index && std::get<1>(entry) == container) {
            if (offset > std::get<2>(entry)) {
              std::get<2>(entry) = offset;
            }

            return;
          }
        }

        plus_bounded.emplace_back(index, container, offset);
      }

      void addSizeAlias(const clang::ValueDecl* alias, const clang::ValueDecl* container) {
        if (alias == nullptr || container == nullptr) {
          return;
        }

        const bool exists = llvm::any_of(size_aliases, [&](const auto& pair) {
          return pair.first == alias && pair.second == container;
        });

        if (!exists) {
          size_aliases.emplace_back(alias, container);
        }
      }

      void recordMaxValue(const clang::ValueDecl* decl, std::uint64_t upper) {
        if (decl == nullptr) {
          return;
        }

        const auto found = max_value.find(decl);
        if (found == max_value.end() || upper < found->second) {
          max_value[decl] = upper;
        }
      }

      void recordMinValue(const clang::ValueDecl* decl, std::uint64_t lower) {
        if (decl == nullptr || lower == 0) {
          return;
        }

        auto& entry = min_value[decl];
        if (lower > entry) {
          entry = lower;
        }
      }

      void removeBoundsFor(const clang::ValueDecl* decl) {
        llvm::erase_if(bounded, [&](const auto& pair) {
          return pair.first == decl || pair.second == decl;
        });

        llvm::erase_if(plus_bounded, [&](const auto& entry) {
          return std::get<0>(entry) == decl || std::get<1>(entry) == decl;
        });

        llvm::erase_if(size_aliases, [&](const auto& pair) {
          return pair.first == decl || pair.second == decl;
        });

        min_size.erase(decl);
        max_value.erase(decl);
        min_value.erase(decl);
      }

      void recordMinSize(const clang::ValueDecl* container, std::uint64_t size) {
        if (container == nullptr || size == 0) {
          return;
        }

        auto& entry = min_size[container];
        if (size > entry) {
          entry = size;
        }
      }

      bool join(const access_state& incoming) {
        if (!incoming.initialized) {
          return false;
        }

        if (!initialized) {
          *this = incoming;
          return true;
        }

        bool changed = false;

        // Intersection for non_null.
        llvm::SmallVector<const clang::ValueDecl*, 8> drop_non_null;

        for (const auto* decl : non_null) {
          if (!incoming.non_null.contains(decl)) {
            drop_non_null.push_back(decl);
          }
        }

        for (const auto* decl : drop_non_null) {
          non_null.erase(decl);
          changed = true;
        }

        // Intersection for bounded: keep (index, container) if incoming either has the same bound
        // or proves index <= K < staticExtent(container).
        const auto old_bounds = bounded.size();

        llvm::erase_if(bounded, [&](const auto& pair) {
          if (incoming.hasBound(pair.first, pair.second)) {
            return false;
          }

          if (const auto found_max = incoming.max_value.find(pair.first); found_max != incoming.max_value.end()) {
            if (const auto extent = staticExtent(pair.second->getType()); extent && found_max->second < *extent) {
              return false;
            }
          }

          return true;
        });

        if (bounded.size() != old_bounds) {
          changed = true;
        }

        // Also pull incoming bounds that are satisfied by our max_value.
        for (const auto& pair : incoming.bounded) {
          if (!hasBound(pair.first, pair.second)) {
            if (const auto found_max = max_value.find(pair.first); found_max != max_value.end()) {
              if (const auto extent = staticExtent(pair.second->getType()); extent && found_max->second < *extent) {
                bounded.push_back(pair);
                changed = true;
              }
            }
          }
        }

        // Intersection for plus_bounded (keeping minimum offset across paths).
        const auto old_plus = plus_bounded.size();

        llvm::erase_if(plus_bounded, [&](auto& entry) {
          for (const auto& other : incoming.plus_bounded) {
            if (std::get<0>(other) == std::get<0>(entry) && std::get<1>(other) == std::get<1>(entry)) {
              if (std::get<2>(other) < std::get<2>(entry)) {
                std::get<2>(entry) = std::get<2>(other);
                changed = true;
              }

              return false;
            }
          }

          return true;
        });

        if (plus_bounded.size() != old_plus) {
          changed = true;
        }

        // Intersection for size_aliases.
        const auto old_aliases = size_aliases.size();

        llvm::erase_if(size_aliases, [&](const auto& pair) {
          return !llvm::any_of(incoming.size_aliases, [&](const auto& other) {
            return other.first == pair.first && other.second == pair.second;
          });
        });

        if (size_aliases.size() != old_aliases) {
          changed = true;
        }

        // Maximum of max_value across paths (only when known on both paths).
        llvm::SmallVector<const clang::ValueDecl*, 4> drop_max;

        for (auto& entry : max_value) {
          const auto found = incoming.max_value.find(entry.first);
          if (found == incoming.max_value.end()) {
            drop_max.push_back(entry.first);
          } else if (found->second > entry.second) {
            entry.second = found->second;
            changed = true;
          }
        }

        for (const auto* decl : drop_max) {
          max_value.erase(decl);
          changed = true;
        }

        // Minimum of min_value across paths.
        llvm::SmallVector<const clang::ValueDecl*, 4> drop_min_val;

        for (auto& entry : min_value) {
          const auto found = incoming.min_value.find(entry.first);
          if (found == incoming.min_value.end()) {
            drop_min_val.push_back(entry.first);
          } else if (found->second < entry.second) {
            entry.second = found->second;
            changed = true;
          }
        }

        for (const auto* decl : drop_min_val) {
          min_value.erase(decl);
          changed = true;
        }

        // Minimum of min_size across paths.
        llvm::SmallVector<const clang::ValueDecl*, 4> drop_min;

        for (auto& entry : min_size) {
          const auto found = incoming.min_size.find(entry.first);
          if (found == incoming.min_size.end()) {
            drop_min.push_back(entry.first);
          } else if (found->second < entry.second) {
            entry.second = found->second;
            changed = true;
          }
        }

        for (const auto* decl : drop_min) {
          min_size.erase(decl);
          changed = true;
        }

        // Union for uninitialized and nullable_vars.
        for (const auto* decl : incoming.uninitialized) {
          if (uninitialized.insert(decl).second) {
            changed = true;
          }
        }

        for (const auto* decl : incoming.nullable_vars) {
          if (nullable_vars.insert(decl).second) {
            changed = true;
          }
        }

        return changed;
      }
    };

    bool isKnownNullableCall(const clang::CallExpr* call) {
      if (call == nullptr) {
        return false;
      }

      const auto* callee = call->getDirectCallee();
      if (callee == nullptr || callee->getIdentifier() == nullptr) {
        return false;
      }

      const auto* pattern = callee->getTemplateInstantiationPattern();
      if (annotated(*callee, "tbc::raw") || (pattern != nullptr && annotated(*pattern, "tbc::raw"))) {
        return false;
      }

      if (standardFunction(callee, "get_if") || standardFunction(callee, "addressof")) {
        return standardFunction(callee, "get_if");
      }

      const auto name = callee->getName();

      return name == "find" || name == "findMut" || name == "tryFind" || name == "getIf" || name == "allocate" || name == "malloc" || name == "calloc" || name == "realloc";
    }

    bool inherentlyNonNull(const clang::Expr* expr, const access_state& state);

    // Whether dereferencing `pointer` requires a non-null guard that is currently missing.
    bool isUnprovenNullablePointer(const clang::Expr* pointer, const access_state& state) {
      pointer = stripExpr(pointer);
      if (pointer == nullptr || !pointer->getType()->isPointerType()) {
        return false;
      }

      // Smart pointer / optional / iterator overloaded operator-> is not a raw nullable pointer here.
      if (const auto* op_call = llvm::dyn_cast<clang::CXXOperatorCallExpr>(pointer); op_call != nullptr && op_call->getOperator() == clang::OO_Arrow) {
        return false;
      }

      if (inherentlyNonNull(pointer, state)) {
        return false;
      }

      if (isNullLiteral(pointer)) {
        return true;
      }

      if (const auto* call = llvm::dyn_cast<clang::CallExpr>(pointer)) {
        return isKnownNullableCall(call);
      }

      if (const auto* decl = baseDecl(pointer)) {
        if (state.non_null.contains(decl)) {
          return false;
        }

        if (state.nullable_vars.contains(decl)) {
          return true;
        }

        if (const auto* param = llvm::dyn_cast<clang::ParmVarDecl>(decl)) {
          // Raw pointer parameters labeled tbc::view<T*> (or plain T*) are nullable unless guarded,
          // except opaque incomplete C handles and pointers inside helper functions of non-null design.
          const auto pointee = param->getType()->getPointeeType();

          return !pointee->isIncompleteType() && !pointee->isFunctionType() && viewAnnotation(param->getType(), param->getASTContext()).present;
        }

        if (const auto* field = llvm::dyn_cast<clang::FieldDecl>(decl)) {
          const auto* member = llvm::dyn_cast<clang::MemberExpr>(pointer);
          const bool on_this = member != nullptr && llvm::isa<clang::CXXThisExpr>(stripExpr(member->getBase()));

          return on_this && field->hasInClassInitializer() && isNullLiteral(field->getInClassInitializer());
        }
      }

      return false;
    }

    // Whether an expression is inherently non-null regardless of branch guards.
    bool inherentlyNonNull(const clang::Expr* expr, const access_state& state) {
      expr = stripExpr(expr);
      if (expr == nullptr) {
        return false;
      }

      if (llvm::isa<clang::CXXThisExpr>(expr) || llvm::isa<clang::CXXNewExpr>(expr) || llvm::isa<clang::StringLiteral>(expr) || expr->getType()->isArrayType()) {
        return true;
      }

      if (const auto* unary = llvm::dyn_cast<clang::UnaryOperator>(expr); unary != nullptr && unary->getOpcode() == clang::UO_AddrOf) {
        return true;
      }

      if (const auto* call = llvm::dyn_cast<clang::CallExpr>(expr)) {
        const auto* callee = call->getDirectCallee();
        if (standardFunction(callee, "addressof")) {
          return true;
        }

        if (const auto* member_call = llvm::dyn_cast<clang::CXXMemberCallExpr>(call)) {
          const auto* method = member_call->getMethodDecl();
          if (method != nullptr && method->getIdentifier() != nullptr) {
            const auto name = method->getName();
            if (name == "data" || name == "dataMut" || name == "c_str") {
              const auto receiver_type = member_call->getImplicitObjectArgument()->getType().getNonReferenceType();
              if (const auto extent = staticExtent(receiver_type); extent && *extent > 0) {
                return true;
              }

              if (const auto* container = baseDecl(member_call->getImplicitObjectArgument()); container != nullptr && state.min_size.lookup(container) > 0) {
                return true;
              }
            } else if (name == "get") {
              if (const auto* owner = baseDecl(member_call->getImplicitObjectArgument()); owner != nullptr && state.non_null.contains(owner)) {
                return true;
              }
            }
          }
        } else if (standardFunction(callee, "make_unique") || standardFunction(callee, "make_shared") || (callee != nullptr && callee->getIdentifier() != nullptr && (callee->getName() == "makeBox" || callee->getName() == "makeOwned"))) {
          return true;
        }
      }

      if (const auto* decl = baseDecl(expr)) {
        return state.non_null.contains(decl);
      }

      return false;
    }

    // Refines state along a conditional branch edge (taken = true/false).
    void refineCondition(const clang::Expr* condition, bool taken, access_state& state, const clang::ASTContext& context) {
      condition = stripExpr(condition);
      if (condition == nullptr) {
        return;
      }

      if (const auto* unary = llvm::dyn_cast<clang::UnaryOperator>(condition); unary != nullptr && unary->getOpcode() == clang::UO_LNot) {
        refineCondition(unary->getSubExpr(), !taken, state, context);
        return;
      }

      if (const auto* binary = llvm::dyn_cast<clang::BinaryOperator>(condition)) {
        const auto opcode = binary->getOpcode();
        if (opcode == clang::BO_LAnd && taken) {
          refineCondition(binary->getLHS(), true, state, context);
          refineCondition(binary->getRHS(), true, state, context);
          return;
        }

        if (opcode == clang::BO_LOr && !taken) {
          refineCondition(binary->getLHS(), false, state, context);
          refineCondition(binary->getRHS(), false, state, context);
          return;
        }

        const auto* lhs = stripExpr(binary->getLHS());
        const auto* rhs = stripExpr(binary->getRHS());

        // Collects all containers whose size is upper-bounded by `expr` (either `c.size()` directly
        // or a variable recorded in `state.size_aliases`).
        auto containersBoundedBy = [&](const clang::Expr* expr) {
          llvm::SmallVector<const clang::ValueDecl*, 2> containers;

          if (const auto* direct = sizeCallContainer(expr)) {
            containers.push_back(direct);
          } else if (const auto* alias = baseDecl(expr)) {
            for (const auto& pair : state.size_aliases) {
              if (pair.first == alias) {
                containers.push_back(pair.second);
              }
            }
          }

          return containers;
        };

        // Extracts `(index_decl, offset)` from `index` (offset 0) or `index + K` / `K + index`.
        auto indexPlusOffset = [&](const clang::Expr* expr) -> std::pair<const clang::ValueDecl*, std::uint64_t> {
          if (const auto* decl = baseDecl(expr)) {
            return {decl, 0};
          }

          if (const auto* add = llvm::dyn_cast_or_null<clang::BinaryOperator>(expr); add != nullptr && add->getOpcode() == clang::BO_Add) {
            if (const auto* decl = baseDecl(add->getLHS())) {
              if (const auto offset = constantUnsigned(add->getRHS(), context)) {
                return {decl, *offset};
              }
            } else if (const auto* rhs_decl = baseDecl(add->getRHS())) {
              if (const auto offset = constantUnsigned(add->getLHS(), context)) {
                return {rhs_decl, *offset};
              }
            }
          }

          return {nullptr, 0};
        };

        // Pointer nullness and equality/inequality comparisons: p != nullptr, i != 0, c.size() == N, i + 1 != c.size().
        if (opcode == clang::BO_NE || opcode == clang::BO_EQ) {
          const bool means_non_equal = (opcode == clang::BO_NE) == taken;
          if (means_non_equal) {
            if (isNullLiteral(rhs)) {
              if (const auto* decl = baseDecl(lhs)) {
                state.non_null.insert(decl);
                state.recordMinValue(decl, 1);
              }
            } else if (isNullLiteral(lhs)) {
              if (const auto* decl = baseDecl(rhs)) {
                state.non_null.insert(decl);
                state.recordMinValue(decl, 1);
              }
            }

            // container.size() != 0 / !container.empty().
            if (isZeroLiteral(rhs)) {
              for (const auto* container : containersBoundedBy(lhs)) {
                state.recordMinSize(container, 1);
              }
            } else if (isZeroLiteral(lhs)) {
              for (const auto* container : containersBoundedBy(rhs)) {
                state.recordMinSize(container, 1);
              }
            }

            // `index + 1 != c.size()` when `index < c.size()` proves `index + 1 < c.size()`.
            const auto [lhs_idx, lhs_off] = indexPlusOffset(lhs);
            if (lhs_idx != nullptr && lhs_off == 1) {
              for (const auto* container : containersBoundedBy(rhs)) {
                if (state.hasBound(lhs_idx, container)) {
                  state.addPlusBound(lhs_idx, container, 1);
                }
              }
            }

            const auto [rhs_idx, rhs_off] = indexPlusOffset(rhs);
            if (rhs_idx != nullptr && rhs_off == 1) {
              for (const auto* container : containersBoundedBy(lhs)) {
                if (state.hasBound(rhs_idx, container)) {
                  state.addPlusBound(rhs_idx, container, 1);
                }
              }
            }
          } else {
            // Equality branch: `c.size() == K` proves min_size >= K; `i == K` proves min/max K.
            if (const auto constant = constantUnsigned(rhs, context)) {
              for (const auto* container : containersBoundedBy(lhs)) {
                state.recordMinSize(container, *constant);
              }

              if (const auto* decl = baseDecl(lhs)) {
                state.recordMaxValue(decl, *constant);
                state.recordMinValue(decl, *constant);
              }
            } else if (const auto lhs_constant = constantUnsigned(lhs, context)) {
              for (const auto* container : containersBoundedBy(rhs)) {
                state.recordMinSize(container, *lhs_constant);
              }

              if (const auto* decl = baseDecl(rhs)) {
                state.recordMaxValue(decl, *lhs_constant);
                state.recordMinValue(decl, *lhs_constant);
              }
            }
          }

          return;
        }

        // Index bounds comparisons: index < c.size(), index + K < c.size(), index < CONST, etc.
        auto effective = opcode;

        if (!taken) {
          switch (opcode) {
          case clang::BO_LT:
            effective = clang::BO_GE;
            break;
          case clang::BO_LE:
            effective = clang::BO_GT;
            break;
          case clang::BO_GT:
            effective = clang::BO_LE;
            break;
          case clang::BO_GE:
            effective = clang::BO_LT;
            break;
          default:
            return;
          }
        }

        const auto left_containers = containersBoundedBy(lhs);
        const auto right_containers = containersBoundedBy(rhs);
        const auto [lhs_idx, lhs_off] = indexPlusOffset(lhs);
        const auto [rhs_idx, rhs_off] = indexPlusOffset(rhs);

        if (effective == clang::BO_LT) {
          for (const auto* container : right_containers) {
            if (lhs_idx != nullptr) {
              state.addPlusBound(lhs_idx, container, lhs_off);
            } else if (const auto constant = constantUnsigned(lhs, context)) {
              state.recordMinSize(container, *constant + 1);
            }
          }

          if (const auto constant = constantUnsigned(rhs, context); constant && *constant > 0 && lhs_idx != nullptr && *constant > lhs_off) {
            state.recordMaxValue(lhs_idx, *constant - 1 - lhs_off);
          }
        } else if (effective == clang::BO_GT) {
          for (const auto* container : left_containers) {
            if (rhs_idx != nullptr) {
              state.addPlusBound(rhs_idx, container, rhs_off);
            } else if (const auto constant = constantUnsigned(rhs, context)) {
              state.recordMinSize(container, *constant + 1);
            }
          }

          if (const auto constant = constantUnsigned(lhs, context); constant && *constant > 0 && rhs_idx != nullptr && *constant > rhs_off) {
            state.recordMaxValue(rhs_idx, *constant - 1 - rhs_off);
          }

          if (const auto constant = constantUnsigned(rhs, context); constant && lhs_idx != nullptr && lhs_off == 0) {
            state.recordMinValue(lhs_idx, *constant + 1);
          }
        } else if (effective == clang::BO_GE) {
          for (const auto* container : left_containers) {
            if (const auto constant = constantUnsigned(rhs, context)) {
              state.recordMinSize(container, *constant);
            } else if (rhs_idx != nullptr && rhs_off >= 1) {
              state.addPlusBound(rhs_idx, container, rhs_off - 1);
            }
          }

          if (const auto constant = constantUnsigned(lhs, context); constant && rhs_idx != nullptr && *constant >= rhs_off) {
            state.recordMaxValue(rhs_idx, *constant - rhs_off);
          }

          if (const auto constant = constantUnsigned(rhs, context); constant && lhs_idx != nullptr && lhs_off == 0) {
            state.recordMinValue(lhs_idx, *constant);
          }
        } else if (effective == clang::BO_LE) {
          for (const auto* container : right_containers) {
            if (const auto constant = constantUnsigned(lhs, context)) {
              state.recordMinSize(container, *constant);
            } else if (lhs_idx != nullptr && lhs_off >= 1) {
              state.addPlusBound(lhs_idx, container, lhs_off - 1);
            }
          }

          if (const auto constant = constantUnsigned(rhs, context); constant && lhs_idx != nullptr && *constant >= lhs_off) {
            state.recordMaxValue(lhs_idx, *constant - lhs_off);
          }
        }

        return;
      }

      // `if (ptr)` proves ptr non-null on true branch.
      if (taken && condition->getType()->isPointerType()) {
        if (const auto* decl = baseDecl(condition)) {
          state.non_null.insert(decl);
        }
      }

      // `if (!container.empty())` proves container.size() >= 1 on false branch of empty().
      if (!taken) {
        if (const auto* container = emptyCallContainer(condition)) {
          state.recordMinSize(container, 1);
        }
      }
    }

    // Whether an index expression is proven strictly less than container's length.
    bool indexProvenInBounds(const clang::Expr* container_expr, const clang::Expr* index_expr, const access_state& state, const clang::ASTContext& context) {
      index_expr = stripExpr(index_expr);
      if (index_expr == nullptr) {
        return true;
      }

      const auto extent = exprStaticExtent(container_expr);
      const auto* container = baseDecl(container_expr);
      const auto known_limit = [&](std::uint64_t value) {
        return (extent && value < *extent) || (container != nullptr && value < state.min_size.lookup(container));
      };

      if (const auto constant = constantUnsigned(index_expr, context)) {
        if (known_limit(*constant)) {
          return true;
        }
      }

      if (const auto* index = baseDecl(index_expr); index != nullptr) {
        if (container != nullptr && state.hasBound(index, container)) {
          return true;
        }

        if (const auto found_max = state.max_value.find(index); found_max != state.max_value.end() && known_limit(found_max->second)) {
          return true;
        }
      }

      // Narrow unsigned integer width upper bound (e.g. `uint8_t byte` or `static_cast<size_t>(byte)` <= 255).
      auto unsignedWidthMax = [&](const clang::Expr* expr) -> std::optional<std::uint64_t> {
        const auto* inner = stripExpr(expr);

        while (const auto* cast = llvm::dyn_cast_or_null<clang::ExplicitCastExpr>(inner)) {
          inner = stripExpr(cast->getSubExpr());
        }

        if (inner == nullptr) {
          return std::nullopt;
        }

        const auto type = inner->getType().getNonReferenceType().getCanonicalType();
        if (type->isUnsignedIntegerType()) {
          const auto bits = context.getTypeSize(type);
          if (bits == 8) {
            return 255U;
          }

          if (bits == 16) {
            return 65535U;
          }
        }

        return std::nullopt;
      };

      if (const auto width_max = unsignedWidthMax(index_expr); width_max && known_limit(*width_max)) {
        return true;
      }

      // Pre-increment `arr[++i]` is in bounds when `i + 1 < container.size()`.
      if (const auto* pre = llvm::dyn_cast<clang::UnaryOperator>(index_expr); pre != nullptr && pre->getOpcode() == clang::UO_PreInc) {
        if (const auto* decl = baseDecl(pre->getSubExpr())) {
          if (container != nullptr && state.hasPlusBound(decl, container, 1)) {
            return true;
          }

          if (const auto found_max = state.max_value.find(decl); found_max != state.max_value.end() && known_limit(found_max->second + 1)) {
            return true;
          }
        }
      }

      // Post-increment/decrement `arr[i++]` evaluates to the pre-mutation value of `i`.
      if (const auto* post = llvm::dyn_cast<clang::UnaryOperator>(index_expr);
          post != nullptr && (post->getOpcode() == clang::UO_PostInc || post->getOpcode() == clang::UO_PostDec)) {
        if (indexProvenInBounds(container_expr, post->getSubExpr(), state, context)) {
          return true;
        }
      }

      // Post-increment `arr[i++]` whose pre-increment value of `i` was proven in bounds in an earlier CFGStmt.
      if (container != nullptr && llvm::any_of(state.bounded_exprs, [&](const auto& pair) {
            return pair.first == index_expr && pair.second == container;
          })) {
        return true;
      }

      // Arithmetic index expressions: `i + K`, `i - K`, `i % c.size()`, `i % N`, `i & (N - 1)`, `i / N`.
      if (const auto* binary = llvm::dyn_cast<clang::BinaryOperator>(index_expr)) {
        const auto opcode = binary->getOpcode();
        if (opcode == clang::BO_Add) {
          const auto* lhs_decl = baseDecl(binary->getLHS());
          const auto rhs_const = constantUnsigned(binary->getRHS(), context);
          if (lhs_decl != nullptr && rhs_const) {
            if (container != nullptr && state.hasPlusBound(lhs_decl, container, *rhs_const)) {
              return true;
            }

            if (const auto found_max = state.max_value.find(lhs_decl); found_max != state.max_value.end() && known_limit(found_max->second + *rhs_const)) {
              return true;
            }
          }
        } else if (opcode == clang::BO_Rem) {
          if (container != nullptr && sizeCallContainer(binary->getRHS()) == container) {
            return true;
          }

          if (const auto* rhs_decl = baseDecl(binary->getRHS()); rhs_decl != nullptr && container != nullptr) {
            if (llvm::any_of(state.size_aliases, [&](const auto& pair) {
                  return pair.first == rhs_decl && pair.second == container;
                })) {
              return true;
            }
          }

          if (const auto modulus = constantUnsigned(binary->getRHS(), context); modulus && *modulus > 0) {
            if ((extent && *modulus <= *extent) || (container != nullptr && *modulus <= state.min_size.lookup(container))) {
              return true;
            }
          }
        } else if (opcode == clang::BO_And) {
          if (const auto mask = constantUnsigned(binary->getRHS(), context); mask && known_limit(*mask)) {
            return true;
          }
        } else if (opcode == clang::BO_Div) {
          if (const auto divisor = constantUnsigned(binary->getRHS(), context); divisor && *divisor > 0) {
            if (const auto* lhs_decl = baseDecl(binary->getLHS())) {
              if (const auto found_max = state.max_value.find(lhs_decl); found_max != state.max_value.end() && known_limit(found_max->second / *divisor)) {
                return true;
              }
            }
          }
        } else if (opcode == clang::BO_Sub) {
          // `c.size() - K` when `c.size() >= K >= 1`.
          if (container != nullptr && sizeCallContainer(binary->getLHS()) == container) {
            if (const auto offset = constantUnsigned(binary->getRHS(), context); offset && *offset >= 1 && state.min_size.lookup(container) >= *offset) {
              return true;
            }
          }

          // `index - K` when `index < container.size()` and `index >= K` (no unsigned underflow).
          if (const auto* lhs_decl = baseDecl(binary->getLHS())) {
            if (const auto offset = constantUnsigned(binary->getRHS(), context); offset && state.min_value.lookup(lhs_decl) >= *offset) {
              if (indexProvenInBounds(container_expr, binary->getLHS(), state, context)) {
                return true;
              }
            }
          }
        }
      }

      return false;
    }

    enum class access_issue : std::uint8_t {
      unproven_bounds = 200,
      nullable_deref = 201,
      uninitialized_read = 202,
    };

    void reportAccess(
        access_issue kind,
        clang::SourceLocation location,
        clang::ASTContext& context,
        bool errors,
        llvm::DenseSet<std::uint64_t>& reported
    ) {
      if (location.isInvalid()) {
        return;
      }

      location = context.getSourceManager().getExpansionLoc(location);
      if (context.getSourceManager().isInSystemHeader(location)) {
        return;
      }

      const auto key = (static_cast<std::uint64_t>(location.getRawEncoding()) << 8U) | static_cast<std::uint8_t>(kind);
      if (!reported.insert(key).second) {
        return;
      }

      auto& diagnostics = context.getDiagnostics();
      const auto severity = errors ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning;
      unsigned id = 0;

      switch (kind) {
      case access_issue::unproven_bounds:
        id = diagnostics.getCustomDiagID(severity, "indexed access has no proven upper bound; check against size() or use a checked accessor [tbc-unproven-bounds]");
        break;
      case access_issue::nullable_deref:
        id = diagnostics.getCustomDiagID(severity, "dereferences a pointer not proven non-null; guard against nullptr first [tbc-nullable-dereference]");
        break;
      case access_issue::uninitialized_read:
        id = diagnostics.getCustomDiagID(severity, "reads storage that may not be initialized [tbc-uninitialized-read]");
        break;
      }

      diagnostics.Report(location, id);
    }
  }

  void checkAccessValidity(
      const clang::FunctionDecl& definition,
      const clang::CFG& graph,
      clang::ASTContext& context,
      access_options options,
      llvm::DenseSet<std::uint64_t>& reported
  ) {
    const bool errors = options.errors;
    const bool check_bounds = options.check_bounds;

    if (definition.isImplicit() || definition.isDependentContext()) {
      return;
    }

    if (const auto* method = llvm::dyn_cast<clang::CXXMethodDecl>(&definition)) {
      if (sharedRecord(*method->getParent()) || ownerRecord(*method->getParent()) || inTelarDsNamespace(*method->getParent())) {
        return;
      }
    }

    // Fast-path pre-scan: skip functions that perform no dereference, indexed access, or
    // uninitialized local/buffer operation without allocating dataflow states or running worklists.
    bool needs_check = false;

    for (const auto* block : graph) {
      for (const auto& element : *block) {
        const auto stmt_element = element.getAs<clang::CFGStmt>();
        if (!stmt_element) {
          continue;
        }

        const auto* node = stmt_element->getStmt();
        if (const auto* decl_stmt = llvm::dyn_cast<clang::DeclStmt>(node)) {
          for (const auto* decl : decl_stmt->decls()) {
            const auto* var = llvm::dyn_cast<clang::VarDecl>(decl);
            if (var == nullptr) {
              continue;
            }

            if (!var->hasInit() && var->getType()->isScalarType() && !var->hasGlobalStorage()) {
              needs_check = true;
              break;
            }

            if (var->hasInit()) {
              if (const auto* call = llvm::dyn_cast_or_null<clang::CallExpr>(stripExpr(var->getInit()))) {
                if (isUninitializedProducer(call->getDirectCallee())) {
                  needs_check = true;
                  break;
                }
              }
            }
          }
        } else {
          llvm::SmallVector<const clang::Stmt*, 16> scan{node};

          while (!scan.empty() && !needs_check) {
            const auto* sub = scan.pop_back_val();
            if (sub == nullptr || llvm::isa<clang::LambdaExpr>(sub)) {
              continue;
            }

            if (const auto* unary = llvm::dyn_cast<clang::UnaryOperator>(sub); unary != nullptr && unary->getOpcode() == clang::UO_Deref) {
              needs_check = true;
              break;
            }

            if (const auto* member = llvm::dyn_cast<clang::MemberExpr>(sub); member != nullptr && member->isArrow()) {
              needs_check = true;
              break;
            }

            if (check_bounds && llvm::isa<clang::ArraySubscriptExpr>(sub)) {
              needs_check = true;
              break;
            }

            if (const auto* array_sub = llvm::dyn_cast<clang::ArraySubscriptExpr>(sub); array_sub != nullptr && array_sub->getBase() != nullptr && array_sub->getBase()->getType()->isPointerType()) {
              needs_check = true;
              break;
            }

            if (check_bounds) {
              if (const auto* op_call = llvm::dyn_cast<clang::CXXOperatorCallExpr>(sub); op_call != nullptr && op_call->getOperator() == clang::OO_Subscript) {
                needs_check = true;
                break;
              }

              if (const auto* member_call = llvm::dyn_cast<clang::CXXMemberCallExpr>(sub)) {
                const auto* method = member_call->getMethodDecl();
                if (method != nullptr && method->getIdentifier() != nullptr && method->getName() == "atMut") {
                  needs_check = true;
                  break;
                }
              }
            }

            for (const auto* child : sub->children()) {
              if (!llvm::isa_and_nonnull<clang::CallExpr>(child) && !llvm::isa_and_nonnull<clang::BinaryOperator>(child)) {
                scan.push_back(child);
              }
            }
          }
        }

        if (needs_check) {
          break;
        }
      }

      if (needs_check) {
        break;
      }
    }

    if (!needs_check) {
      return;
    }

    const auto block_count = graph.getNumBlockIDs();
    llvm::SmallVector<access_state, 16> entry_states(block_count);
    llvm::SmallVector<const clang::CFGBlock*, 16> worklist;
    llvm::SmallVector<bool, 16> queued(block_count, false);

    auto& start = entry_states[graph.getEntry().getBlockID()];

    start.initialized = true;
    worklist.push_back(&graph.getEntry());
    queued[graph.getEntry().getBlockID()] = true;

    const auto transferBlock = [&](const clang::CFGBlock& block, access_state& current, bool emit) {
      for (const auto& element : block) {
        const auto stmt_element = element.getAs<clang::CFGStmt>();
        if (!stmt_element) {
          continue;
        }

        const auto* node = stmt_element->getStmt();

        // Declarations: track non-nullness and uninitialized locals/buffers.
        if (const auto* decl_stmt = llvm::dyn_cast<clang::DeclStmt>(node)) {
          for (const auto* decl : decl_stmt->decls()) {
            const auto* var = llvm::dyn_cast<clang::VarDecl>(decl);
            if (var == nullptr) {
              continue;
            }

            if (!var->hasInit()) {
              if (var->getType()->isScalarType() && !var->hasGlobalStorage()) {
                current.uninitialized.insert(var);
              }

              continue;
            }

            const auto* init = stripExpr(var->getInit());

            if (var->getType()->isPointerType() || smartPointer(var->getType())) {
              if (inherentlyNonNull(init, current)) {
                current.non_null.insert(var);
                current.nullable_vars.erase(var);
              } else {
                current.non_null.erase(var);
                if (isNullLiteral(init) || isKnownNullableCall(llvm::dyn_cast_or_null<clang::CallExpr>(init))) {
                  current.nullable_vars.insert(var);
                }
              }
            }

            // Track container minimum size from initializer lists (e.g. std::vector<int>{1, 2}).
            if (isIndexedContainerType(var->getType())) {
              if (const auto* ctor = llvm::dyn_cast_or_null<clang::CXXConstructExpr>(init); ctor != nullptr && ctor->getNumArgs() >= 1) {
                if (const auto* init_list = llvm::dyn_cast_or_null<clang::CXXStdInitializerListExpr>(stripExpr(ctor->getArg(0)))) {
                  if (const auto* sub = llvm::dyn_cast_or_null<clang::InitListExpr>(stripExpr(init_list->getSubExpr()))) {
                    current.recordMinSize(var, sub->getNumInits());
                  }
                } else if (const auto count = constantUnsigned(ctor->getArg(0), context); count && *count > 0) {
                  current.recordMinSize(var, *count);
                }
              }
            }

            if (const auto* call = llvm::dyn_cast_or_null<clang::CallExpr>(init)) {
              if (isUninitializedProducer(call->getDirectCallee())) {
                current.uninitialized.insert(var);
              }
            }

            // Track size aliases: `const auto n = c.size();` or `const auto n = std::min(a.size(), b.size());`.
            if (const auto* size_container = sizeCallContainer(init)) {
              current.addSizeAlias(var, size_container);
            } else if (const auto* call = llvm::dyn_cast_or_null<clang::CallExpr>(init); call != nullptr && standardFunction(call->getDirectCallee(), "min") && call->getNumArgs() == 2) {
              if (const auto* left_c = sizeCallContainer(call->getArg(0))) {
                current.addSizeAlias(var, left_c);
              }

              if (const auto* right_c = sizeCallContainer(call->getArg(1))) {
                current.addSizeAlias(var, right_c);
              }
            } else if (const auto constant = constantUnsigned(init, context)) {
              current.max_value[var] = *constant;
              current.recordMinValue(var, *constant);
            }
          }

          continue;
        }

        // Check dereferences and subscripts within the statement (Clang's CFG omits nested builtin
        // unary `*`, `->`, and `[]` subexpressions as separate CFGStmt elements).
        // Skip short-circuiting logical / ternary roots whose branches are already evaluated in
        // separate CFG blocks with refined nullability and bounds state.
        llvm::SmallVector<const clang::Stmt*, 16> sub_stack;
        llvm::SmallVector<const clang::UnaryOperator*, 4> nested_inc_dec;

        const bool is_short_circuit_root = llvm::isa<clang::ConditionalOperator>(node) || (llvm::isa<clang::BinaryOperator>(node) && llvm::cast<clang::BinaryOperator>(node)->isLogicalOp());
        if (!is_short_circuit_root) {
          sub_stack.push_back(node);
        }

        while (!sub_stack.empty()) {
          const auto* sub = sub_stack.pop_back_val();
          if (sub == nullptr || llvm::isa<clang::LambdaExpr>(sub) || llvm::isa<clang::ConditionalOperator>(sub)) {
            continue;
          }

          if (const auto* bin = llvm::dyn_cast<clang::BinaryOperator>(sub); bin != nullptr && bin->isLogicalOp()) {
            continue;
          }

          if (const auto* unary = llvm::dyn_cast<clang::UnaryOperator>(sub); unary != nullptr && unary->isIncrementDecrementOp()) {
            nested_inc_dec.push_back(unary);
          }

          if (const auto* unary = llvm::dyn_cast<clang::UnaryOperator>(sub); unary != nullptr && unary->getOpcode() == clang::UO_Deref) {
            const auto* pointer = stripExpr(unary->getSubExpr());
            if (isUnprovenNullablePointer(pointer, current)) {
              if (emit) {
                reportAccess(access_issue::nullable_deref, unary->getOperatorLoc(), context, errors, reported);
              }
            }
          } else if (const auto* member = llvm::dyn_cast<clang::MemberExpr>(sub); member != nullptr && member->isArrow()) {
            const auto* pointer = stripExpr(member->getBase());
            if (isUnprovenNullablePointer(pointer, current)) {
              if (emit) {
                reportAccess(access_issue::nullable_deref, member->getOperatorLoc(), context, errors, reported);
              }
            }
          } else if (const auto* subscript = llvm::dyn_cast<clang::ArraySubscriptExpr>(sub)) {
            const auto* base = stripExpr(subscript->getBase());
            if (base != nullptr && base->getType()->isPointerType()) {
              if (isUnprovenNullablePointer(base, current) && emit) {
                reportAccess(access_issue::nullable_deref, subscript->getBeginLoc(), context, errors, reported);
              }
            } else if (check_bounds && base != nullptr && base->getType()->isArrayType()) {
              if (!indexProvenInBounds(base, subscript->getIdx(), current, context) && emit) {
                reportAccess(access_issue::unproven_bounds, subscript->getBeginLoc(), context, errors, reported);
              }
            }
          } else if (check_bounds) {
            if (const auto* op_call = llvm::dyn_cast<clang::CXXOperatorCallExpr>(sub)) {
              if (op_call->getOperator() == clang::OO_Subscript && op_call->getNumArgs() == 2 && isIndexedContainerType(op_call->getArg(0)->getType())) {
                if (!indexProvenInBounds(op_call->getArg(0), op_call->getArg(1), current, context) && emit) {
                  reportAccess(access_issue::unproven_bounds, op_call->getBeginLoc(), context, errors, reported);
                }
              }
            }
          }

          for (const auto* child : sub->children()) {
            // Do not descend into sub-calls, binary ops, or ternaries that appear as their own CFGStmt with refined state.
            if (!llvm::isa_and_nonnull<clang::CallExpr>(child) && !llvm::isa_and_nonnull<clang::BinaryOperator>(child) && !llvm::isa_and_nonnull<clang::ConditionalOperator>(child)) {
              sub_stack.push_back(child);
            }
          }
        }

        for (const auto* unary : nested_inc_dec) {
          if (unary == node) {
            continue;
          }

          if (const auto* decl = baseDecl(unary->getSubExpr())) {
            current.removeBoundsFor(decl);
          }
        }

        // Check calls: buffer initializers clear uninitialized; other calls reading uninitialized buffers report.
        if (const auto* call = llvm::dyn_cast<clang::CallExpr>(node)) {
          const auto* callee = call->getDirectCallee();
          if (isBufferInitializer(callee)) {
            for (const auto* arg : call->arguments()) {
              if (const auto* decl = baseDecl(arg)) {
                current.uninitialized.erase(decl);
              }
            }
          } else if (callee != nullptr) {
            if (const auto* member_call = llvm::dyn_cast<clang::CXXMemberCallExpr>(call)) {
              const auto* method = member_call->getMethodDecl();
              const auto* container = baseDecl(member_call->getImplicitObjectArgument());

              if (method != nullptr && method->getIdentifier() != nullptr) {
                const auto name = method->getName();
                if (check_bounds && name == "atMut" && member_call->getNumArgs() == 1 && isIndexedContainerType(member_call->getImplicitObjectArgument()->getType())) {
                  if (!indexProvenInBounds(member_call->getImplicitObjectArgument(), member_call->getArg(0), current, context) && emit) {
                    reportAccess(access_issue::unproven_bounds, member_call->getBeginLoc(), context, errors, reported);
                  }
                } else if (name == "push_back" || name == "emplace_back" || name == "push" || name == "emplace") {
                  if (container != nullptr) {
                    current.recordMinSize(container, current.min_size.lookup(container) + 1);
                  }
                } else if (!method->isConst()) {
                  if (container != nullptr) {
                    current.removeBoundsFor(container);
                  }
                }
              }
            }

            for (unsigned index = 0; index < call->getNumArgs(); ++index) {
              const auto* arg = call->getArg(index);
              // Taking the address of a pointer (`&out_ptr`) passed as a `T**` out-parameter
              // initializes the pointer (e.g. `FT_Get_MM_Var`, `pcap_next_ex`).
              if (const auto* addr = llvm::dyn_cast_or_null<clang::UnaryOperator>(stripExpr(arg)); addr != nullptr && addr->getOpcode() == clang::UO_AddrOf) {
                if (const auto* out_decl = baseDecl(addr->getSubExpr()); out_decl != nullptr && out_decl->getType()->isPointerType()) {
                  current.nullable_vars.erase(out_decl);
                  current.uninitialized.erase(out_decl);
                }

                continue;
              }

              if (const auto* decl = baseDecl(arg); decl != nullptr && current.uninitialized.contains(decl)) {
                if (emit) {
                  reportAccess(access_issue::uninitialized_read, call->getBeginLoc(), context, errors, reported);
                }
              }
            }
          }
        }

        // Assignments update nullness, initialization, and invalidate stale bounds.
        if (const auto* binary = llvm::dyn_cast<clang::BinaryOperator>(node); binary != nullptr && binary->isAssignmentOp()) {
          const auto* lhs = stripExpr(binary->getLHS());
          if (const auto* decl = baseDecl(lhs)) {
            current.uninitialized.erase(decl);
            current.removeBoundsFor(decl);
            if (const auto constant = constantUnsigned(binary->getRHS(), context)) {
              current.max_value[decl] = *constant;
            }

            if (decl->getType()->isPointerType()) {
              if (inherentlyNonNull(binary->getRHS(), current)) {
                current.non_null.insert(decl);
                current.nullable_vars.erase(decl);
              } else {
                current.non_null.erase(decl);
                if (isNullLiteral(binary->getRHS()) || isKnownNullableCall(llvm::dyn_cast_or_null<clang::CallExpr>(stripExpr(binary->getRHS())))) {
                  current.nullable_vars.insert(decl);
                }
              }
            }
          } else if (const auto* sub = llvm::dyn_cast_or_null<clang::ArraySubscriptExpr>(lhs)) {
            if (const auto* target = baseDecl(sub->getBase())) {
              current.uninitialized.erase(target);
            }
          } else if (const auto* op_sub = llvm::dyn_cast_or_null<clang::CXXOperatorCallExpr>(lhs); op_sub != nullptr && op_sub->getOperator() == clang::OO_Subscript && op_sub->getNumArgs() == 2) {
            if (const auto* target = baseDecl(op_sub->getArg(0))) {
              current.uninitialized.erase(target);
            }
          }
        } else if (const auto* unary = llvm::dyn_cast<clang::UnaryOperator>(node); unary != nullptr && unary->isIncrementDecrementOp()) {
          if (const auto* decl = baseDecl(unary->getSubExpr())) {
            if (unary->getOpcode() == clang::UO_PostInc) {
              for (const auto& pair : current.bounded) {
                if (pair.first == decl) {
                  current.bounded_exprs.emplace_back(unary, pair.second);
                }
              }
            }

            current.removeBoundsFor(decl);
          }
        } else if (const auto* read = llvm::dyn_cast<clang::ImplicitCastExpr>(node); read != nullptr && read->getCastKind() == clang::CK_LValueToRValue) {
          if (const auto* decl = baseDecl(read->getSubExpr()); decl != nullptr && current.uninitialized.contains(decl)) {
            if (emit) {
              reportAccess(access_issue::uninitialized_read, read->getBeginLoc(), context, errors, reported);
            }
          }
        }
      }
    };

    // Fixed-point propagation over CFG.
    while (!worklist.empty()) {
      const auto* block = worklist.pop_back_val();

      queued[block->getBlockID()] = false;

      access_state out = entry_states[block->getBlockID()];

      transferBlock(*block, out, false);

      const auto* terminator = block->getTerminatorStmt();
      const auto* condition = [&]() -> const clang::Expr* {
        if (const auto* branch = llvm::dyn_cast_or_null<clang::IfStmt>(terminator)) {
          return branch->getCond();
        }

        if (const auto* loop = llvm::dyn_cast_or_null<clang::ForStmt>(terminator)) {
          return loop->getCond();
        }

        if (const auto* loop = llvm::dyn_cast_or_null<clang::WhileStmt>(terminator)) {
          return loop->getCond();
        }

        if (const auto* ternary = llvm::dyn_cast_or_null<clang::ConditionalOperator>(terminator)) {
          return ternary->getCond();
        }

        if (const auto* binary = llvm::dyn_cast_or_null<clang::BinaryOperator>(terminator); binary != nullptr && binary->isLogicalOp()) {
          return binary->getLHS();
        }

        return nullptr;
      }();

      unsigned succ_index = 0;

      for (const auto& successor : block->succs()) {
        const auto* next = successor.getReachableBlock();
        if (next != nullptr) {
          access_state branch = out;

          if (condition != nullptr && block->succ_size() == 2) {
            refineCondition(condition, succ_index == 0, branch, context);
          }

          if (entry_states[next->getBlockID()].join(branch) && !queued[next->getBlockID()]) {
            queued[next->getBlockID()] = true;
            worklist.push_back(next);
          }
        }

        ++succ_index;
      }
    }

    // Final diagnostic pass.
    for (const auto* block : graph) {
      if (!entry_states[block->getBlockID()].initialized) {
        continue;
      }

      access_state current = entry_states[block->getBlockID()];

      transferBlock(*block, current, true);
    }
  }
}
