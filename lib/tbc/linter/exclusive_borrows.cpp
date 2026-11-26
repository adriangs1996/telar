#include "exclusive_borrows.hpp"

#include "view_type.hpp"

#include <clang/AST/Expr.h>
#include <clang/AST/ExprCXX.h>
#include <clang/AST/RecursiveASTVisitor.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/BitVector.h>
#include <llvm/ADT/DenseMap.h>
#include <llvm/ADT/SmallPtrSet.h>
#include <llvm/ADT/SmallVector.h>

#include <algorithm>
#include <cstdint>
#include <optional>
#include <utility>

namespace tbc_lint {
  namespace {
    const clang::Expr* stripBorrowExpr(const clang::Expr* expr) {
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

    // A syntactic place: a root variable and zero or more field projections.
    struct borrow_place {
      const clang::ValueDecl* root = nullptr;
      llvm::SmallVector<const clang::FieldDecl*, 3> fields;

      bool operator==(const borrow_place&) const = default;
    };

    // Whether two places overlap (same root, and one field path is a prefix of the other, or
    // either crosses a union where members share storage).
    bool placesOverlap(const borrow_place& left, const borrow_place& right) {
      if (left.root == nullptr || left.root != right.root) {
        return false;
      }

      const auto shared = std::min(left.fields.size(), right.fields.size());

      for (std::size_t index = 0; index < shared; ++index) {
        if (left.fields[index] == nullptr || right.fields[index] == nullptr) {
          return true;
        }

        if (left.fields[index] != right.fields[index]) {
          return false;
        }
      }

      return true;
    }

    bool isSharedOrSyncPlace(const borrow_place& place, const clang::ASTContext& context) {
      if (place.root == nullptr) {
        return true;
      }

      auto checkType = [&](clang::QualType type) {
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
      };

      if (checkType(place.root->getType())) {
        return true;
      }

      for (const auto* field : place.fields) {
        if (field != nullptr && checkType(field->getType())) {
          return true;
        }
      }

      return false;
    }

    // Extracts the root variable and field path of an lvalue expression.
    std::optional<borrow_place> extractPlace(const clang::Expr* expr) {
      expr = stripBorrowExpr(expr);
      if (expr == nullptr) {
        return std::nullopt;
      }

      if (const auto* unary = llvm::dyn_cast<clang::UnaryOperator>(expr); unary != nullptr && unary->getOpcode() == clang::UO_AddrOf) {
        return extractPlace(unary->getSubExpr());
      }

      if (const auto* ref = llvm::dyn_cast<clang::DeclRefExpr>(expr)) {
        if (const auto* var = llvm::dyn_cast<clang::VarDecl>(ref->getDecl())) {
          return borrow_place{.root = var, .fields = {}};
        }

        return std::nullopt;
      }

      if (const auto* member = llvm::dyn_cast<clang::MemberExpr>(expr)) {
        if (member->isArrow()) {
          return std::nullopt;
        }

        const auto* field = llvm::dyn_cast<clang::FieldDecl>(member->getMemberDecl());
        if (field == nullptr) {
          return std::nullopt;
        }

        if (llvm::isa<clang::CXXThisExpr>(stripBorrowExpr(member->getBase()))) {
          return borrow_place{.root = field, .fields = {}};
        }

        auto base = extractPlace(member->getBase());
        if (!base) {
          return std::nullopt;
        }

        if (base->fields.size() < 3) {
          base->fields.push_back(field->getParent()->isUnion() ? nullptr : field);
        }

        return base;
      }

      // Container/array subscript denotes a place inside the container (merged at the container root).
      if (const auto* subscript = llvm::dyn_cast<clang::ArraySubscriptExpr>(expr)) {
        return extractPlace(subscript->getBase());
      }

      if (const auto* call = llvm::dyn_cast<clang::CXXOperatorCallExpr>(expr); call != nullptr && call->getOperator() == clang::OO_Subscript && call->getNumArgs() == 2) {
        return extractPlace(call->getArg(0));
      }

      return std::nullopt;
    }

    // Whether a type is a non-Copy owning type whose values become invalid after std::move.
    bool isMoveTrackedType(clang::QualType type) {
      type = type.getNonReferenceType().getCanonicalType();
      if (type.isNull() || type->isScalarType() || type->isReferenceType() || type->isPointerType() || viewType(type) || iteratorRecord(type)) {
        return false;
      }

      const auto* record = recordOf(type);
      if (record == nullptr || record->getDefinition() == nullptr) {
        return false;
      }

      const auto* definition = record->getDefinition();
      if (definition->isTriviallyCopyable()) {
        return false;
      }

      // Standard and telar owning containers / smart pointers / non-trivially-destructible project types.
      return !definition->hasTrivialDestructor() || uniqueOwner(type) || transfersAllocation(type);
    }

    // Extracts the place moved from in `std::move(x)` or `std::move(x.field)`, unwrapping move constructors.
    std::optional<borrow_place> extractMovedPlace(const clang::Expr* expr) {
      expr = stripBorrowExpr(expr);
      if (const auto* temp = llvm::dyn_cast_or_null<clang::MaterializeTemporaryExpr>(expr)) {
        return extractMovedPlace(temp->getSubExpr());
      }

      if (const auto* ctor = llvm::dyn_cast_or_null<clang::CXXConstructExpr>(expr); ctor != nullptr && ctor->getNumArgs() == 1) {
        return extractMovedPlace(ctor->getArg(0));
      }

      if (const auto* call = llvm::dyn_cast_or_null<clang::CallExpr>(expr)) {
        const auto* callee = call->getDirectCallee();
        if (standardFunction(callee, "move") && call->getNumArgs() == 1) {
          const auto* arg = stripBorrowExpr(call->getArg(0));
          // Moving one element out of a container (`std::move(vec[i])`) leaves the container itself valid.
          if (llvm::isa_and_nonnull<clang::ArraySubscriptExpr>(arg)) {
            return std::nullopt;
          }

          if (const auto* op = llvm::dyn_cast_or_null<clang::CXXOperatorCallExpr>(arg); op != nullptr && op->getOperator() == clang::OO_Subscript) {
            return std::nullopt;
          }

          if (arg != nullptr && isMoveTrackedType(arg->getType())) {
            return extractPlace(arg);
          }
        }
      }

      return std::nullopt;
    }

    // Collects all DeclRefExpr reads of local variables inside a statement (for backward NLL liveness).
    void collectReads(const clang::Stmt* stmt, llvm::SmallVectorImpl<const clang::VarDecl*>& out) {
      if (stmt == nullptr) {
        return;
      }

      llvm::SmallVector<const clang::Stmt*, 16> stack{stmt};

      while (!stack.empty()) {
        const auto* node = stack.pop_back_val();
        if (node == nullptr) {
          continue;
        }

        if (const auto* ref = llvm::dyn_cast<clang::DeclRefExpr>(node)) {
          if (const auto* var = llvm::dyn_cast<clang::VarDecl>(ref->getDecl())) {
            out.push_back(var);
          }
        }

        for (const auto* child : node->children()) {
          stack.push_back(child);
        }
      }
    }

    struct active_loan {
      const clang::VarDecl* borrower = nullptr;
      borrow_place target;
      bool exclusive = false;
      // Non-null when derived by reborrowing through another reference/borrower variable.
      const clang::VarDecl* parent_borrower = nullptr;

      bool operator==(const active_loan&) const = default;
    };

    struct borrow_state {
      bool reachable = false;
      llvm::SmallVector<active_loan, 8> loans;
      llvm::SmallVector<borrow_place, 4> moved;

      bool addLoan(const active_loan& loan) {
        if (llvm::is_contained(loans, loan)) {
          return false;
        }

        loans.push_back(loan);
        return true;
      }

      void removeLoansBy(const clang::VarDecl* borrower) {
        llvm::erase_if(loans, [&](const active_loan& loan) {
          return loan.borrower == borrower;
        });
      }

      bool addMoved(const borrow_place& place) {
        if (llvm::is_contained(moved, place)) {
          return false;
        }

        moved.push_back(place);
        return true;
      }

      void clearMoved(const borrow_place& place) {
        llvm::erase_if(moved, [&](const borrow_place& existing) {
          if (existing.root != place.root) {
            return false;
          }

          // Reassigning a whole object or ancestor clears moved fields beneath it.
          if (place.fields.size() <= existing.fields.size()) {
            return std::equal(place.fields.begin(), place.fields.end(), existing.fields.begin());
          }

          return false;
        });
      }

      bool merge(const borrow_state& other) {
        if (!other.reachable) {
          return false;
        }

        bool changed = false;

        if (!reachable) {
          reachable = true;
          changed = true;
        }

        for (const auto& loan : other.loans) {
          changed = addLoan(loan) || changed;
        }

        for (const auto& place : other.moved) {
          changed = addMoved(place) || changed;
        }

        return changed;
      }
    };

    enum class borrow_issue : std::uint8_t {
      conflicting_borrow = 210,
      conflicting_access = 211,
      use_after_move = 212,
    };

    void reportBorrow(
        borrow_issue kind,
        clang::SourceLocation location,
        clang::SourceLocation note_loc,
        clang::ASTContext& context,
        bool errors,
        llvm::DenseSet<std::uint64_t>& reported
    ) {
      if (location.isInvalid()) {
        return;
      }

      const auto& sources = context.getSourceManager();

      location = sources.getExpansionLoc(location);
      if (sources.isInSystemHeader(location)) {
        return;
      }

      const auto key = (static_cast<std::uint64_t>(location.getRawEncoding()) << 8U) | static_cast<std::uint8_t>(kind);

      // Do not emit a duplicate conflicting-access when lifetime analysis already reported
      // tbc-invalidated-borrow (issue::invalidated == 1) on the same source line.
      if (kind == borrow_issue::conflicting_access) {
        const auto target_file = sources.getFileID(location);
        const auto target_line = sources.getExpansionLineNumber(location);

        for (const auto existing : reported) {
          if ((existing & 0xFFU) != 1U) {
            continue;
          }

          const auto prev = clang::SourceLocation::getFromRawEncoding(static_cast<clang::SourceLocation::UIntTy>(existing >> 8U));
          if (sources.getFileID(prev) == target_file && sources.getExpansionLineNumber(prev) == target_line) {
            return;
          }
        }
      }

      if (!reported.insert(key).second) {
        return;
      }

      auto& diagnostics = context.getDiagnostics();
      const auto severity = errors ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning;
      unsigned id = 0;

      switch (kind) {
      case borrow_issue::conflicting_borrow:
        id = diagnostics.getCustomDiagID(severity, "mutable borrow conflicts with an active borrow of the same place [tbc-conflicting-borrow]");
        break;
      case borrow_issue::conflicting_access:
        id = diagnostics.getCustomDiagID(severity, "access conflicts with an active borrow of the same place [tbc-conflicting-access]");
        break;
      case borrow_issue::use_after_move:
        id = diagnostics.getCustomDiagID(severity, "uses a value after it was moved [tbc-use-after-move]");
        break;
      }

      diagnostics.Report(location, id);
      if (note_loc.isValid() && sources.getExpansionLoc(note_loc) != location) {
        const auto note_id = kind == borrow_issue::use_after_move ? diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Note, "value was moved here") : diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Note, "conflicting borrow created here");

        diagnostics.Report(sources.getExpansionLoc(note_loc), note_id);
      }
    }

    // Whether an active loan `loan` belongs to a borrower variable that is currently live (NLL),
    // excluding accesses through `actor` itself or through a child reborrow of `loan`.
    bool loanIsLive(const active_loan& loan, const llvm::BitVector& live_vars, const llvm::DenseMap<const clang::VarDecl*, unsigned>& var_ids) {
      if (loan.borrower == nullptr) {
        return false;
      }

      const auto found = var_ids.find(loan.borrower);

      return found != var_ids.end() && live_vars.test(found->second);
    }

    // Whether `child` is derived (directly or transitively) from `ancestor` in `loans`.
    bool derivedFrom(const clang::VarDecl* child, const clang::VarDecl* ancestor, llvm::ArrayRef<active_loan> loans) {
      if (child == nullptr || ancestor == nullptr) {
        return false;
      }

      const clang::VarDecl* current = child;

      for (unsigned depth = 0; depth < 8 && current != nullptr; ++depth) {
        if (current == ancestor) {
          return true;
        }

        const clang::VarDecl* next = nullptr;

        for (const auto& loan : loans) {
          if (loan.borrower == current && loan.parent_borrower != nullptr) {
            next = loan.parent_borrower;
            break;
          }
        }

        current = next;
      }

      return false;
    }

    // Whether a type is a non-const reference or mutable view/pointer that lends exclusive access.
    bool isExclusiveBorrowType(clang::QualType type) {
      if (type->isReferenceType()) {
        return !type.getNonReferenceType().isConstQualified();
      }

      if (type->isPointerType()) {
        return !type->getPointeeType().isConstQualified();
      }

      if (standardType(type, "span")) {
        const auto elem = elementType(type);

        return !elem.isNull() && !elem.isConstQualified();
      }

      return false;
    }

    bool isSharedBorrowType(clang::QualType type) {
      if (type->isReferenceType()) {
        return type.getNonReferenceType().isConstQualified();
      }

      if (type->isPointerType()) {
        return type->getPointeeType().isConstQualified();
      }

      if (standardType(type, "basic_string_view")) {
        return true;
      }

      if (standardType(type, "span")) {
        const auto elem = elementType(type);

        return !elem.isNull() && elem.isConstQualified();
      }

      return false;
    }

    // Whether a class aggregate contains a non-const reference field initialized from a local,
    // allowing detection of two independent objects holding the same mutable reference.
    void extractAggregateBorrows(
        const clang::Expr* init,
        const clang::VarDecl* owner,
        const borrow_state& current,
        const clang::ASTContext& context,
        llvm::SmallVectorImpl<active_loan>& created
    ) {
      init = stripBorrowExpr(init);
      if (init == nullptr) {
        return;
      }

      if (const auto* list = llvm::dyn_cast<clang::InitListExpr>(init)) {
        const auto* record = recordOf(list->getType());
        if (record == nullptr || record->getDefinition() == nullptr) {
          return;
        }

        unsigned idx = 0;

        for (const auto* field : record->getDefinition()->fields()) {
          if (idx >= list->getNumInits()) {
            break;
          }

          const auto* field_init = list->getInit(idx++);

          if (isExclusiveBorrowType(field->getType()) || isSharedBorrowType(field->getType())) {
            if (auto target = extractPlace(field_init); target && !isSharedOrSyncPlace(*target, context)) {
              const clang::VarDecl* parent_ref = nullptr;

              if (const auto* ref = llvm::dyn_cast_or_null<clang::DeclRefExpr>(stripBorrowExpr(field_init))) {
                if (const auto* var = llvm::dyn_cast<clang::VarDecl>(ref->getDecl()); var != nullptr && var->getType()->isReferenceType()) {
                  parent_ref = var;
                  for (const auto& existing : current.loans) {
                    if (existing.borrower == var) {
                      target = existing.target;
                      break;
                    }
                  }
                }
              }

              created.push_back({.borrower = owner, .target = *target, .exclusive = isExclusiveBorrowType(field->getType()), .parent_borrower = parent_ref});
            }
          }
        }
      } else if (const auto* ctor = llvm::dyn_cast<clang::CXXConstructExpr>(init)) {
        const auto* constructor = ctor->getConstructor();
        if (constructor == nullptr || libraryRecord(ctor->getType()) || ctor->getNumArgs() == 0) {
          return;
        }

        // Only for constructors of types with reference fields where an argument binds a mutable reference.
        const auto* record = constructor->getParent();
        const bool has_mut_ref_field = llvm::any_of(record->fields(), [](const clang::FieldDecl* field) {
          return field->getType()->isReferenceType() && !field->getType().getNonReferenceType().isConstQualified();
        });
        if (!has_mut_ref_field) {
          return;
        }

        for (unsigned idx = 0; idx < constructor->getNumParams() && idx < ctor->getNumArgs(); ++idx) {
          const auto param_type = constructor->getParamDecl(idx)->getType();
          if (param_type->isReferenceType() && !param_type.getNonReferenceType().isConstQualified()) {
            if (auto target = extractPlace(ctor->getArg(idx)); target && !isSharedOrSyncPlace(*target, context)) {
              created.push_back({.borrower = owner, .target = *target, .exclusive = true, .parent_borrower = nullptr});
            }
          }
        }
      }
    }

    bool isReinitializingMethod(llvm::StringRef name) {
      return name == "operator=" || name == "reset" || name == "clear" || name == "assign" || name == "emplace" || name == "swap";
    }
  }

  void checkExclusiveBorrowsAndMoves(
      const clang::FunctionDecl& definition,
      const clang::CFG& graph,
      clang::ASTContext& context,
      bool errors,
      llvm::DenseSet<std::uint64_t>& reported
  ) {
    if (definition.isImplicit() || definition.isDependentContext() || annotated(definition, "tbc::raw")) {
      return;
    }

    if (const auto* method = llvm::dyn_cast<clang::CXXMethodDecl>(&definition)) {
      if (sharedRecord(*method->getParent()) || ownerRecord(*method->getParent())) {
        return;
      }
    }

    // Step 1: Index local variables for O(1) bitvector NLL liveness, and detect whether this
    // function has any local borrow declarations or std::move calls at all. Functions with neither
    // cannot produce loans or moved places, so they skip both dataflow passes in O(N).
    llvm::DenseMap<const clang::VarDecl*, unsigned> var_ids;
    bool may_borrow_or_move = false;

    for (const auto* block : graph) {
      for (const auto& element : *block) {
        const auto stmt = element.getAs<clang::CFGStmt>();
        if (!stmt) {
          continue;
        }

        const auto* node = stmt->getStmt();
        if (const auto* decl_stmt = llvm::dyn_cast<clang::DeclStmt>(node)) {
          for (const auto* decl : decl_stmt->decls()) {
            if (const auto* var = llvm::dyn_cast<clang::VarDecl>(decl)) {
              const auto next_id = static_cast<unsigned>(var_ids.size());

              var_ids.try_emplace(var, next_id);
              if (!may_borrow_or_move && var->hasInit()) {
                const auto type = var->getType();
                if (isExclusiveBorrowType(type) || isSharedBorrowType(type) || containsViews(type)) {
                  may_borrow_or_move = true;
                }
              }
            }
          }
        } else if (!may_borrow_or_move) {
          if (const auto* call = llvm::dyn_cast<clang::CallExpr>(node)) {
            if (standardFunction(call->getDirectCallee(), "move")) {
              may_borrow_or_move = true;
            }
          }
        }
      }
    }

    if (!may_borrow_or_move) {
      return;
    }

    const auto num_vars = static_cast<unsigned>(var_ids.size());
    const auto num_blocks = graph.getNumBlockIDs();

    // Step 2: Backward NLL use-liveness over CFG blocks.
    llvm::SmallVector<llvm::BitVector, 16> live_in(num_blocks, llvm::BitVector(num_vars));
    llvm::SmallVector<llvm::BitVector, 16> live_out(num_blocks, llvm::BitVector(num_vars));
    llvm::SmallVector<llvm::BitVector, 16> gen(num_blocks, llvm::BitVector(num_vars));
    llvm::SmallVector<llvm::BitVector, 16> kill(num_blocks, llvm::BitVector(num_vars));

    if (num_vars > 0) {
      llvm::SmallVector<const clang::VarDecl*, 16> reads;

      for (const auto* block : graph) {
        const auto id = block->getBlockID();
        auto& block_gen = gen[id];
        auto& block_kill = kill[id];

        for (const auto& element : *block) {
          if (const auto life = element.getAs<clang::CFGLifetimeEnds>()) {
            if (const auto found = var_ids.find(life->getVarDecl()); found != var_ids.end()) {
              block_kill.set(found->second);
            }

            continue;
          }

          const auto stmt = element.getAs<clang::CFGStmt>();
          if (!stmt) {
            continue;
          }

          const auto* node = stmt->getStmt();
          // Plain assignment `v = rhs;` kills non-reference variable `v` after reading `rhs`.
          if (const auto* binary = llvm::dyn_cast<clang::BinaryOperator>(node); binary != nullptr && binary->getOpcode() == clang::BO_Assign) {
            reads.clear();
            collectReads(binary->getRHS(), reads);
            for (const auto* var : reads) {
              if (const auto found = var_ids.find(var); found != var_ids.end() && !block_kill.test(found->second)) {
                block_gen.set(found->second);
              }
            }

            if (const auto* lhs_ref = llvm::dyn_cast<clang::DeclRefExpr>(stripBorrowExpr(binary->getLHS()))) {
              if (const auto* lhs_var = llvm::dyn_cast<clang::VarDecl>(lhs_ref->getDecl()); lhs_var != nullptr && !lhs_var->getType()->isReferenceType()) {
                if (const auto found = var_ids.find(lhs_var); found != var_ids.end()) {
                  block_kill.set(found->second);
                }

                continue;
              }
            }
          }

          reads.clear();
          collectReads(node, reads);
          for (const auto* var : reads) {
            if (const auto found = var_ids.find(var); found != var_ids.end() && !block_kill.test(found->second)) {
              block_gen.set(found->second);
            }
          }
        }
      }

      bool changed = true;

      while (changed) {
        changed = false;
        for (const auto* block : graph) {
          const auto id = block->getBlockID();
          llvm::BitVector out(num_vars);

          for (const auto& succ : block->succs()) {
            if (const auto* next = succ.getReachableBlock()) {
              out |= live_in[next->getBlockID()];
            }
          }

          llvm::BitVector in = out;

          in.reset(kill[id]);
          in |= gen[id];

          if (in != live_in[id] || out != live_out[id]) {
            live_in[id] = std::move(in);
            live_out[id] = std::move(out);
            changed = true;
          }
        }
      }
    }

    // Helper: compute per-element live_after bitvectors for a block.
    const auto computeLiveAfter = [&](const clang::CFGBlock& block) {
      llvm::SmallVector<llvm::BitVector, 16> after(block.size(), llvm::BitVector(num_vars));

      if (num_vars == 0 || block.empty()) {
        return after;
      }

      llvm::BitVector current = live_out[block.getBlockID()];
      llvm::SmallVector<const clang::VarDecl*, 16> reads;

      for (std::size_t idx = block.size(); idx-- > 0;) {
        after[idx] = current;
        const auto& element = block[idx];

        if (const auto life = element.getAs<clang::CFGLifetimeEnds>()) {
          if (const auto found = var_ids.find(life->getVarDecl()); found != var_ids.end()) {
            current.reset(found->second);
          }

          continue;
        }

        const auto stmt = element.getAs<clang::CFGStmt>();
        if (!stmt) {
          continue;
        }

        const auto* node = stmt->getStmt();
        if (const auto* binary = llvm::dyn_cast<clang::BinaryOperator>(node); binary != nullptr && binary->getOpcode() == clang::BO_Assign) {
          if (const auto* lhs_ref = llvm::dyn_cast<clang::DeclRefExpr>(stripBorrowExpr(binary->getLHS()))) {
            if (const auto* lhs_var = llvm::dyn_cast<clang::VarDecl>(lhs_ref->getDecl()); lhs_var != nullptr && !lhs_var->getType()->isReferenceType()) {
              if (const auto found = var_ids.find(lhs_var); found != var_ids.end()) {
                current.reset(found->second);
              }
            }
          }

          reads.clear();
          collectReads(binary->getRHS(), reads);
          for (const auto* var : reads) {
            if (const auto found = var_ids.find(var); found != var_ids.end()) {
              current.set(found->second);
            }
          }

          continue;
        }

        reads.clear();
        collectReads(node, reads);
        for (const auto* var : reads) {
          if (const auto found = var_ids.find(var); found != var_ids.end()) {
            current.set(found->second);
          }
        }
      }

      return after;
    };

    // Step 3: Forward fixed-point over loans and moved places.
    llvm::SmallVector<borrow_state, 16> entry_states(num_blocks);
    llvm::SmallVector<const clang::CFGBlock*, 16> worklist;
    llvm::SmallVector<bool, 16> queued(num_blocks, false);

    entry_states[graph.getEntry().getBlockID()].reachable = true;
    worklist.push_back(&graph.getEntry());
    queued[graph.getEntry().getBlockID()] = true;

    const auto transferBlock = [&](const clang::CFGBlock& block, borrow_state& current, bool emit) {
      const auto live_after = emit ? computeLiveAfter(block) : llvm::SmallVector<llvm::BitVector, 16>{};
      const llvm::BitVector empty_live(num_vars);

      // Checks if `place` conflicts with any live active loan when accessed as write/read/borrow.
      const auto checkConflict = [&](
                                     const borrow_place& place,
                                     const clang::VarDecl* actor,
                                     bool is_write,
                                     bool is_creating_borrow,
                                     clang::SourceLocation loc,
                                     const llvm::BitVector& live_vars
                                 ) -> bool {
        if (!emit || isSharedOrSyncPlace(place, context)) {
          return false;
        }

        for (const auto& loan : current.loans) {
          if (!loanIsLive(loan, live_vars, var_ids)) {
            continue;
          }

          if (loan.borrower == actor || derivedFrom(actor, loan.borrower, current.loans)) {
            continue;
          }

          // If `loan` is a derived child reborrow of `actor` (e.g., `child` reborrowed from `parent`),
          // accessing `parent` while `child` is still live conflicts with `child`!
          const bool actor_is_suspended_parent = actor != nullptr && derivedFrom(loan.borrower, actor, current.loans);

          if (!actor_is_suspended_parent && !placesOverlap(place, loan.target)) {
            continue;
          }

          if (is_write || loan.exclusive || actor_is_suspended_parent) {
            const auto kind = is_creating_borrow ? borrow_issue::conflicting_borrow : borrow_issue::conflicting_access;

            reportBorrow(kind, loc, loan.borrower->getLocation(), context, errors, reported);
            return true;
          }
        }

        return false;
      };

      const auto checkMovedUse = [&](const borrow_place& place, clang::SourceLocation loc) {
        if (!emit) {
          return;
        }

        for (const auto& moved_place : current.moved) {
          if (placesOverlap(place, moved_place)) {
            reportBorrow(borrow_issue::use_after_move, loc, clang::SourceLocation{}, context, errors, reported);
            return;
          }
        }
      };

      // Resolves a reference variable to the underlying place it borrows, if known.
      const auto resolveTarget = [&](const clang::Expr* expr, const clang::VarDecl*& actor_out) -> std::optional<borrow_place> {
        actor_out = nullptr;
        const auto* stripped = stripBorrowExpr(expr);
        if (const auto* ref = llvm::dyn_cast_or_null<clang::DeclRefExpr>(stripped)) {
          if (const auto* var = llvm::dyn_cast<clang::VarDecl>(ref->getDecl()); var != nullptr && var->getType()->isReferenceType()) {
            actor_out = var;
            for (const auto& loan : current.loans) {
              if (loan.borrower == var) {
                return loan.target;
              }
            }
          }
        }

        return extractPlace(expr);
      };

      for (std::size_t idx = 0; idx < block.size(); ++idx) {
        const auto& element = block[idx];
        const auto& live_vars = emit ? live_after[idx] : empty_live;

        if (const auto life = element.getAs<clang::CFGLifetimeEnds>()) {
          current.removeLoansBy(life->getVarDecl());
          current.clearMoved({.root = life->getVarDecl(), .fields = {}});
          continue;
        }

        const auto stmt = element.getAs<clang::CFGStmt>();
        if (!stmt) {
          continue;
        }

        const auto* node = stmt->getStmt();

        // 1. Variable declarations (creating borrows, reborrows, or consuming std::move).
        if (const auto* decl_stmt = llvm::dyn_cast<clang::DeclStmt>(node)) {
          for (const auto* decl : decl_stmt->decls()) {
            const auto* var = llvm::dyn_cast<clang::VarDecl>(decl);
            if (var == nullptr || !var->hasInit()) {
              continue;
            }

            const auto* init = var->getInit();

            // Move consumption in variable initialization (`auto b = std::move(a);`).
            if (const auto moved = extractMovedPlace(init)) {
              checkMovedUse(*moved, init->getBeginLoc());
              checkConflict(*moved, nullptr, true, false, init->getBeginLoc(), live_vars);
              current.addMoved(*moved);
            } else if (const auto* ctor = llvm::dyn_cast<clang::CXXConstructExpr>(stripBorrowExpr(init)); ctor != nullptr && ctor->getConstructor()->isMoveConstructor() && ctor->getNumArgs() == 1) {
              if (const auto moved_arg = extractMovedPlace(ctor->getArg(0))) {
                checkMovedUse(*moved_arg, ctor->getBeginLoc());
                checkConflict(*moved_arg, nullptr, true, false, ctor->getBeginLoc(), live_vars);
                current.addMoved(*moved_arg);
              }
            }

            // Reference or pointer/view borrow creation.
            const auto type = var->getType();
            if (isExclusiveBorrowType(type) || isSharedBorrowType(type)) {
              // Skip if initialized from tbc::raw(...).
              if (const auto* call = llvm::dyn_cast_or_null<clang::CallExpr>(stripBorrowExpr(init))) {
                const auto* callee = call->getDirectCallee();
                const auto* pattern = callee == nullptr ? nullptr : callee->getTemplateInstantiationPattern();
                if (callee != nullptr && (annotated(*callee, "tbc::raw") || (pattern != nullptr && annotated(*pattern, "tbc::raw")))) {
                  continue;
                }
              }

              const clang::VarDecl* parent_ref = nullptr;
              std::optional<borrow_place> target;

              if (type->isPointerType()) {
                // Copying a pointer value (`T* q = p;`) copies the address rather than borrowing
                // the stack variable `p` itself; only `&x` or inheriting `p`'s existing loan creates a loan.
                const auto* stripped_init = stripBorrowExpr(init);
                if (const auto* addr = llvm::dyn_cast_or_null<clang::UnaryOperator>(stripped_init); addr != nullptr && addr->getOpcode() == clang::UO_AddrOf) {
                  target = resolveTarget(addr->getSubExpr(), parent_ref);
                } else if (const auto* ref = llvm::dyn_cast_or_null<clang::DeclRefExpr>(stripped_init)) {
                  if (const auto* src_var = llvm::dyn_cast<clang::VarDecl>(ref->getDecl())) {
                    for (const auto& existing : current.loans) {
                      if (existing.borrower == src_var) {
                        parent_ref = src_var;
                        target = existing.target;
                        break;
                      }
                    }
                  }
                }
              } else {
                target = resolveTarget(init, parent_ref);
              }

              if (target && !isSharedOrSyncPlace(*target, context)) {
                const bool exclusive = isExclusiveBorrowType(type);
                // Reborrow (`int& child = parent`) inherits parent_ref and does not conflict with parent.
                if (!checkConflict(*target, parent_ref, exclusive, true, var->getLocation(), live_vars)) {
                  current.addLoan({.borrower = var, .target = *target, .exclusive = exclusive, .parent_borrower = parent_ref});
                }
              }
            } else {
              // Aggregate or class holding reference fields (two objects holding the same &mut).
              llvm::SmallVector<active_loan, 2> created;

              extractAggregateBorrows(init, var, current, context, created);
              for (const auto& loan : created) {
                if (!checkConflict(loan.target, loan.parent_borrower, loan.exclusive, true, var->getLocation(), live_vars)) {
                  current.addLoan(loan);
                }
              }
            }
          }

          continue;
        }

        // 2. Assignments & compound assignments (`value = 2;`, `first += 1;`).
        if (const auto* binary = llvm::dyn_cast<clang::BinaryOperator>(node); binary != nullptr && binary->isAssignmentOp()) {
          const clang::VarDecl* actor = nullptr;
          if (const auto target = resolveTarget(binary->getLHS(), actor)) {
            if (binary->getOpcode() == clang::BO_Assign) {
              // Plain assignment reinitializes a moved place, but still conflicts with active borrows.
              current.clearMoved(*target);
            } else {
              checkMovedUse(*target, binary->getOperatorLoc());
            }

            checkConflict(*target, actor, true, false, binary->getOperatorLoc(), live_vars);
          }

          if (const auto moved = extractMovedPlace(binary->getRHS())) {
            checkMovedUse(*moved, binary->getRHS()->getBeginLoc());
            checkConflict(*moved, nullptr, true, false, binary->getRHS()->getBeginLoc(), live_vars);
            current.addMoved(*moved);
          }

          continue;
        }

        // 3. Increment/decrement (`++value`, `value--`).
        if (const auto* unary = llvm::dyn_cast<clang::UnaryOperator>(node); unary != nullptr && unary->isIncrementDecrementOp()) {
          const clang::VarDecl* actor = nullptr;
          if (const auto target = resolveTarget(unary->getSubExpr(), actor)) {
            checkMovedUse(*target, unary->getOperatorLoc());
            checkConflict(*target, actor, true, false, unary->getOperatorLoc(), live_vars);
          }

          continue;
        }

        // 4. Function and method calls (including two-phase borrows and move consumption).
        if (const auto* call = llvm::dyn_cast<clang::CallExpr>(node)) {
          const auto* callee = call->getDirectCallee();

          // std::exchange(x, y) reads and immediately replaces x (not a use-after-move!).
          if (standardFunction(callee, "exchange") && call->getNumArgs() == 2) {
            const clang::VarDecl* actor = nullptr;
            if (const auto target = resolveTarget(call->getArg(0), actor)) {
              checkMovedUse(*target, call->getBeginLoc());
              checkConflict(*target, actor, true, false, call->getBeginLoc(), live_vars);
              current.clearMoved(*target);
            }

            continue;
          }

          // Member call: check receiver for moved-use and exclusive conflict (two-phase: activates here
          // AFTER argument expressions have already been evaluated in the CFG!).
          if (const auto* member_call = llvm::dyn_cast<clang::CXXMemberCallExpr>(call)) {
            const auto* method = member_call->getMethodDecl();
            const auto* obj = member_call->getImplicitObjectArgument();
            if (method != nullptr && obj != nullptr) {
              const clang::VarDecl* actor = nullptr;
              if (const auto target = resolveTarget(obj, actor)) {
                const bool reinit = method->getIdentifier() != nullptr && isReinitializingMethod(method->getName());
                if (reinit) {
                  current.clearMoved(*target);
                } else {
                  checkMovedUse(*target, call->getBeginLoc());
                }

                checkConflict(*target, actor, !method->isConst(), false, call->getBeginLoc(), live_vars);
              }
            }
          } else if (const auto* op_call = llvm::dyn_cast<clang::CXXOperatorCallExpr>(call); op_call != nullptr && op_call->getNumArgs() >= 1) {
            const auto* method = llvm::dyn_cast_or_null<clang::CXXMethodDecl>(callee);
            if (method != nullptr) {
              const clang::VarDecl* actor = nullptr;
              if (const auto target = resolveTarget(op_call->getArg(0), actor)) {
                if (op_call->getOperator() == clang::OO_Equal) {
                  current.clearMoved(*target);
                } else {
                  checkMovedUse(*target, call->getBeginLoc());
                }

                checkConflict(*target, actor, !method->isConst(), false, call->getBeginLoc(), live_vars);
              }
            }
          }

          // Check arguments for conflicts and move consumption.
          if (callee != nullptr && !standardFunction(callee, "move") && !standardFunction(callee, "forward")) {
            const unsigned offset = llvm::isa<clang::CXXOperatorCallExpr>(call) && llvm::isa<clang::CXXMethodDecl>(callee) ? 1U : 0U;

            for (unsigned arg_idx = offset; arg_idx < call->getNumArgs(); ++arg_idx) {
              const auto* arg = call->getArg(arg_idx);
              const unsigned param_idx = arg_idx - offset;
              const clang::ParmVarDecl* param = param_idx < callee->getNumParams() ? callee->getParamDecl(param_idx) : nullptr;
              const bool mut_param = param != nullptr && param->getType()->isReferenceType() && !param->getType().getNonReferenceType().isConstQualified() && !param->getType()->isRValueReferenceType();
              const bool consumes_move = param != nullptr && (!param->getType()->isReferenceType() || param->getType()->isRValueReferenceType());

              if (consumes_move) {
                if (const auto moved = extractMovedPlace(arg)) {
                  checkMovedUse(*moved, arg->getBeginLoc());
                  checkConflict(*moved, nullptr, true, false, arg->getBeginLoc(), live_vars);
                  current.addMoved(*moved);
                  continue;
                }
              }

              const clang::VarDecl* actor = nullptr;
              if (const auto target = resolveTarget(arg, actor)) {
                checkMovedUse(*target, arg->getBeginLoc());
                checkConflict(*target, actor, mut_param, false, arg->getBeginLoc(), live_vars);
              }
            }
          }

          continue;
        }

        // 5. Reads of variables (`LValueToRValue` casts): check against active exclusive loans & moves.
        if (const auto* read = llvm::dyn_cast<clang::ImplicitCastExpr>(node); read != nullptr && read->getCastKind() == clang::CK_LValueToRValue) {
          const clang::VarDecl* actor = nullptr;
          if (const auto target = resolveTarget(read->getSubExpr(), actor)) {
            checkMovedUse(*target, read->getBeginLoc());
            checkConflict(*target, actor, false, false, read->getBeginLoc(), live_vars);
          }
        }
      }
    };

    while (!worklist.empty()) {
      const auto* block = worklist.pop_back_val();

      queued[block->getBlockID()] = false;

      borrow_state out = entry_states[block->getBlockID()];

      transferBlock(*block, out, false);

      for (const auto& succ : block->succs()) {
        if (const auto* next = succ.getReachableBlock()) {
          if (entry_states[next->getBlockID()].merge(out) && !queued[next->getBlockID()]) {
            queued[next->getBlockID()] = true;
            worklist.push_back(next);
          }
        }
      }
    }

    for (const auto* block : graph) {
      if (!entry_states[block->getBlockID()].reachable) {
        continue;
      }

      borrow_state current = entry_states[block->getBlockID()];

      transferBlock(*block, current, true);
    }
  }
}
