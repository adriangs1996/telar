#include "lifetime_analysis.hpp"
#include "view_type.hpp"

#include <clang/AST/ExprCXX.h>
#include <clang/AST/ParentMapContext.h>
#include <clang/Analysis/CFG.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/BitVector.h>
#include <llvm/ADT/DenseMap.h>
#include <llvm/ADT/Hashing.h>
#include <llvm/ADT/STLExtras.h>
#include <llvm/ADT/SetVector.h>
#include <llvm/ADT/SmallPtrSet.h>
#include <llvm/ADT/SmallVector.h>

#include <algorithm>
#include <memory>
#include <optional>
#include <string>

namespace tbc_lint {
  namespace {
    enum class origin_kind : std::uint8_t {
      parameter,
      parameter_storage,
      parameter_pointee,
      captured_storage,
      captured_contents,
      static_storage,
      environment,
      receiver,
      receiver_region,
      local,
      temporary,
      unknown,
    };

    enum class issue : std::uint8_t {
      dangling,
      invalidated,
      contract,
      ambiguous,
      missing,
    };

    // How deep a borrow reaches into a variable: the variable itself, the storage it owns, such as a
    // container's element slots, and then each level owned by the one above, such as the objects those
    // slots own through pointers. Levels below the deepest one merge into it.
    enum class storage_kind : std::uint8_t {
      inherited,
      object,
      data,
      deepest = 8,
    };

    // How many levels a borrow lies below the variable itself.
    constexpr unsigned depth(storage_kind kind) {
      return std::to_underlying(std::max(kind, storage_kind::object)) - std::to_underlying(storage_kind::object);
    }

    constexpr storage_kind below(storage_kind kind, unsigned levels) {
      const unsigned level = std::to_underlying(std::max(kind, storage_kind::object)) + levels;
      return static_cast<storage_kind>(std::min<unsigned>(level, std::to_underlying(storage_kind::deepest)));
    }

    // The storage owned by an object at the given level.
    constexpr storage_kind deepen(storage_kind kind) {
      return below(kind, depth(storage_kind::data));
    }

    // The levels an operation invalidates, relative to the object it operates on.
    struct storage_range {
      storage_kind first = storage_kind::data;
      storage_kind last = storage_kind::data;

      [[nodiscard]] bool contains(storage_kind kind) const {
        return kind != storage_kind::inherited && kind >= first && kind <= last;
      }

      [[nodiscard]] storage_range widen(storage_range other) const {
        return {.first = std::min(first, other.first), .last = std::max(last, other.last)};
      }

      // The same operation on an object that lies at a given level inside its variable.
      [[nodiscard]] storage_range inside(storage_kind level) const {
        return {.first = below(first, depth(level)), .last = below(last, depth(level))};
      }
    };

    // Moving element slots leaves what they own in place; destroying elements frees everything below them.
    constexpr storage_range element_slots{.first = storage_kind::data, .last = storage_kind::data};
    constexpr storage_range owned_storage{.first = storage_kind::data, .last = storage_kind::deepest};

    // A field on the way to a place, and the level of the object that holds it. A step without a field
    // cuts the path at its level: which fields lie below it there is not known, as inside a union.
    struct projection {
      const clang::FieldDecl *field = nullptr;
      storage_kind level = storage_kind::object;

      bool operator==(const projection &) const = default;
    };

    // The most steps a path records. The steps past it are not known, which keeps the places finite
    // while loops walk through nested and recursive structures. Where an object holds a borrow is
    // recorded more coarsely than where a borrow points.
    enum class path_bound : std::uint8_t {
      held = 2,
      steps = 4,
    };

    // The fields leading from a variable to a place inside it, outermost first.
    using field_path = llvm::SmallVector<projection, 2>;

    // Appends a step unless the path is full or already cut at the step's level. The deepest level
    // merges every level below it, so its fields are not recorded.
    void appendStep(field_path &path, projection step, path_bound bound = path_bound::steps) {
      if (step.level == storage_kind::deepest || path.size() >= std::to_underlying(bound)) {
        return;
      }
      if (!path.empty() && (path.back().level > step.level || (path.back().level == step.level && path.back().field == nullptr))) {
        return;
      }

      path.push_back(step);
    }

    // The members of a union share one place.
    void appendField(field_path &path, const clang::FieldDecl &field, storage_kind level, path_bound bound = path_bound::steps) {
      appendStep(path, {.field = field.getParent()->isUnion() ? nullptr : &field, .level = level}, bound);
    }

    // Appends the steps of a path that lie at or below one level, moving that level onto another.
    void appendMoved(field_path &into, const field_path &steps, storage_kind from, storage_kind onto) {
      for (auto step : steps) {
        if (step.level < from) {
          continue;
        }
        step.level = below(onto, depth(step.level) - depth(from));
        appendStep(into, step);
      }
    }

    // A summary's level lies as many levels below its symbolic input as the result lies below the actual one.
    constexpr storage_kind relocate(storage_kind actual, storage_kind symbolic) {
      return depth(symbolic) == 0 ? actual : below(actual, depth(symbolic));
    }

    // A place inside a variable: the level of the object there, and the fields that lead to it.
    struct object_place {
      const clang::ValueDecl *variable = nullptr;
      storage_kind level = storage_kind::object;
      field_path path{};

      bool operator==(const object_place &) const = default;
    };

    // The place a callee's place denotes once its own variable is replaced by an actual place.
    object_place rebased(object_place actual, const object_place &symbolic) {
      appendMoved(actual.path, symbolic.path, storage_kind::object, actual.level);
      actual.level = relocate(actual.level, symbolic.level);
      return actual;
    }

    // Whether a borrow's place can lie inside the object at a place: on every level down to that
    // object, the fields leading to both agree as far as both are known.
    bool within(const field_path &borrow, const object_place &target) {
      for (unsigned level = 0; level <= depth(target.level); ++level) {
        const auto at = [level](const projection &step) { return depth(step.level) == level; };
        for (const auto [left, right] : llvm::zip(llvm::make_filter_range(borrow, at), llvm::make_filter_range(target.path, at))) {
          if (left.field == nullptr || right.field == nullptr) {
            break;
          }
          if (left.field != right.field) {
            return false;
          }
        }
      }

      return true;
    }

    struct origin {
      origin_kind kind;
      storage_kind storage = storage_kind::inherited;
      field_path path{};
      // Where the object holding this borrow keeps it: the fields of that object that lead to it.
      field_path held{};
      // For a borrow that stands for what an input held, the part of the input it stands for.
      field_path select{};
      const clang::ValueDecl *variable = nullptr;
      const clang::Expr *expression = nullptr;
      const clang::Type *region = nullptr;
      const clang::Stmt *invalidated = nullptr;
      const clang::Stmt *full_expression = nullptr;
      clang::SourceLocation borrow_site{};
    };

    // Where a borrow of a local or a temporary was taken, which is where its escape is reported. Other
    // borrows keep no site, so that they stay one borrow wherever they were taken.
    void markBorrowSite(origin &source, clang::SourceLocation location) {
      if (source.borrow_site.isInvalid() && (source.kind == origin_kind::local || source.kind == origin_kind::temporary)) {
        source.borrow_site = location;
      }
    }

    // Two borrows of the same storage, whatever position holds them. Every field but `held` counts.
    bool sameBorrow(const origin &left, const origin &right) {
      return left.kind == right.kind && left.storage == right.storage && left.path == right.path && left.select == right.select && left.variable == right.variable && left.expression == right.expression && left.region == right.region && left.invalidated == right.invalidated && left.full_expression == right.full_expression && left.borrow_site == right.borrow_site;
    }

    llvm::hash_code borrowHash(const origin &value) {
      auto path = llvm::hash_value(value.path.size());
      for (const auto &step : value.path) {
        path = llvm::hash_combine(path, step.field, std::to_underlying(step.level));
      }
      for (const auto &step : value.select) {
        path = llvm::hash_combine(path, step.field);
      }
      return llvm::hash_combine(std::to_underlying(value.kind), std::to_underlying(value.storage), path, value.variable, value.expression, value.region, value.invalidated, value.full_expression, value.borrow_site.getRawEncoding());
    }

    // Whether a borrow held at one position stands for the same borrow held at another: the second
    // lies inside the first, or the first is cut before they differ.
    bool covers(const field_path &outer, const field_path &inner) {
      for (std::size_t index = 0; index < outer.size(); ++index) {
        if (outer[index].field == nullptr) {
          return true;
        }
        if (index == inner.size() || inner[index].field != outer[index].field) {
          return false;
        }
      }

      return true;
    }

    // A set of borrows. A borrow held at a position another one of it covers adds nothing, so the
    // set keeps the covering one. Large sets are matched through hashes rather than value by value.
    struct loans {
      llvm::SmallVector<origin, 2> values;

      bool add(const origin &value) {
        return merge(llvm::ArrayRef<origin>(value));
      }

      bool merge(llvm::ArrayRef<origin> incoming) {
        const bool hashed = values.size() * incoming.size() > values.size() + incoming.size();
        llvm::DenseMap<llvm::hash_code, llvm::SmallVector<unsigned, 1>> index;
        if (hashed) {
          for (unsigned position = 0; position < values.size(); ++position) {
            index[borrowHash(values[position])].push_back(position);
          }
        }
        llvm::BitVector covered(static_cast<unsigned>(values.size()));
        bool changed = false;
        for (const auto &value : incoming) {
          auto *bucket = hashed ? &index[borrowHash(value)] : nullptr;
          bool redundant = false;
          const auto compare = [&](unsigned position) {
            if (covered.test(position) || !sameBorrow(values[position], value)) {
              return;
            }
            if (covers(values[position].held, value.held)) {
              redundant = true;
            } else if (covers(value.held, values[position].held)) {
              covered.set(position);
            }
          };
          if (bucket != nullptr) {
            for (const auto position : *bucket) {
              compare(position);
            }
          } else {
            for (unsigned position = 0; position < values.size(); ++position) {
              compare(position);
            }
          }
          if (redundant) {
            continue;
          }

          if (bucket != nullptr) {
            bucket->push_back(static_cast<unsigned>(values.size()));
          }
          values.push_back(value);
          covered.push_back(false);
          changed = true;
        }
        if (covered.any()) {
          llvm::SmallVector<origin, 2> kept;
          for (unsigned position = 0; position < values.size(); ++position) {
            if (!covered.test(position)) {
              kept.push_back(std::move(values[position]));
            }
          }
          values = std::move(kept);
        }

        return changed;
      }

      bool merge(const loans &other) {
        return merge(llvm::ArrayRef<origin>(other.values));
      }
    };

    enum class containment : std::uint8_t {
      inside,
      covering,
      apart,
    };

    // How a position inside an object relates to the subobject at some of its fields: inside it, at
    // an unknown position that covers it, or apart from it.
    containment contain(const field_path &position, const field_path &fields) {
      for (std::size_t index = 0; index < fields.size(); ++index) {
        if (index == position.size() || position[index].field == nullptr || fields[index].field == nullptr) {
          return containment::covering;
        }
        if (position[index].field != fields[index].field) {
          return containment::apart;
        }
      }

      return containment::inside;
    }

    // A borrow that stands for what an input held at its position, whatever input part that was.
    bool standsForInput(const origin &source) {
      return source.kind == origin_kind::parameter || source.kind == origin_kind::parameter_pointee || source.kind == origin_kind::receiver_region || source.kind == origin_kind::captured_contents;
    }

    // Such a borrow, moved from its position to one inside it, stands for the same part of the input.
    // Where its position is cut, which part is not known, so it never narrows again.
    void narrow(origin &source, const field_path &position) {
      if (!standsForInput(source)) {
        return;
      }
      if (std::ranges::any_of(source.held, [](const projection &step) { return step.field == nullptr; })) {
        appendStep(source.select, {.field = nullptr}, path_bound::held);
        return;
      }
      for (std::size_t index = source.held.size(); index < position.size(); ++index) {
        appendStep(source.select, position[index], path_bound::held);
      }
    }

    // What a subobject at some fields holds: the borrows held inside it, and those held at a position
    // that covers it.
    loans selected(const loans &contents, const field_path &fields) {
      llvm::SmallVector<origin, 4> kept;
      for (auto source : contents.values) {
        const auto relation = contain(source.held, fields);
        if (relation == containment::apart) {
          continue;
        }
        if (relation == containment::inside) {
          source.held.erase(source.held.begin(), source.held.begin() + static_cast<std::ptrdiff_t>(fields.size()));
        } else {
          narrow(source, fields);
          source.held.clear();
        }
        kept.push_back(std::move(source));
      }

      loans result;
      result.merge(kept);
      return result;
    }

    loans selected(const loans &contents, const clang::FieldDecl &field) {
      field_path fields;
      appendField(fields, field, storage_kind::object);
      return selected(contents, fields);
    }

    // The fields leading to a place while it lies inline in its variable, which is where the variable
    // holds what the place holds. Contents of owned storage are held where its owner lies.
    field_path inlineFields(const field_path &path) {
      field_path result;
      for (const auto &step : path) {
        if (depth(step.level) == 0) {
          result.push_back(step);
        }
      }

      return result;
    }

    // The same contents, held at some fields of a larger object.
    loans heldAt(const loans &contents, const field_path &fields) {
      if (fields.empty()) {
        return contents;
      }

      llvm::SmallVector<origin, 4> moved;
      for (auto source : contents.values) {
        field_path position;
        for (const auto &step : fields) {
          appendStep(position, step, path_bound::held);
        }
        for (const auto &step : source.held) {
          appendStep(position, step, path_bound::held);
        }
        source.held = std::move(position);
        moved.push_back(std::move(source));
      }

      loans result;
      result.merge(moved);
      return result;
    }

    // Contents whose position inside their new holder is not known, as inside a library object.
    loans unplaced(const loans &contents) {
      llvm::SmallVector<origin, 4> moved;
      for (auto source : contents.values) {
        if (standsForInput(source)) {
          appendStep(source.select, {.field = nullptr}, path_bound::held);
        }
        source.held.clear();
        moved.push_back(std::move(source));
      }

      loans result;
      result.merge(moved);
      return result;
    }

    // The fields of a record, its bases' first.
    void recordFields(const clang::CXXRecordDecl &record, llvm::SmallVectorImpl<const clang::FieldDecl *> &fields) {
      for (const auto &base : record.bases()) {
        const auto *parent = base.getType()->getAsCXXRecordDecl();
        if (parent != nullptr && parent->hasDefinition()) {
          recordFields(*parent->getDefinition(), fields);
        }
      }
      for (const auto *field : record.fields()) {
        fields.push_back(field);
      }
    }

    // A borrow held at an unknown position that covers the fields being replaced may lie in any other
    // field on the way to them, so it moves to each of those. Fails when they cannot be listed.
    bool spread(const origin &source, clang::QualType holder, const field_path &fields, loans &into) {
      const auto cut = [](const projection &step) { return step.field == nullptr; };
      if (std::ranges::any_of(source.held, cut) || std::ranges::any_of(fields, cut)) {
        return false;
      }
      auto type = holder.getNonReferenceType();
      for (std::size_t index = 0; index < source.held.size(); ++index) {
        type = fields[index].field->getType().getNonReferenceType();
      }
      loans siblings;
      for (std::size_t index = source.held.size(); index < fields.size(); ++index) {
        const auto *record = recordOf(type);
        if (record == nullptr || !record->hasDefinition() || record->isUnion()) {
          return false;
        }
        llvm::SmallVector<const clang::FieldDecl *, 8> members;
        recordFields(*record->getDefinition(), members);
        if (std::ranges::find(members, fields[index].field) == members.end()) {
          return false;
        }
        for (const auto *member : members) {
          if (member != fields[index].field && containsViews(member->getType())) {
            field_path position(fields.begin(), fields.begin() + static_cast<std::ptrdiff_t>(index));
            appendField(position, *member, storage_kind::object, path_bound::held);
            auto copy = source;
            narrow(copy, position);
            copy.held = std::move(position);
            siblings.add(copy);
          }
        }
        type = fields[index].field->getType().getNonReferenceType();
      }
      into.merge(siblings);
      return true;
    }

    // Replaces what a holder of the given type keeps at some of its fields.
    void replaceHeld(loans &contents, clang::QualType holder, const field_path &fields, const loans &incoming) {
      llvm::SmallVector<origin, 4> kept;
      loans spreads;
      for (const auto &source : contents.values) {
        const auto relation = contain(source.held, fields);
        if (relation == containment::apart || (relation == containment::covering && !spread(source, holder, fields, spreads))) {
          kept.push_back(source);
        }
      }
      loans result;
      result.merge(kept);
      result.merge(spreads);
      result.merge(heldAt(incoming, fields));
      contents = std::move(result);
    }

    struct state {
      llvm::DenseMap<const clang::ValueDecl *, loans> values;
      llvm::DenseMap<const clang::ValueDecl *, loans> references;
      llvm::SmallPtrSet<const clang::ValueDecl *, 8> written;

      loans get(const clang::ValueDecl *key) const {
        const auto found = values.find(key);
        return found == values.end() ? loans{} : found->second;
      }

      loans getReference(const clang::ValueDecl *key) const {
        const auto found = references.find(key);
        return found == references.end() ? loans{} : found->second;
      }

      bool merge(const state &other) {
        bool changed = false;
        for (const auto &entry : other.values) {
          changed = values[entry.first].merge(entry.second) || changed;
        }
        for (const auto &entry : other.references) {
          changed = references[entry.first].merge(entry.second) || changed;
        }
        for (const auto *key : other.written) {
          changed = written.insert(key).second || changed;
        }

        return changed;
      }
    };

    // The levels an operation invalidates below a place.
    struct invalidation {
      object_place target;
      storage_range range;
    };

    struct function_summary {
      loans returned;
      llvm::DenseMap<const clang::ValueDecl *, loans> writes;
      bool invalidates_environment = false;
      llvm::SmallVector<invalidation, 2> invalidates;
      // The parameters and receiver fields whose incoming contents the function uses.
      llvm::SmallSetVector<const clang::ValueDecl *, 4> uses;

      bool invalidate(const object_place &target, storage_range range) {
        const auto found = std::ranges::find_if(invalidates, [&](const invalidation &entry) { return entry.target == target; });
        if (found == invalidates.end()) {
          invalidates.push_back({.target = target, .range = range});
          return true;
        }

        const auto widened = found->range.widen(range);
        const bool changed = widened.first != found->range.first || widened.last != found->range.last;
        found->range = widened;
        return changed;
      }

      bool merge(const function_summary &other) {
        bool changed = returned.merge(other.returned);
        if (other.invalidates_environment && !invalidates_environment) {
          invalidates_environment = true;
          changed = true;
        }
        for (const auto &[target, range] : other.invalidates) {
          changed = invalidate(target, range) || changed;
        }
        for (const auto *input : other.uses) {
          changed = uses.insert(input) || changed;
        }
        for (const auto &entry : other.writes) {
          const auto inserted = writes.try_emplace(entry.first);
          changed = inserted.second || changed;
          changed = inserted.first->second.merge(entry.second) || changed;
        }

        return changed;
      }
    };

    struct function_entry {
      const clang::FunctionDecl *definition;
      std::unique_ptr<clang::CFG> graph;
      function_summary summary;
      llvm::SmallSetVector<const clang::FunctionDecl *, 8> dependents;
      bool queued = false;
    };

    // Functions are solved in the order the translation unit declares them, so results never depend on addresses.
    struct inference_cache {
      llvm::DenseMap<const clang::FunctionDecl *, std::unique_ptr<function_entry>> functions;
      llvm::SmallVector<const clang::FunctionDecl *, 32> order;

      void clear() {
        functions.clear();
        order.clear();
      }
    };

    const clang::Expr *clean(const clang::Expr *expression) {
      if (expression == nullptr) {
        return nullptr;
      }

      expression = expression->IgnoreParens();
      if (const auto *cast = llvm::dyn_cast<clang::ImplicitCastExpr>(expression)) {
        return clean(cast->getSubExpr());
      }
      if (const auto *cleanup = llvm::dyn_cast<clang::ExprWithCleanups>(expression)) {
        return clean(cleanup->getSubExpr());
      }
      if (const auto *bound = llvm::dyn_cast<clang::CXXBindTemporaryExpr>(expression)) {
        return clean(bound->getSubExpr());
      }
      // A constant-evaluated expression borrows exactly what the expression it wraps borrows.
      if (const auto *constant = llvm::dyn_cast<clang::ConstantExpr>(expression)) {
        return clean(constant->getSubExpr());
      }

      return expression;
    }

    const clang::ValueDecl *place(const clang::Expr *expression) {
      expression = clean(expression);
      if (expression == nullptr) {
        return nullptr;
      }
      if (const auto *reference = llvm::dyn_cast<clang::DeclRefExpr>(expression)) {
        return reference->getDecl();
      }
      if (const auto *member = llvm::dyn_cast<clang::MemberExpr>(expression)) {
        if (llvm::isa<clang::CXXThisExpr>(clean(member->getBase()))) {
          return member->getMemberDecl();
        }

        return place(member->getBase());
      }
      if (const auto *operation = llvm::dyn_cast<clang::CXXOperatorCallExpr>(expression)) {
        return operation->getNumArgs() == 0 ? nullptr : place(operation->getArg(0));
      }
      if (const auto *index = llvm::dyn_cast<clang::ArraySubscriptExpr>(expression)) {
        return place(index->getBase());
      }
      if (const auto *unary = llvm::dyn_cast<clang::UnaryOperator>(expression)) {
        return place(unary->getSubExpr());
      }

      return nullptr;
    }

    // The pointer whose pointee holds the object an expression designates, if any.
    const clang::Expr *dereferencedPointer(const clang::Expr *expression) {
      expression = clean(expression);
      if (expression == nullptr) {
        return nullptr;
      }
      if (const auto *unary = llvm::dyn_cast<clang::UnaryOperator>(expression)) {
        return unary->getOpcode() == clang::UO_Deref ? unary->getSubExpr() : nullptr;
      }
      if (const auto *index = llvm::dyn_cast<clang::ArraySubscriptExpr>(expression)) {
        return index->getBase();
      }
      if (const auto *member = llvm::dyn_cast<clang::MemberExpr>(expression)) {
        if (!member->isArrow()) {
          return dereferencedPointer(member->getBase());
        }
        return llvm::isa<clang::CXXThisExpr>(clean(member->getBase())) ? nullptr : member->getBase();
      }

      return nullptr;
    }

    // A member call through a pointer acts on the pointee rather than on the pointer.
    bool throughPointer(const clang::Expr &object) {
      return object.getType()->isPointerType() && !llvm::isa<clang::CXXThisExpr>(clean(&object));
    }

    clang::QualType objectType(const clang::Expr &object) {
      return throughPointer(object) ? object.getType()->getPointeeType() : object.getType();
    }

    const clang::Expr *defaultOperand(const clang::Expr *expression) {
      if (const auto *argument = llvm::dyn_cast<clang::CXXDefaultArgExpr>(expression)) {
        return argument->getExpr();
      }
      if (const auto *initializer = llvm::dyn_cast<clang::CXXDefaultInitExpr>(expression)) {
        return initializer->getExpr();
      }
      return nullptr;
    }

    class function_analysis {
    public:
      function_analysis(const clang::FunctionDecl &function, clang::ASTContext &context, bool errors, llvm::DenseSet<std::uint64_t> &reported, inference_cache &cache)
          : function_(function),
            context_(context),
            errors_(errors),
            reported_(reported),
            cache_(cache) {
        const auto *method = llvm::dyn_cast<clang::CXXMethodDecl>(&function);
        if (method != nullptr && method->getParent()->isLambda()) {
          clang::FieldDecl *this_capture = nullptr;
          method->getParent()->getCaptureFields(captures_, this_capture);
          for (const auto &capture : method->getParent()->captures()) {
            if (capture.capturesVariable() && capture.getCaptureKind() == clang::LCK_ByRef) {
              captures_.erase(capture.getCapturedVar());
              by_reference_.insert(capture.getCapturedVar());
            }
          }
        }
      }

      function_summary run(const clang::CFG &cfg, bool diagnostics = false) {
        const auto *graph = &cfg;
        llvm::SmallVector<state, 16> inputs(graph->getNumBlockIDs());
        llvm::BitVector reached(graph->getNumBlockIDs());
        llvm::BitVector queued(graph->getNumBlockIDs());
        llvm::SmallVector<const clang::CFGBlock *, 16> work;
        const auto *entry = &graph->getEntry();
        inputs[entry->getBlockID()] = initialState();
        reached.set(entry->getBlockID());
        queued.set(entry->getBlockID());
        work.push_back(entry);

        while (!work.empty()) {
          const auto *block = work.pop_back_val();
          queued.reset(block->getBlockID());
          auto output = inputs[block->getBlockID()];
          transfer(*block, output);
          for (const auto &successor : block->succs()) {
            const auto *next = successor.getReachableBlock();
            if (next == nullptr) {
              continue;
            }

            const auto id = next->getBlockID();
            const bool changed = inputs[id].merge(output);
            if ((!reached[id] || changed) && !queued[id]) {
              queued.set(id);
              work.push_back(next);
            }
            reached.set(id);
          }
        }

        // Report only after the dataflow solution stabilizes, not during speculation.
        reporting_ = diagnostics;
        collecting_ = true;
        for (const auto *block : *graph) {
          if (reached[block->getBlockID()]) {
            auto current = inputs[block->getBlockID()];
            transfer(*block, current);
          }
        }
        const auto &exit = inputs[graph->getExit().getBlockID()];
        for (const auto *key : exit.written) {
          if (llvm::isa<clang::FieldDecl>(key) || callerVisible(key) || by_reference_.contains(key)) {
            summary_.writes[key] = exit.get(key);
            for (const auto &source : summary_.writes[key].values) {
              if (source.kind == origin_kind::local || source.kind == origin_kind::temporary) {
                report(issue::dangling, source.borrow_site.isValid() ? source.borrow_site : function_.getEndLoc(), &source);
              }
            }
          }
        }

        return std::move(summary_);
      }

    private:
      const clang::FunctionDecl &function_;
      clang::ASTContext &context_;
      bool errors_;
      llvm::DenseSet<std::uint64_t> &reported_;
      inference_cache &cache_;
      function_summary summary_;
      llvm::DenseMap<const clang::CallExpr *, loans> call_results_;
      llvm::DenseMap<const clang::ValueDecl *, clang::FieldDecl *> captures_;
      llvm::SmallPtrSet<const clang::ValueDecl *, 4> by_reference_;
      bool reporting_ = false;
      bool collecting_ = false;

      const clang::Stmt *fullExpression(const clang::Stmt *statement) const {
        auto node = clang::DynTypedNode::create(*statement);
        const clang::Stmt *last = statement;
        while (true) {
          const auto parents = context_.getParents(node);
          if (parents.empty()) {
            return last;
          }
          const auto &parent = parents[0];
          if (const auto *parent_statement = parent.get<clang::Stmt>()) {
            if (llvm::isa<clang::CompoundStmt>(parent_statement)) {
              return last;
            }
            if (!llvm::isa<clang::Expr>(parent_statement) && !llvm::isa<clang::DeclStmt>(parent_statement)) {
              return parent_statement;
            }
            last = parent_statement;
          } else if (parent.get<clang::VarDecl>() == nullptr) {
            return last;
          }
          node = parent;
        }
      }

      // A standard function, or a library function whose body is visible, follows the argument-shape model.
      [[nodiscard]] bool libraryFunction(const clang::FunctionDecl &callee) const {
        return standardDeclaration(callee) || (context_.getSourceManager().isInSystemHeader(callee.getLocation()) && callee.hasBody());
      }

      // A call or construction into code the project does not control.
      [[nodiscard]] bool foreign(const clang::Expr &expression) const {
        const clang::FunctionDecl *callee = nullptr;
        if (const auto *call = llvm::dyn_cast<clang::CallExpr>(&expression)) {
          callee = call->getDirectCallee();
        } else if (const auto *construction = llvm::dyn_cast<clang::CXXConstructExpr>(&expression)) {
          callee = construction->getConstructor();
        }
        return callee != nullptr && context_.getSourceManager().isInSystemHeader(callee->getLocation());
      }

      static std::string unsupportedName(const clang::Expr *expression) {
        if (const auto *call = llvm::dyn_cast_or_null<clang::CallExpr>(expression)) {
          const auto *callee = call->getDirectCallee();
          return callee == nullptr ? "an indirect call" : callee->getQualifiedNameAsString();
        }
        if (const auto *construction = llvm::dyn_cast_or_null<clang::CXXConstructExpr>(expression)) {
          return "the constructor of " + construction->getType().getAsString();
        }
        return expression == nullptr ? "an unsupported expression" : std::string("an unsupported ") + expression->getStmtClassName();
      }

      void report(issue kind, clang::SourceLocation location, const origin *source = nullptr, const clang::Stmt *use = nullptr) {
        if (!reporting_ || location.isInvalid()) {
          return;
        }
        location = context_.getSourceManager().getExpansionLoc(location);
        const auto key = (static_cast<std::uint64_t>(location.getRawEncoding()) << 8U) | static_cast<std::uint8_t>(kind);
        if (!reported_.insert(key).second) {
          return;
        }

        auto &diagnostics = context_.getDiagnostics();
        const auto severity = errors_ ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning;
        unsigned id = 0;
        switch (kind) {
        case issue::dangling:
          id = diagnostics.getCustomDiagID(severity, "borrow can outlive its referent [tbc-dangling-borrow]");
          break;
        case issue::invalidated:
          id = diagnostics.getCustomDiagID(severity, "operation invalidates a borrow used later [tbc-invalidated-borrow]");
          break;
        case issue::contract:
          id = diagnostics.getCustomDiagID(severity, "borrow origin does not satisfy the declared region [tbc-contract-violation]");
          break;
        case issue::ambiguous:
          id = diagnostics.getCustomDiagID(severity, "borrowed result has no unambiguous input region [tbc-ambiguous-lifetime]");
          break;
        case issue::missing:
          id = diagnostics.getCustomDiagID(severity, "borrow-sensitive call to %0 has no supported lifetime summary [tbc-missing-contract]");
          break;
        }
        {
          auto diagnostic = diagnostics.Report(location, id);
          if (kind == issue::missing) {
            diagnostic << unsupportedName(source == nullptr ? nullptr : source->expression);
          }
        }
        if (source != nullptr) {
          clang::SourceLocation note;
          if (source->variable != nullptr) {
            note = source->variable->getLocation();
          } else if (source->expression != nullptr) {
            note = source->expression->getBeginLoc();
          }
          if (note.isValid() && note != location) {
            const auto note_id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Note, "borrowed storage originates here");
            diagnostics.Report(note, note_id);
          }
        }
        if (use != nullptr) {
          const auto note_id = diagnostics.getCustomDiagID(clang::DiagnosticsEngine::Note, "invalidated borrow is used here");
          diagnostics.Report(use->getBeginLoc(), note_id);
        }
      }

      [[nodiscard]] state initialState() const {
        state initial;
        for (const auto *parameter : function_.parameters()) {
          const auto type = parameter->getType();
          if (containsViews(type.getNonReferenceType())) {
            initial.values[parameter].add({.kind = origin_kind::parameter, .variable = parameter});
          }
          if (type->isReferenceType()) {
            initial.references[parameter].add({.kind = origin_kind::parameter_storage, .storage = storage_kind::object, .variable = parameter});
          }
        }
        if (const auto *method = llvm::dyn_cast<clang::CXXMethodDecl>(&function_)) {
          for (const auto *field : method->getParent()->fields()) {
            if (containsViews(field->getType())) {
              const auto annotation = viewAnnotation(field->getType(), context_);
              initial.values[field].add({.kind = origin_kind::receiver_region, .storage = field->getType()->isReferenceType() ? storage_kind::object : storage_kind::inherited, .variable = field, .region = annotation.region});
            }
          }
        }
        for (const auto *variable : by_reference_) {
          if (containsViews(variable->getType().getNonReferenceType())) {
            initial.values[variable].add({.kind = origin_kind::captured_contents, .variable = variable});
          }
          if (variable->getType()->isReferenceType()) {
            initial.references[variable].add({.kind = origin_kind::captured_storage, .storage = storage_kind::object, .variable = variable});
          }
        }

        return initial;
      }

      [[nodiscard]] loans capturedStorage(const clang::ValueDecl &variable, const state &current) const {
        const auto *local = llvm::dyn_cast<clang::VarDecl>(&variable);
        return local != nullptr && local->getType()->isReferenceType() ? current.getReference(&variable) : localStorage(&variable);
      }

      // The variable an expression moves from, as in std::move(owner).
      [[nodiscard]] const clang::ValueDecl *movedFrom(const clang::Expr *expression) const {
        expression = clean(expression);
        if (const auto *temporary = llvm::dyn_cast_or_null<clang::MaterializeTemporaryExpr>(expression)) {
          return movedFrom(temporary->getSubExpr());
        }
        if (const auto *construction = llvm::dyn_cast_or_null<clang::CXXConstructExpr>(expression)) {
          const bool moves = construction->getConstructor()->isMoveConstructor() && construction->getNumArgs() != 0;
          return moves ? movedFrom(construction->getArg(0)) : nullptr;
        }
        const auto *call = llvm::dyn_cast_or_null<clang::CallExpr>(expression);
        const auto *callee = call == nullptr ? nullptr : call->getDirectCallee();
        if (callee != nullptr && call->getNumArgs() == 1 && callee->getQualifiedNameAsString() == "std::move") {
          return place(call->getArg(0));
        }
        return nullptr;
      }

      // After a move, borrows of the source's allocation belong to the destination, at the given level below it.
      // A container keeps a moved element's allocation below its element slots, across its own reallocations.
      void transferOwnership(const clang::ValueDecl *from, llvm::ArrayRef<const clang::ValueDecl *> destinations, storage_kind level, state &current) {
        if (from == nullptr) {
          return;
        }
        loans owners;
        for (const auto *destination : destinations) {
          if (destination != from) {
            owners.merge(capturedStorage(*destination, current));
          }
        }
        if (owners.values.empty()) {
          return;
        }
        for (auto *map : {&current.values, &current.references}) {
          for (auto &entry : *map) {
            loans kept;
            bool moved = false;
            for (const auto &source : entry.second.values) {
              if (source.variable != from || source.storage < storage_kind::data || source.invalidated != nullptr) {
                kept.add(source);
                continue;
              }
              moved = true;
              for (auto owner : owners.values) {
                const auto slot = below(owner.storage, depth(level));
                appendMoved(owner.path, source.path, storage_kind::data, slot);
                owner.storage = below(slot, depth(source.storage) - depth(storage_kind::data));
                markBorrowSite(owner, source.borrow_site);
                kept.add(owner);
              }
            }
            if (moved) {
              entry.second = std::move(kept);
            }
          }
        }
      }

      // A swap exchanges two owners' allocations without moving the elements inside them.
      void exchangeOwnership(const clang::ValueDecl *left, const clang::ValueDecl *right, state &current) {
        if (left == nullptr || right == nullptr || left == right) {
          return;
        }
        const auto left_owner = capturedStorage(*left, current);
        const auto right_owner = capturedStorage(*right, current);
        for (auto *map : {&current.values, &current.references}) {
          for (auto &entry : *map) {
            loans exchanged;
            for (const auto &source : entry.second.values) {
              const bool data = source.storage >= storage_kind::data && source.invalidated == nullptr;
              const loans *owners = nullptr;
              if (data && source.variable == left) {
                owners = &right_owner;
              } else if (data && source.variable == right) {
                owners = &left_owner;
              }
              if (owners == nullptr) {
                exchanged.add(source);
                continue;
              }
              for (auto owner : owners->values) {
                appendMoved(owner.path, source.path, storage_kind::data, deepen(owner.storage));
                owner.storage = below(owner.storage, depth(source.storage));
                markBorrowSite(owner, source.borrow_site);
                exchanged.add(owner);
              }
            }
            entry.second = std::move(exchanged);
          }
        }
      }

      // A by-value parameter is the callee's own copy; only writes through references, pointers, and iterators reach the caller.
      static bool callerVisible(const clang::ValueDecl *variable) {
        const auto *parameter = llvm::dyn_cast<clang::ParmVarDecl>(variable);
        return parameter != nullptr && (parameter->getType()->isReferenceType() || pointerLike(parameter->getType()));
      }

      // A by-reference capture is the caller's own variable when the enclosing function calls the lambda.
      [[nodiscard]] bool visibleVariable(const clang::ValueDecl *variable) const {
        return by_reference_.contains(variable) || variable->getDeclContext() == &function_;
      }

      loans readPlace(const clang::ValueDecl *key, const state &current) const {
        const auto *variable = llvm::dyn_cast_or_null<clang::VarDecl>(key);
        if (variable == nullptr || !variable->getType()->isReferenceType()) {
          return current.get(key);
        }
        loans result;
        for (const auto &binding : current.getReference(key).values) {
          result.merge(binding.variable == nullptr ? current.get(key) : selected(current.get(binding.variable), inlineFields(binding.path)));
        }
        return result;
      }

      // Variables a pointer can designate; an untracked pointee keeps the pointer's own place.
      llvm::SmallVector<const clang::ValueDecl *, 2> pointees(const clang::Expr *pointer, const state &current) {
        llvm::SmallVector<const clang::ValueDecl *, 2> result;
        for (const auto &source : value(pointer, current).values) {
          if (source.variable == nullptr) {
            return targets(pointer, current);
          }
          if (std::ranges::find(result, source.variable) == result.end()) {
            result.push_back(source.variable);
          }
        }
        return result.empty() ? targets(pointer, current) : result;
      }

      // Inside a lambda, a captured variable is the closure field that holds or refers to it.
      [[nodiscard]] const clang::FieldDecl *captured(const clang::ValueDecl *variable) const {
        const auto found = captures_.find(variable);
        return found == captures_.end() ? nullptr : found->second;
      }

      // Where an operation on an object lands: each place that can hold it.
      llvm::SmallVector<object_place, 2> invalidationTargets(const clang::Expr &object, const state &current) {
        llvm::SmallVector<object_place, 2> result;
        for (const auto &source : objectReference(object, current).values) {
          if (source.variable == nullptr) {
            result.clear();
            break;
          }
          result.push_back({.variable = source.variable, .level = source.storage, .path = source.path});
        }
        if (!result.empty()) {
          return result;
        }
        for (const auto *target : targets(&object, current)) {
          result.push_back({.variable = target});
        }
        return result;
      }

      // A write to an object lands in each variable that can hold it, at the fields that lead to it there.
      struct write_target {
        const clang::ValueDecl *variable = nullptr;
        field_path fields{};
      };

      struct write_targets {
        llvm::SmallVector<write_target, 2> places;
        // The write replaces what the object held only when the object has one place, inline in its
        // variable, and every field on the way to it is known.
        bool replaces = false;
      };

      static bool exactPlace(const origin &source) {
        const bool place = source.kind == origin_kind::local || source.kind == origin_kind::static_storage || source.kind == origin_kind::receiver || source.kind == origin_kind::parameter_storage || source.kind == origin_kind::captured_storage;
        const bool known = std::ranges::none_of(source.path, [](const projection &step) { return step.field == nullptr; }) && source.path.size() < std::to_underlying(path_bound::steps);
        return place && known && source.storage == storage_kind::object;
      }

      // Without a place for the object, the write lands anywhere in the variables that can hold it.
      static write_targets writeTargets(const loans &places, llvm::ArrayRef<const clang::ValueDecl *> fallback) {
        write_targets result;
        bool exact = true;
        for (const auto &source : places.values) {
          if (source.variable == nullptr) {
            result.places.clear();
            break;
          }
          auto fields = exactPlace(source) || source.storage > storage_kind::object ? inlineFields(source.path) : field_path{};
          exact = exact && exactPlace(source) && fields.size() <= std::to_underlying(path_bound::held);
          fields.truncate(std::min<std::size_t>(fields.size(), std::to_underlying(path_bound::held)));
          write_target target{.variable = source.variable, .fields = std::move(fields)};
          const auto same = [&](const write_target &other) { return other.variable == target.variable && other.fields == target.fields; };
          if (std::ranges::none_of(result.places, same)) {
            result.places.push_back(std::move(target));
          }
        }
        if (result.places.empty()) {
          for (const auto *variable : fallback) {
            result.places.push_back({.variable = variable});
          }
          return result;
        }

        result.replaces = exact && result.places.size() == 1;
        return result;
      }

      void store(const write_targets &where, const loans &incoming, state &current) {
        for (const auto &target : where.places) {
          auto &contents = current.values[target.variable];
          if (where.replaces) {
            replaceHeld(contents, target.variable->getType(), target.fields, incoming);
          } else {
            contents.merge(heldAt(incoming, target.fields));
          }
          current.written.insert(target.variable);
        }
      }

      llvm::SmallVector<const clang::ValueDecl *, 2> objectTargets(const clang::Expr &object, const state &current) {
        return throughPointer(object) ? pointees(&object, current) : targets(&object, current);
      }

      llvm::SmallVector<const clang::ValueDecl *, 2> targets(const clang::Expr *expression, const state &current) {
        if (const auto *pointer = dereferencedPointer(expression)) {
          return pointees(pointer, current);
        }
        llvm::SmallVector<const clang::ValueDecl *, 2> result;
        const auto *key = place(expression);
        if (key == nullptr) {
          return result;
        }
        if (const auto *field = captured(key)) {
          result.push_back(field);
          return result;
        }
        const auto *variable = llvm::dyn_cast<clang::VarDecl>(key);
        if (variable != nullptr && variable->getType()->isReferenceType()) {
          for (const auto &binding : current.getReference(key).values) {
            if (binding.variable != nullptr && std::ranges::find(result, binding.variable) == result.end()) {
              result.push_back(binding.variable);
            }
          }
        }
        if (result.empty()) {
          result.push_back(key);
        }

        return result;
      }

      loans localStorage(const clang::ValueDecl *variable) const {
        loans result;
        if (by_reference_.contains(variable)) {
          result.add({.kind = origin_kind::captured_storage, .storage = storage_kind::object, .variable = variable});
          return result;
        }
        if (const auto *local = llvm::dyn_cast_or_null<clang::VarDecl>(variable)) {
          if (local->hasLocalStorage()) {
            result.add({.kind = origin_kind::local, .storage = storage_kind::object, .variable = variable});
          } else {
            result.add({.kind = origin_kind::static_storage, .storage = storage_kind::object, .variable = variable});
          }
        } else if (variable != nullptr) {
          result.add({.kind = origin_kind::receiver, .storage = storage_kind::object, .variable = variable});
        }

        return result;
      }

      [[nodiscard]] loans anchorDefault(loans result, const clang::Expr &wrapper) const {
        for (auto &source : result.values) {
          if (source.kind == origin_kind::temporary) {
            source.full_expression = fullExpression(&wrapper);
          }
        }
        return result;
      }

      loans reference(const clang::Expr *expression, const state &current) {
        expression = clean(expression);
        if (expression == nullptr) {
          return {};
        }
        if (const auto *operand = defaultOperand(expression)) {
          return anchorDefault(reference(operand, current), *expression);
        }
        if (const auto *temporary = llvm::dyn_cast<clang::MaterializeTemporaryExpr>(expression)) {
          return temporaryStorage(*temporary);
        }
        if (llvm::isa<clang::CXXThisExpr>(expression)) {
          loans result;
          result.add({.kind = origin_kind::receiver, .storage = storage_kind::object});
          return result;
        }
        if (const auto *ref = llvm::dyn_cast<clang::DeclRefExpr>(expression)) {
          if (const auto *field = captured(ref->getDecl())) {
            return field->getType()->isReferenceType() ? current.get(field) : localStorage(field);
          }
          const auto *variable = llvm::dyn_cast<clang::VarDecl>(ref->getDecl());
          if (variable != nullptr && variable->getType()->isReferenceType()) {
            return current.getReference(variable);
          }

          return localStorage(ref->getDecl());
        }
        if (const auto *member = llvm::dyn_cast<clang::MemberExpr>(expression)) {
          if (const auto *field = llvm::dyn_cast<clang::FieldDecl>(member->getMemberDecl())) {
            return field->getType()->isReferenceType() ? value(member, current) : fieldPlace(*member, *field, current);
          }
          if (const auto *pointer = dereferencedPointer(member)) {
            return value(pointer, current);
          }
          if (const auto *root = place(member)) {
            const auto *variable = llvm::dyn_cast<clang::VarDecl>(root);
            return variable != nullptr && variable->getType()->isReferenceType() ? current.getReference(root) : localStorage(root);
          }
        }
        if (const auto *pointer = dereferencedPointer(expression)) {
          return value(pointer, current);
        }
        if (const auto *operation = llvm::dyn_cast<clang::CXXOperatorCallExpr>(expression)) {
          if (operation->getOperator() == clang::OO_Subscript && operation->getNumArgs() != 0) {
            return storage(operation->getArg(0), current);
          }
        }

        if (const auto *call = llvm::dyn_cast<clang::CallExpr>(expression)) {
          const auto *callee = call->getDirectCallee();
          if (callee != nullptr && (callee->getQualifiedNameAsString() == "std::move" || callee->getQualifiedNameAsString() == "std::forward")) {
            return reference(call->getArg(0), current);
          }
          return callResult(*call, current);
        }
        if (const auto *conditional = llvm::dyn_cast<clang::ConditionalOperator>(expression)) {
          auto result = reference(conditional->getTrueExpr(), current);
          result.merge(reference(conditional->getFalseExpr(), current));
          return result;
        }

        return storage(expression, current);
      }

      [[nodiscard]] loans temporaryStorage(const clang::MaterializeTemporaryExpr &temporary) const {
        if (const auto *extended = temporary.getExtendingDecl()) {
          // A temporary extended alongside a declaration, like an initializer list's array, is a separate object.
          if (!sameType(extended->getType(), temporary.getType())) {
            loans result;
            result.add({.kind = origin_kind::local, .storage = storage_kind::object, .variable = extended, .expression = &temporary});
            return result;
          }
          return localStorage(extended);
        }
        loans result;
        result.add({.kind = origin_kind::temporary, .storage = storage_kind::object, .expression = &temporary, .full_expression = fullExpression(&temporary)});
        return result;
      }

      // A field lies inside the object it is selected from, at that object's level. The receiver's fields
      // are variables of their own, and the members of a union share one place.
      static void project(origin &source, const clang::FieldDecl &field) {
        if (source.kind == origin_kind::receiver && source.variable == nullptr && source.storage <= storage_kind::object && !field.getParent()->isUnion()) {
          source.variable = &field;
          return;
        }
        if (source.variable != nullptr) {
          appendField(source.path, field, std::max(source.storage, storage_kind::object));
        }
      }

      // A receiver field's place, relative to the receiver object.
      static object_place receiverPlace(const object_place &target) {
        object_place result{.level = target.level};
        appendField(result.path, *llvm::cast<clang::FieldDecl>(target.variable), storage_kind::object);
        appendMoved(result.path, target.path, storage_kind::object, storage_kind::object);
        return result;
      }

      // The place a callee's place denotes inside an object an actual borrow designates. A field of the
      // caller's own receiver is a variable of its own.
      static std::optional<object_place> placeWithin(origin actual, const object_place &symbolic) {
        auto steps = symbolic.path;
        if (actual.variable == nullptr && !steps.empty() && depth(steps.front().level) == 0 && steps.front().field != nullptr) {
          project(actual, *steps.front().field);
          steps.erase(steps.begin());
        }
        if (actual.variable == nullptr) {
          return std::nullopt;
        }
        return rebased({.variable = actual.variable, .level = actual.storage, .path = actual.path}, {.level = symbolic.level, .path = steps});
      }

      // Inside a lambda, `this` is the object the closure captured. A field of the closure is its own.
      static bool capturedReceiver(const clang::FunctionDecl &callee, const clang::ValueDecl *field) {
        const auto *method = llvm::dyn_cast<clang::CXXMethodDecl>(&callee);
        return method != nullptr && method->getParent()->isLambda() && (field == nullptr || llvm::cast<clang::FieldDecl>(field)->getParent() != method->getParent());
      }

      // What a closure's captured `this` designates: the captured pointer's object, or the copy of `*this`
      // the closure holds.
      loans capturedThis(const clang::FunctionDecl &callee, const clang::Expr &object, const state &current) {
        llvm::DenseMap<const clang::ValueDecl *, clang::FieldDecl *> fields;
        clang::FieldDecl *this_field = nullptr;
        llvm::cast<clang::CXXMethodDecl>(callee).getParent()->getCaptureFields(fields, this_field);
        if (this_field == nullptr) {
          return {};
        }
        if (!this_field->getType()->isPointerType()) {
          auto result = objectReference(object, current);
          for (auto &source : result.values) {
            project(source, *this_field);
          }
          return result;
        }
        return selected(receiverContents(object, current), *this_field);
      }

      loans fieldPlace(const clang::MemberExpr &member, const clang::FieldDecl &field, const state &current) {
        const auto *base = clean(member.getBase());
        if (llvm::isa<clang::CXXThisExpr>(base)) {
          return localStorage(&field);
        }
        auto result = member.isArrow() ? value(base, current) : reference(base, current);
        for (auto &source : result.values) {
          project(source, field);
        }
        return result;
      }

      // What a field holds is what its object holds at that field.
      loans fieldContents(const clang::MemberExpr &member, const clang::FieldDecl &field, const state &current) {
        const auto *base = clean(member.getBase());
        if (llvm::isa<clang::CXXThisExpr>(base)) {
          return readPlace(&field, current);
        }
        return selected(member.isArrow() ? pointeeContents(member, base, true, current) : value(base, current), field);
      }

      // Each initializer of an aggregate's fields holds its contents at that field.
      loans aggregateContents(const clang::InitListExpr &list, const state &current) {
        const auto *initializer = list.isSyntacticForm() && list.getSemanticForm() != nullptr ? list.getSemanticForm() : &list;
        const auto *record = recordOf(initializer->getType());
        llvm::SmallVector<const clang::FieldDecl *, 8> fields;
        if (record != nullptr && !record->isUnion() && record->getNumBases() == 0) {
          for (const auto *field : record->fields()) {
            if (!field->isUnnamedBitField()) {
              fields.push_back(field);
            }
          }
        }
        const bool positioned = fields.size() == initializer->getNumInits();
        loans result;
        for (unsigned index = 0; index < initializer->getNumInits(); ++index) {
          auto contents = value(initializer->getInit(index), current);
          if (positioned) {
            field_path at;
            appendField(at, *fields[index], storage_kind::object);
            contents = heldAt(contents, at);
          }
          result.merge(contents);
        }
        return positioned ? result : unplaced(result);
      }

      // The storage an object owns lies one level below the object's place.
      static loans ownedBy(loans places) {
        for (auto &source : places.values) {
          source.storage = deepen(source.storage);
        }
        return places;
      }

      // What an expression lends of its own: an object lends the storage it owns, while a view or a
      // pointer lends what it designates.
      loans storage(const clang::Expr *expression, const state &current) {
        expression = clean(expression);
        if (expression == nullptr) {
          return {};
        }
        if (const auto *operand = defaultOperand(expression)) {
          return anchorDefault(storage(operand, current), *expression);
        }
        if (llvm::isa<clang::StringLiteral>(expression) || llvm::isa<clang::CXXNullPtrLiteralExpr>(expression)) {
          return {};
        }
        const bool designates = viewType(expression->getType()) || expression->getType()->isPointerType();
        if (const auto *temporary = llvm::dyn_cast<clang::MaterializeTemporaryExpr>(expression)) {
          return viewType(temporary->getType()) ? value(temporary->getSubExpr(), current) : ownedBy(temporaryStorage(*temporary));
        }
        if (const auto *ref = llvm::dyn_cast<clang::DeclRefExpr>(expression)) {
          if (const auto *field = captured(ref->getDecl())) {
            if (designates) {
              return current.get(field);
            }
            return ownedBy(field->getType()->isReferenceType() ? current.get(field) : localStorage(field));
          }
          const auto *variable = llvm::dyn_cast<clang::VarDecl>(ref->getDecl());
          if (variable != nullptr && (viewType(variable->getType()) || variable->getType().getNonReferenceType()->isPointerType())) {
            return readPlace(variable, current);
          }
          if (variable != nullptr && variable->getType()->isReferenceType()) {
            return ownedBy(current.getReference(variable));
          }

          return ownedBy(localStorage(ref->getDecl()));
        }
        if (const auto *member = llvm::dyn_cast<clang::MemberExpr>(expression)) {
          const auto *field = llvm::dyn_cast<clang::FieldDecl>(member->getMemberDecl());
          if (designates) {
            return value(member, current);
          }
          if (field != nullptr) {
            return ownedBy(reference(member, current));
          }
          if (const auto *pointer = dereferencedPointer(member)) {
            return ownedBy(value(pointer, current));
          }
          if (const auto *root = place(member)) {
            const auto *variable = llvm::dyn_cast<clang::VarDecl>(root);
            return ownedBy(variable != nullptr && variable->getType()->isReferenceType() ? current.getReference(root) : localStorage(root));
          }
        }
        if (const auto *pointer = dereferencedPointer(expression)) {
          return designates ? value(expression, current) : ownedBy(value(pointer, current));
        }
        if (llvm::isa<clang::CXXThisExpr>(expression)) {
          loans result;
          result.add({.kind = origin_kind::receiver, .storage = storage_kind::object});
          return result;
        }
        if (const auto *call = llvm::dyn_cast<clang::CallExpr>(expression)) {
          const auto *callee = call->getDirectCallee();
          if (callee != nullptr && (callee->getQualifiedNameAsString() == "std::move" || callee->getQualifiedNameAsString() == "std::forward")) {
            return storage(call->getArg(0), current);
          }
          // A pointer or view lends what it designates, even when a call returns a reference to it.
          if (designates) {
            return value(call, current);
          }
          return call->isGLValue() ? ownedBy(callResult(*call, current)) : callResult(*call, current);
        }

        return value(expression, current);
      }

      bool receiverHasRegion(const clang::FunctionDecl &callee, const clang::Type *region) const {
        const auto *method = llvm::dyn_cast<clang::CXXMethodDecl>(&callee);
        if (method == nullptr) {
          return false;
        }
        for (const auto *field : method->getParent()->fields()) {
          if (viewAnnotation(field->getType(), context_).region == region && containsViews(field->getType())) {
            return true;
          }
        }

        return false;
      }

      [[nodiscard]] const clang::Expr *receiver(const clang::CallExpr &call) const {
        if (const auto *member = llvm::dyn_cast<clang::CXXMemberCallExpr>(&call)) {
          return member->getImplicitObjectArgument();
        }
        if (const auto *operation = llvm::dyn_cast<clang::CXXOperatorCallExpr>(&call)) {
          const auto *method = llvm::dyn_cast_or_null<clang::CXXMethodDecl>(call.getDirectCallee());
          if (method != nullptr && operation->getNumArgs() != 0) {
            return operation->getArg(0);
          }
        }

        return nullptr;
      }

      [[nodiscard]] unsigned argumentOffset(const clang::CallExpr &call) const {
        return llvm::isa<clang::CXXOperatorCallExpr>(call) && llvm::isa_and_nonnull<clang::CXXMethodDecl>(call.getDirectCallee()) ? 1U : 0U;
      }

      [[nodiscard]] bool outputParameter(const clang::ParmVarDecl &parameter) const {
        const auto type = parameter.getType();
        return parameterAnnotation(parameter, context_).present && type->isReferenceType() && !type.getNonReferenceType().isConstQualified() && containsViews(type.getNonReferenceType()) && !viewType(type);
      }

      function_entry *knownDeclaration(const clang::FunctionDecl *callee) {
        if (callee == nullptr) {
          return nullptr;
        }
        const auto found = cache_.functions.find(callee->getCanonicalDecl());
        if (found == cache_.functions.end()) {
          return nullptr;
        }
        found->second->dependents.insert(function_.getCanonicalDecl());
        return found->second.get();
      }

      function_entry *knownFunction(const clang::CallExpr &call) {
        return knownDeclaration(call.getDirectCallee());
      }

      // A summary's borrow lies at its symbolic place inside the actual borrow that replaces its input,
      // and is held where the symbolic borrow was, at the actual borrow's own position below it.
      static void locate(origin &borrow, const origin &symbolic) {
        field_path position;
        for (const auto &step : symbolic.held) {
          appendStep(position, step, path_bound::held);
        }
        for (const auto &step : borrow.held) {
          appendStep(position, step, path_bound::held);
        }
        borrow.held = std::move(position);
        const auto *field = llvm::dyn_cast_or_null<clang::FieldDecl>(symbolic.variable);
        if (field != nullptr && symbolic.kind == origin_kind::receiver) {
          project(borrow, *field);
        }
        // A borrow of no variable, like an unknown result, is never invalidated by its place.
        if (borrow.variable == nullptr) {
          return;
        }
        appendMoved(borrow.path, symbolic.path, storage_kind::object, borrow.storage);
        borrow.storage = relocate(borrow.storage, symbolic.storage);
      }

      static bool parameterOrigin(const origin &source) {
        return source.kind == origin_kind::parameter || source.kind == origin_kind::parameter_storage || source.kind == origin_kind::parameter_pointee;
      }

      // Substitutes one argument for a summary's symbolic parameter origin.
      loans argumentLoans(const origin &source, const clang::Expr &argument, const state &current) {
        if (source.kind == origin_kind::parameter) {
          return value(&argument, current);
        }
        if (source.kind == origin_kind::parameter_storage) {
          return reference(&argument, current);
        }
        return referencedContents(value(&argument, current), current);
      }

      loans constructionResult(const clang::CXXConstructExpr &construction, const state &current) {
        const auto *constructor = construction.getConstructor();
        const auto *known = knownDeclaration(constructor);
        loans result;
        for (const auto &base : constructor->getParent()->bases()) {
          if (containsViews(base.getType())) {
            result.add({.kind = origin_kind::unknown, .expression = &construction});
            return result;
          }
        }
        if (known == nullptr) {
          result.add({.kind = origin_kind::unknown, .expression = &construction});
          return result;
        }
        for (const auto &write : known->summary.writes) {
          // What a constructor writes to one of its fields is held at that field of the new object.
          field_path at;
          if (const auto *field = llvm::dyn_cast<clang::FieldDecl>(write.first)) {
            appendField(at, *field, storage_kind::object);
          }
          loans written;
          for (const auto &source : write.second.values) {
            loans actual;
            if (parameterOrigin(source)) {
              const auto index = llvm::cast<clang::ParmVarDecl>(source.variable)->getFunctionScopeIndex();
              if (index < construction.getNumArgs()) {
                actual = argumentLoans(source, *construction.getArg(index), current);
              }
            } else if (source.kind == origin_kind::static_storage || source.kind == origin_kind::environment) {
              written.add(source);
              continue;
            } else {
              actual.add({.kind = origin_kind::unknown, .expression = &construction});
            }
            if (!source.select.empty()) {
              actual = selected(actual, source.select);
            }
            for (auto &borrow : actual.values) {
              locate(borrow, source);
            }
            written.merge(actual);
          }
          result.merge(heldAt(written, at));
        }
        return result;
      }

      loans instantiate(const loans &symbolic, const clang::CallExpr &call, const state &current) {
        loans result;
        const auto offset = argumentOffset(call);
        for (const auto &source : symbolic.values) {
          loans actual;
          if (parameterOrigin(source)) {
            const auto *parameter = llvm::cast<clang::ParmVarDecl>(source.variable);
            const auto index = parameter->getFunctionScopeIndex() + offset;
            if (index >= call.getNumArgs()) {
              continue;
            }
            actual = argumentLoans(source, *call.getArg(index), current);
          } else if (source.kind == origin_kind::receiver_region) {
            const auto *object = receiver(call);
            if (object != nullptr) {
              actual = llvm::isa<clang::CXXThisExpr>(clean(object)) ? current.get(source.variable) : selected(receiverContents(*object, current), *llvm::cast<clang::FieldDecl>(source.variable));
            }
          } else if (source.kind == origin_kind::receiver) {
            if (const auto *object = receiver(call)) {
              actual = capturedReceiver(*call.getDirectCallee(), source.variable) ? capturedThis(*call.getDirectCallee(), *object, current) : objectReference(*object, current);
            }
          } else if (source.kind == origin_kind::captured_storage || source.kind == origin_kind::captured_contents) {
            const auto *object = receiver(call);
            if (visibleVariable(source.variable)) {
              actual = source.kind == origin_kind::captured_contents ? readPlace(source.variable, current) : capturedStorage(*source.variable, current);
            } else if (object != nullptr) {
              actual = receiverContents(*object, current);
            }
          } else if (source.kind == origin_kind::local || source.kind == origin_kind::temporary) {
            actual.add({.kind = origin_kind::unknown, .expression = &call});
          } else {
            // Static storage and the environment are the same places at every call.
            result.add(source);
            continue;
          }
          if (!source.select.empty()) {
            actual = selected(actual, source.select);
          }
          for (auto &borrow : actual.values) {
            locate(borrow, source);
            if (source.invalidated != nullptr) {
              borrow.invalidated = source.invalidated;
            }
          }
          result.merge(actual);
        }

        return result;
      }

      loans referencedContents(const loans &binding, const state &current) {
        loans result;
        for (const auto &source : binding.values) {
          // An extended temporary is identified by its expression; its variable only bounds its lifetime.
          const bool extended_temporary = source.kind == origin_kind::local && llvm::isa_and_nonnull<clang::MaterializeTemporaryExpr>(source.expression);
          if (source.kind == origin_kind::unknown) {
            result.add(source);
          } else if (source.kind == origin_kind::parameter && pointerLike(source.variable->getType())) {
            // A pointer parameter's value is its pointee's storage; the pointee's contents are a separate input.
            result.add({.kind = origin_kind::parameter_pointee, .variable = source.variable});
          } else if (source.variable != nullptr && !extended_temporary) {
            result.merge(selected(readPlace(source.variable, current), inlineFields(source.path)));
          } else if (source.expression != nullptr) {
            result.merge(value(source.expression, current));
          } else if (source.kind == origin_kind::receiver) {
            if (const auto *method = llvm::dyn_cast<clang::CXXMethodDecl>(&function_)) {
              for (const auto *field : method->getParent()->fields()) {
                result.merge(current.get(field));
              }
            }
          }
        }

        return result;
      }

      loans callResult(const clang::CallExpr &call, const state &current) {
        if (const auto cached = call_results_.find(&call); cached != call_results_.end()) {
          return cached->second;
        }
        const auto *callee = call.getDirectCallee();
        if (callee == nullptr) {
          loans result;
          if (containsViews(call.getType()) || call.isGLValue()) {
            result.add({.kind = origin_kind::unknown, .expression = &call});
          }
          return result;
        }
        if (!containsViews(call.getType()) && !callee->getReturnType()->isReferenceType()) {
          return {};
        }

        const auto *object = receiver(call);
        const auto name = callee->getNameAsString();
        if (name == "getenv" && context_.getSourceManager().isInSystemHeader(callee->getLocation())) {
          loans result;
          result.add({.kind = origin_kind::environment, .expression = &call});
          return result;
        }
        if (callee->getQualifiedNameAsString() == "std::move" || callee->getQualifiedNameAsString() == "std::forward") {
          return call.getNumArgs() == 0 ? loans{} : reference(call.getArg(0), current);
        }
        if (object != nullptr && libraryRecord(objectType(*object)) && !standardType(objectType(*object), "function")) {
          if (const auto modeled = standardMember(call, *callee, *object, current)) {
            return unplaced(*modeled);
          }
        }
        if (standardType(call.getType(), "basic_string") && !callee->getReturnType()->isReferenceType()) {
          return {};
        }
        if (object == nullptr && libraryFunction(*callee) && !callee->getReturnType()->isReferenceType()) {
          return unplaced(standardArguments(call, 0, current));
        }

        const auto result_annotation = returnAnnotation(*callee, context_);
        if (result_annotation.region == nullptr) {
          if (const auto *known = knownFunction(call)) {
            return instantiate(known->summary.returned, call, current);
          }
          if (callee->getReturnType()->isReferenceType() && context_.getSourceManager().isInSystemHeader(callee->getLocation()) && (object == nullptr || !standardType(objectType(*object), "function"))) {
            auto result = referenceArguments(call, current);
            if (object != nullptr) {
              result.merge(objectReference(*object, current));
            }
            return result;
          }
          if (!result_annotation.present) {
            loans result;
            result.add({.kind = origin_kind::unknown, .expression = &call});
            return result;
          }
        }
        const auto offset = argumentOffset(call);
        loans result;
        const clang::Type *selected_region = result_annotation.region;
        const clang::ParmVarDecl *elided = nullptr;
        bool ambiguous = false;
        for (unsigned index = 0; index < callee->getNumParams() && index + offset < call.getNumArgs(); ++index) {
          const auto *parameter = callee->getParamDecl(index);
          const auto annotation = parameterAnnotation(*parameter, context_);
          if (!annotation.present || outputParameter(*parameter)) {
            continue;
          }
          if (selected_region != nullptr) {
            if (annotation.region == selected_region) {
              result.merge(parameter->getType()->isReferenceType() ? reference(call.getArg(index + offset), current) : storage(call.getArg(index + offset), current));
            }
          } else if (object == nullptr) {
            if (elided != nullptr && (annotation.region == nullptr || annotation.region != parameterAnnotation(*elided, context_).region)) {
              ambiguous = true;
            }
            elided = parameter;
            result.merge(parameter->getType()->isReferenceType() ? reference(call.getArg(index + offset), current) : storage(call.getArg(index + offset), current));
          }
        }
        if (selected_region == nullptr && object != nullptr) {
          return objectStorage(*object, current);
        }
        if (ambiguous) {
          report(issue::ambiguous, call.getExprLoc());
        }
        // A receiver field with the result's region is another input that can supply it.
        if (selected_region != nullptr && object != nullptr && receiverHasRegion(*callee, selected_region)) {
          if (!hasMatchingParameter(*callee, selected_region)) {
            return receiverContents(*object, current);
          }
          result.merge(receiverContents(*object, current));
        }
        if (result.values.empty() && ((selected_region != nullptr && !hasMatchingParameter(*callee, selected_region)) || (selected_region == nullptr && elided == nullptr))) {
          result.add({.kind = origin_kind::unknown, .expression = &call});
        }

        return result;
      }

      // A view lends its referent, an iterator its pointee, and an owner its storage or a copy of its contents.
      std::optional<loans> standardMember(const clang::CallExpr &call, const clang::FunctionDecl &callee, const clang::Expr &object, const state &current) {
        const auto type = objectType(object);
        const bool reference_result = callee.getReturnType()->isReferenceType();
        const auto *record = recordOf(type);
        if (record != nullptr && record->getDefinition() != nullptr && record->getDefinition()->isEmpty()) {
          return reference_result ? referenceArguments(call, current) : standardArguments(call, argumentOffset(call), current);
        }
        if (reference_result && sameType(callee.getReturnType(), type)) {
          return objectReference(object, current);
        }
        if (viewType(type)) {
          const bool copy = !reference_result && containsViews(call.getType()) && callee.getNameAsString() != "data" && !llvm::isa<clang::CXXConversionDecl>(callee);
          return copy ? receiverContents(object, current) : objectStorage(object, current);
        }
        if (iteratorRecord(type)) {
          return receiverContents(object, current);
        }
        // Releasing transfers ownership, which remains an explicit boundary.
        if (callee.getNameAsString() == "release") {
          return std::nullopt;
        }
        const auto element = elementType(type);
        // A container returns its elements by value as copies, not as views of its storage.
        const bool element_copy = !reference_result && !element.isNull() && sameType(call.getType(), element);
        // An owner of views returns copies of them; an owner of plain data can only view its storage.
        const bool lends_storage = viewType(call.getType()) && (llvm::isa<clang::CXXConversionDecl>(callee) || !containsViews(type));
        // A smart pointer's object is one level below the place where the pointer itself lives.
        if (smartPointer(type) && (reference_result || pointsIntoStorage(call.getType()))) {
          return ownedBy(objectReference(object, current));
        }
        if (!element_copy && (reference_result || pointsIntoStorage(call.getType()) || lends_storage)) {
          // Outside the standard library, only a container is known to point into its own storage.
          if (!standardRecord(type) && element.isNull()) {
            return std::nullopt;
          }
          return objectStorage(object, current);
        }
        auto result = receiverContents(object, current);
        for (unsigned index = argumentOffset(call); index < call.getNumArgs(); ++index) {
          const auto argument = call.getArg(index)->getType();
          if (sameType(argument, call.getType()) || (!element.isNull() && sameType(argument, element))) {
            result.merge(copiedValue(call.getArg(index), current));
          }
        }
        return result;
      }

      // An opaque standard function's iterator or pointer comes from an argument of its type, a range
      // argument that yields it, or the address of an argument. Any other result copies its arguments.
      loans standardArguments(const clang::CallExpr &call, unsigned offset, const state &current) {
        loans result;
        if (!pointsIntoStorage(call.getType())) {
          for (unsigned index = offset; index < call.getNumArgs(); ++index) {
            result.merge(copiedValue(call.getArg(index), current));
          }
          return result;
        }
        bool matched = false;
        for (unsigned index = offset; index < call.getNumArgs(); ++index) {
          if (sameType(call.getArg(index)->getType(), call.getType())) {
            matched = true;
            result.merge(value(call.getArg(index), current));
          }
        }
        if (matched) {
          return result;
        }
        for (unsigned index = offset; index < call.getNumArgs(); ++index) {
          const auto *argument = call.getArg(index);
          if (pointerLike(argument->getType())) {
            result.merge(value(argument, current));
          } else if (call.getType()->isPointerType() && sameType(call.getType()->getPointeeType(), argument->getType())) {
            result.merge(reference(argument, current));
          } else if (yields(*argument, call.getType())) {
            result.merge(storage(argument, current));
          }
        }
        return result;
      }

      loans referenceArguments(const clang::CallExpr &call, const state &current) {
        loans result;
        const auto *callee = call.getDirectCallee();
        const auto offset = argumentOffset(call);
        for (unsigned index = 0; callee != nullptr && index < callee->getNumParams() && index + offset < call.getNumArgs(); ++index) {
          if (callee->getParamDecl(index)->getType()->isReferenceType()) {
            result.merge(reference(call.getArg(index + offset), current));
          }
        }
        return result;
      }

      // A container copies the elements of an initializer list rather than borrowing its backing array.
      loans copiedValue(const clang::Expr *argument, const state &current) {
        if (const auto *list = llvm::dyn_cast_or_null<clang::CXXStdInitializerListExpr>(clean(argument))) {
          return value(list->getSubExpr(), current);
        }
        if (const auto *temporary = llvm::dyn_cast_or_null<clang::MaterializeTemporaryExpr>(clean(argument))) {
          return copiedValue(temporary->getSubExpr(), current);
        }
        // An owner adopting a new-expression holds the new object's contents.
        if (const auto *allocation = llvm::dyn_cast_or_null<clang::CXXNewExpr>(clean(argument))) {
          return allocation->getInitializer() == nullptr ? loans{} : copiedValue(allocation->getInitializer(), current);
        }
        return value(argument, current);
      }

      // Reading through a pointer needs a live pointee and yields the pointee's contents.
      loans pointeeContents(const clang::Expr &use, const clang::Expr *pointer, bool borrowed, const state &current) {
        const auto pointee = value(pointer, current);
        checkUse(pointee, use);
        return borrowed ? referencedContents(pointee, current) : loans{};
      }

      loans objectReference(const clang::Expr &object, const state &current) {
        return throughPointer(object) ? value(&object, current) : reference(&object, current);
      }

      loans objectStorage(const clang::Expr &object, const state &current) {
        if (!throughPointer(object)) {
          return storage(&object, current);
        }
        if (viewType(objectType(object))) {
          return receiverContents(object, current);
        }
        return ownedBy(value(&object, current));
      }

      loans receiverContents(const clang::Expr &object, const state &current) {
        if (throughPointer(object)) {
          return referencedContents(value(&object, current), current);
        }
        if (!llvm::isa<clang::CXXThisExpr>(clean(&object))) {
          return value(&object, current);
        }
        loans result;
        if (const auto *method = llvm::dyn_cast<clang::CXXMethodDecl>(&function_)) {
          for (const auto *field : method->getParent()->fields()) {
            result.merge(current.get(field));
          }
        }
        return result;
      }

      bool hasMatchingParameter(const clang::FunctionDecl &callee, const clang::Type *region) const {
        for (const auto *parameter : callee.parameters()) {
          const auto annotation = parameterAnnotation(*parameter, context_);
          if (annotation.present && annotation.region == region && !outputParameter(*parameter)) {
            return true;
          }
        }

        return false;
      }

      loans value(const clang::Expr *expression, const state &current) {
        if (expression != nullptr && expression->getType()->isPointerType()) {
          const auto *unwrapped = clean(expression);
          if (unwrapped != nullptr && unwrapped->getType()->isArrayType()) {
            return storage(unwrapped, current);
          }
        }
        expression = clean(expression);
        if (expression == nullptr || expression->getType().isNull()) {
          return {};
        }
        if (const auto *operand = defaultOperand(expression)) {
          return anchorDefault(value(operand, current), *expression);
        }
        if (const auto *temporary = llvm::dyn_cast<clang::MaterializeTemporaryExpr>(expression)) {
          return value(temporary->getSubExpr(), current);
        }
        if (llvm::isa<clang::ImplicitValueInitExpr>(expression) || llvm::isa<clang::CXXScalarValueInitExpr>(expression)) {
          return {};
        }
        if (const auto *ref = llvm::dyn_cast<clang::DeclRefExpr>(expression)) {
          if (const auto *field = captured(ref->getDecl())) {
            return containsViews(expression->getType()) ? current.get(field) : loans{};
          }
          if (const auto *variable = llvm::dyn_cast<clang::VarDecl>(ref->getDecl())) {
            if (variable->getType()->isReferenceType()) {
              checkUse(current.getReference(variable), *expression);
            }
          }
          return containsViews(expression->getType()) ? readPlace(ref->getDecl(), current) : loans{};
        }
        if (const auto *member = llvm::dyn_cast<clang::MemberExpr>(expression)) {
          const auto *field = llvm::dyn_cast<clang::FieldDecl>(member->getMemberDecl());
          const bool borrowed = containsViews(member->getType()) || (field != nullptr && field->getType()->isReferenceType());
          if (field != nullptr && borrowed) {
            return fieldContents(*member, *field, current);
          }
          if (const auto *pointer = dereferencedPointer(member)) {
            return pointeeContents(*member, pointer, borrowed, current);
          }
          if (!borrowed) {
            return {};
          }
          if (const auto *root = place(member)) {
            checkUse(current.getReference(root), *member);
            return readPlace(root, current);
          }
          return value(member->getBase(), current);
        }
        if (const auto *construction = llvm::dyn_cast<clang::CXXConstructExpr>(expression)) {
          if (standardType(construction->getType(), "basic_string")) {
            return {};
          }
          loans result;
          if (viewType(construction->getType()) && construction->getNumArgs() != 0) {
            return storage(construction->getArg(0), current);
          }
          if (containsViews(construction->getType())) {
            if (!libraryRecord(construction->getType()) && !construction->getConstructor()->isCopyOrMoveConstructor() && !construction->getConstructor()->isDefaulted()) {
              return constructionResult(*construction, current);
            }
            const bool converting = standardRecord(construction->getType()) && !construction->getConstructor()->isCopyOrMoveConstructor();
            const auto element = elementType(construction->getType());
            for (unsigned index = 0; index < construction->getNumArgs(); ++index) {
              const auto *argument = construction->getArg(index);
              // A container built from an iterator range copies the elements the iterators designate.
              if (!element.isNull() && pointerLike(argument->getType()) && !sameType(element, argument->getType())) {
                result.merge(referencedContents(value(argument, current), current));
              } else {
                result.merge(copiedValue(argument, current));
              }
              if (converting && viewsInto(*construction, index)) {
                result.merge(storage(construction->getArg(index), current));
              }
            }
          }
          // A library object keeps what it takes in its own layout.
          return libraryRecord(construction->getType()) ? unplaced(result) : result;
        }
        if (const auto *call = llvm::dyn_cast<clang::CallExpr>(expression)) {
          const auto *callee = call->getDirectCallee();
          auto result = callResult(*call, current);
          if (callee != nullptr && callee->getReturnType()->isReferenceType()) {
            checkUse(result, *call);
            return containsViews(call->getType()) ? referencedContents(result, current) : loans{};
          }
          return result;
        }
        if (const auto *list = llvm::dyn_cast<clang::CXXStdInitializerListExpr>(expression)) {
          auto result = storage(list->getSubExpr(), current);
          result.merge(value(list->getSubExpr(), current));
          return result;
        }
        // A closure holds copies of its by-value captures and borrows its by-reference captures.
        if (const auto *lambda = llvm::dyn_cast<clang::LambdaExpr>(expression)) {
          llvm::DenseMap<const clang::ValueDecl *, clang::FieldDecl *> fields;
          clang::FieldDecl *this_field = nullptr;
          lambda->getLambdaClass()->getCaptureFields(fields, this_field);
          loans result;
          for (const auto [capture, initializer] : llvm::zip(lambda->captures(), lambda->capture_inits())) {
            if (initializer == nullptr) {
              continue;
            }
            loans captured_contents;
            if (capture.getCaptureKind() == clang::LCK_ByRef) {
              captured_contents.merge(reference(initializer, current));
            }
            captured_contents.merge(copiedValue(initializer, current));
            const auto *field = capture.capturesThis() ? this_field : fields.lookup(capture.capturesVariable() ? capture.getCapturedVar() : nullptr);
            field_path at;
            if (field != nullptr) {
              appendField(at, *field, storage_kind::object);
            }
            result.merge(field == nullptr ? unplaced(captured_contents) : heldAt(captured_contents, at));
          }
          return result;
        }
        if (const auto *initializer = llvm::dyn_cast<clang::InitListExpr>(expression)) {
          return aggregateContents(*initializer, current);
        }
        if (const auto *conditional = llvm::dyn_cast<clang::ConditionalOperator>(expression)) {
          auto result = value(conditional->getTrueExpr(), current);
          result.merge(value(conditional->getFalseExpr(), current));
          return result;
        }
        if (const auto *operation = llvm::dyn_cast<clang::BinaryOperator>(expression)) {
          if (operation->isAssignmentOp() || operation->getOpcode() == clang::BO_Comma) {
            return value(operation->getRHS(), current);
          }
          if (expression->getType()->isPointerType()) {
            auto result = value(operation->getLHS(), current);
            result.merge(value(operation->getRHS(), current));
            return result;
          }
        }
        if (const auto *pointer = dereferencedPointer(expression)) {
          return pointeeContents(*expression, pointer, containsViews(expression->getType()), current);
        }
        if (const auto *unary = llvm::dyn_cast<clang::UnaryOperator>(expression)) {
          return unary->getOpcode() == clang::UO_AddrOf ? reference(unary->getSubExpr(), current) : value(unary->getSubExpr(), current);
        }
        if (const auto *cast = llvm::dyn_cast<clang::ExplicitCastExpr>(expression)) {
          return value(cast->getSubExpr(), current);
        }
        if (llvm::isa<clang::CXXThisExpr>(expression)) {
          return reference(expression, current);
        }

        loans result;
        if (containsViews(expression->getType())) {
          result.add({.kind = origin_kind::unknown, .expression = expression});
        }
        return result;
      }

      void checkUse(const loans &borrow, const clang::Stmt &use) {
        for (const auto &source : borrow.values) {
          // What a caller passed in is used here, so a call to this function uses it. Handing on where a
          // parameter lies lets the receiver read all of it.
          if (source.variable != nullptr && (parameterOrigin(source) || source.kind == origin_kind::receiver_region)) {
            summary_.uses.insert(source.variable);
          }
          if (source.invalidated != nullptr) {
            report(issue::invalidated, source.invalidated->getEndLoc(), &source, &use);
          } else if (source.kind == origin_kind::temporary && source.full_expression != fullExpression(&use)) {
            report(issue::dangling, source.borrow_site.isValid() ? source.borrow_site : use.getBeginLoc(), &source);
          } else if (source.kind == origin_kind::unknown && !context_.getSourceManager().isInSystemMacro(source.expression->getExprLoc()) && !foreign(*source.expression)) {
            // The project can neither annotate nor rewrite an expression spelled by a system macro or code it does not control.
            report(issue::missing, source.expression->getExprLoc(), &source);
          }
        }
      }

      [[nodiscard]] bool allowed(const origin &source, annotation output) const {
        if (source.kind == origin_kind::receiver || source.kind == origin_kind::receiver_region) {
          if (output.region != nullptr) {
            return source.kind == origin_kind::receiver_region && source.region == output.region;
          }
          return llvm::isa<clang::CXXMethodDecl>(function_);
        }
        if (source.kind == origin_kind::static_storage || source.kind == origin_kind::environment) {
          return true;
        }
        if (!parameterOrigin(source)) {
          return false;
        }
        const auto *parameter = llvm::dyn_cast<clang::ParmVarDecl>(source.variable);
        if (parameter == nullptr) {
          return false;
        }
        const auto input = parameterAnnotation(*parameter, context_);
        if (output.region != nullptr) {
          return input.region == output.region && input.present;
        }
        if (llvm::isa<clang::CXXMethodDecl>(function_)) {
          return false;
        }
        const clang::ParmVarDecl *selected = nullptr;
        for (const auto *candidate : function_.parameters()) {
          const auto annotation = parameterAnnotation(*candidate, context_);
          if (!annotation.present) {
            continue;
          }
          if (selected != nullptr && (annotation.region == nullptr || annotation.region != parameterAnnotation(*selected, context_).region)) {
            return false;
          }
          selected = candidate;
        }

        return selected != nullptr && (selected == parameter || (input.region != nullptr && input.region == parameterAnnotation(*selected, context_).region));
      }

      void checkReturn(const clang::ReturnStmt &statement, const state &current) {
        const auto output = returnAnnotation(function_, context_);
        if (statement.getRetValue() == nullptr || (!output.present && !containsViews(function_.getReturnType()))) {
          return;
        }
        const auto result = function_.getReturnType()->isReferenceType() ? reference(statement.getRetValue(), current) : value(statement.getRetValue(), current);
        if (collecting_) {
          summary_.returned.merge(result);
        }
        checkUse(result, statement);
        for (const auto &source : result.values) {
          if (source.invalidated != nullptr || (source.kind == origin_kind::temporary && source.full_expression != fullExpression(&statement))) {
            continue;
          }
          if (source.kind == origin_kind::local || source.kind == origin_kind::temporary) {
            report(issue::dangling, statement.getReturnLoc(), &source);
          } else if (output.region != nullptr && source.kind != origin_kind::unknown && source.invalidated == nullptr && !allowed(source, output)) {
            report(issue::contract, statement.getReturnLoc(), &source);
          }
        }
      }

      // Invalidates the levels of a range below an object, which lies at a place inside its variable.
      void invalidate(const object_place &target, const clang::Stmt *trigger, state &current, bool destroyed = false, storage_range range = owned_storage) {
        const auto *owner = target.variable;
        if (owner == nullptr || trigger == nullptr) {
          return;
        }
        if (!destroyed && (llvm::isa<clang::ParmVarDecl>(owner) || llvm::isa<clang::FieldDecl>(owner) || by_reference_.contains(owner) || (llvm::isa<clang::VarDecl>(owner) && llvm::cast<clang::VarDecl>(owner)->hasGlobalStorage()))) {
          summary_.invalidate(target, range);
        }
        const auto levels = range.inside(target.level);
        const auto invalidate_map = [&](auto &map) {
          for (auto &entry : map) {
            for (auto &source : entry.second.values) {
              if (source.variable == owner && source.invalidated == nullptr && (destroyed || (levels.contains(source.storage) && within(source.path, target)))) {
                source.invalidated = trigger;
              }
            }
          }
        };
        invalidate_map(current.values);
        invalidate_map(current.references);
      }

      void invalidateEnvironment(const clang::CallExpr &call, state &current) {
        summary_.invalidates_environment = true;
        for (auto &entry : current.values) {
          for (auto &source : entry.second.values) {
            if (source.kind == origin_kind::environment && source.invalidated == nullptr) {
              source.invalidated = &call;
            }
          }
        }
      }

      // A library object's assignment, or a memberwise one, replaces what the object held without reading it.
      [[nodiscard]] bool overwrites(const clang::FunctionDecl &callee) const {
        const auto *method = llvm::dyn_cast<clang::CXXMethodDecl>(&callee);
        return method != nullptr && method->getOverloadedOperator() == clang::OO_Equal && (method->isDefaulted() || standardDeclaration(*method) || context_.getSourceManager().isInSystemHeader(method->getLocation()));
      }

      // A sequence container's structural operations move, copy, or destroy its elements without reading
      // what they borrow. An associative container compares its keys, so it reads them.
      static bool structural(const clang::FunctionDecl &callee, clang::QualType type) {
        if (!libraryRecord(type) || viewType(type) || iteratorRecord(type) || elementType(type).isNull() || declaresMember(type, "key_type")) {
          return false;
        }
        const auto name = callee.getNameAsString();
        for (const char *operation : {"size", "empty", "capacity", "max_size", "reserve", "shrink_to_fit", "clear", "resize", "reset", "has_value", "swap", "append", "prepend", "assign", "insert", "erase", "push_back", "push_front", "emplace", "emplace_back", "emplace_front", "pop_back", "pop_front"}) {
          if (name == operation) {
            return true;
          }
        }

        return false;
      }

      // What a receiver holds in the fields a callee uses.
      loans usedReceiverContents(const function_entry &callee, const clang::Expr &object, const state &current) {
        const bool own = llvm::isa<clang::CXXThisExpr>(clean(&object));
        const auto contents = own ? loans{} : receiverContents(object, current);
        loans result;
        for (const auto *input : callee.summary.uses) {
          const auto *field = llvm::dyn_cast<clang::FieldDecl>(input);
          if (field != nullptr) {
            result.merge(own ? current.get(field) : selected(contents, *field));
          }
        }
        return result;
      }

      static bool usesArgument(const function_entry &callee, unsigned index) {
        return index >= callee.definition->getNumParams() || callee.summary.uses.contains(callee.definition->getParamDecl(index));
      }

      void applyCall(const clang::CallExpr &call, state &current) {
        const auto *callee = call.getDirectCallee();
        if (callee == nullptr) {
          return;
        }
        // Summaries describe the result in terms of entry state, so read it before this call's writes.
        call_results_.erase(&call);
        auto result = callResult(call, current);
        call_results_[&call] = std::move(result);
        const auto *object = receiver(call);
        // An assigned object is overwritten rather than read: only the place it is written to must be live,
        // as for a container's structural operations.
        const bool overwritten = object != nullptr && overwrites(*callee);
        // A call to a function with a summary uses only the inputs that function uses; any other call
        // may use everything it is given.
        const auto *summarized = knownFunction(call);
        const auto *method = llvm::dyn_cast<clang::CXXMethodDecl>(callee);
        if (method != nullptr && method->getParent()->isLambda()) {
          summarized = nullptr;
        }
        if (object != nullptr) {
          if (throughPointer(*object)) {
            checkUse(value(object, current), call);
          }
          if (overwritten || structural(*callee, objectType(*object))) {
            checkUse(reference(object, current), call);
          } else {
            checkUse(summarized == nullptr ? receiverContents(*object, current) : usedReceiverContents(*summarized, *object, current), call);
          }
        }
        const auto offset = argumentOffset(call);
        for (unsigned index = 0; index < call.getNumArgs(); ++index) {
          const auto *argument = call.getArg(index);
          if (overwritten && argument == object) {
            continue;
          }
          // Reading an argument checks the places it reads through, whether or not its contents are used.
          const auto contents = value(argument, current);
          if (summarized == nullptr || (index >= offset && usesArgument(*summarized, index - offset))) {
            checkUse(contents, call);
          }
        }

        const auto name = callee->getNameAsString();
        const auto *known = knownFunction(call);
        if ((known != nullptr && known->summary.invalidates_environment) || ((name == "getenv" || name == "setenv" || name == "unsetenv" || name == "putenv") && context_.getSourceManager().isInSystemHeader(callee->getLocation()))) {
          invalidateEnvironment(call, current);
        }
        applyInferredInvalidations(call, current);
        const auto type = object == nullptr ? clang::QualType{} : objectType(*object);
        if (object != nullptr && libraryRecord(type) && !viewType(type) && !iteratorRecord(type)) {
          // The standard container modifiers that store their arguments.
          const bool insertion = name == "append" || name == "prepend" || name == "push_back" || name == "push_front" || name == "emplace_back" || name == "emplace_front" || name == "emplace" || name == "emplace_hint" || name == "insert" || name == "insert_or_assign" || name == "try_emplace" || name == "assign";
          const bool contiguous = standardType(type, "basic_string") || standardType(type, "vector");
          // Destroying elements frees everything below them. Growth moves the element slots, and with them
          // whatever an element owns inline.
          const bool destroys = name == "clear" || name == "assign" || name == "operator=" || name == "resize";
          const bool grows = name == "append" || name == "reserve" || insertion;
          const auto element = elementType(type);
          const bool slots_only = grows && !destroys && !element.isNull() && ownsNothingInline(element);
          if (contiguous && (destroys || grows)) {
            for (const auto &target : invalidationTargets(*object, current)) {
              invalidate(target, &call, current, false, slots_only ? element_slots : owned_storage);
            }
          }
          // Resetting or reassigning a unique owner destroys its object. Only the owner itself is invalidated,
          // never an enclosing object that it was merged into.
          if (uniqueOwner(type) && (name == "reset" || name == "operator=")) {
            for (const auto *target : objectTargets(*object, current)) {
              if (sameType(target->getType(), type)) {
                invalidate({.variable = target}, &call, current, false, owned_storage);
              }
            }
          }
          // A cleared container holds no elements, so it keeps none of its previous loans.
          if (name == "clear") {
            const auto cleared = writeTargets(objectReference(*object, current), objectTargets(*object, current));
            if (cleared.replaces) {
              store(cleared, {}, current);
            }
          }
          if (insertion) {
            for (unsigned index = offset; index < call.getNumArgs(); ++index) {
              if (transfersAllocation(call.getArg(index)->getType())) {
                transferOwnership(movedFrom(call.getArg(index)), objectTargets(*object, current), deepen(storage_kind::data), current);
              }
            }
          }
          if (name == "swap" && transfersAllocation(type) && call.getNumArgs() > offset) {
            const auto mine = objectTargets(*object, current);
            const auto theirs = targets(call.getArg(offset), current);
            if (mine.size() == 1 && theirs.size() == 1) {
              exchangeOwnership(mine.front(), theirs.front(), current);
            }
          }
          // Emplacement forwards to the element's constructor, which only a standard element is known to keep.
          const bool forwarded = name.starts_with("emplace") || name == "try_emplace";
          if (insertion && !element.isNull() && containsViews(element) && (!forwarded || libraryRecord(element) || viewType(element))) {
            loans incoming;
            for (unsigned index = offset; index < call.getNumArgs(); ++index) {
              if (!pointerLike(call.getArg(index)->getType())) {
                incoming.merge(copiedValue(call.getArg(index), current));
              }
            }
            auto where = writeTargets(objectReference(*object, current), objectTargets(*object, current));
            where.replaces = false;
            store(where, unplaced(incoming), current);
          }
        }
        if (object == nullptr && name == "swap" && standardDeclaration(*callee) && call.getNumArgs() == 2 && transfersAllocation(call.getArg(0)->getType())) {
          const auto left = targets(call.getArg(0), current);
          const auto right = targets(call.getArg(1), current);
          if (left.size() == 1 && right.size() == 1) {
            exchangeOwnership(left.front(), right.front(), current);
          }
        }
        if (const auto *operation = llvm::dyn_cast<clang::CXXOperatorCallExpr>(&call)) {
          if (operation->getOperator() == clang::OO_Equal && operation->getNumArgs() == 2) {
            assign(*operation, current);
          }
        }

        for (unsigned index = 0; index < callee->getNumParams() && index + offset < call.getNumArgs(); ++index) {
          const auto *parameter = callee->getParamDecl(index);
          if (!outputParameter(*parameter)) {
            continue;
          }
          const auto region = parameterAnnotation(*parameter, context_).region;
          loans incoming;
          for (unsigned other = 0; other < callee->getNumParams() && other + offset < call.getNumArgs(); ++other) {
            const auto *input = callee->getParamDecl(other);
            const auto annotation = parameterAnnotation(*input, context_);
            if (other != index && annotation.present && annotation.region == region && !outputParameter(*input)) {
              incoming.merge(storage(call.getArg(other + offset), current));
            }
          }
          store(writeTargets(reference(call.getArg(index + offset), current), targets(call.getArg(index + offset), current)), incoming, current);
        }
        // A parameter region shared with a receiver field lets a mutating call retain that argument.
        // Earlier arguments may still be retained, so the receiver accumulates loans.
        if (object != nullptr && method != nullptr && !method->isConst()) {
          loans retained;
          for (unsigned index = 0; index < callee->getNumParams() && index + offset < call.getNumArgs(); ++index) {
            const auto *parameter = callee->getParamDecl(index);
            const auto region = parameterAnnotation(*parameter, context_).region;
            if (region != nullptr && !outputParameter(*parameter) && receiverHasRegion(*callee, region)) {
              retained.merge(storage(call.getArg(index + offset), current));
            }
          }
          if (!retained.values.empty()) {
            auto where = writeTargets(objectReference(*object, current), objectTargets(*object, current));
            where.replaces = false;
            store(where, retained, current);
          }
        }
        applyInferredWrites(call, current);
      }

      // A by-reference capture of an enclosing parameter is not one of the lambda's own parameters.
      static bool calleeParameter(const clang::ParmVarDecl &parameter, const function_entry &callee) {
        return parameter.getDeclContext() == callee.definition;
      }

      void applyInferredInvalidations(const clang::CallExpr &call, state &current) {
        const auto *known = knownFunction(call);
        if (known == nullptr) {
          return;
        }
        for (const auto &[target, range] : known->summary.invalidates) {
          const auto *parameter = llvm::dyn_cast<clang::ParmVarDecl>(target.variable);
          if (parameter != nullptr && calleeParameter(*parameter, *known)) {
            const auto index = parameter->getFunctionScopeIndex() + argumentOffset(call);
            if (index >= call.getNumArgs()) {
              continue;
            }
            // A place below what a parameter holds, like its pointee, lies below what the argument holds.
            if (target.level == storage_kind::inherited) {
              for (const auto &actual : value(call.getArg(index), current).values) {
                if (const auto place = placeWithin(actual, target)) {
                  invalidate(*place, &call, current, false, range);
                }
              }
              continue;
            }
            for (const auto &actual : invalidationTargets(*call.getArg(index), current)) {
              invalidate(rebased(actual, target), &call, current, false, range);
            }
          } else if (const auto *field = llvm::dyn_cast<clang::FieldDecl>(target.variable)) {
            const auto *object = receiver(call);
            if (object == nullptr) {
              continue;
            }
            if (capturedReceiver(*call.getDirectCallee(), field)) {
              for (const auto &actual : capturedThis(*call.getDirectCallee(), *object, current).values) {
                if (const auto place = placeWithin(actual, receiverPlace(target))) {
                  invalidate(*place, &call, current, false, range);
                }
              }
            } else if (llvm::isa<clang::CXXThisExpr>(clean(object))) {
              invalidate(target, &call, current, false, range);
            } else if (field->getType()->isReferenceType()) {
              for (const auto &binding : receiverContents(*object, current).values) {
                invalidate(rebased({.variable = binding.variable, .level = binding.storage, .path = binding.path}, target), &call, current, false, range);
              }
            } else {
              for (const auto &actual : invalidationTargets(*object, current)) {
                invalidate(rebased(actual, receiverPlace(target)), &call, current, false, range);
              }
            }
          } else {
            invalidate(target, &call, current, false, range);
          }
        }
      }

      static void stampTemporary(loans &borrow, clang::SourceLocation location) {
        for (auto &source : borrow.values) {
          if (source.kind == origin_kind::temporary && source.borrow_site.isInvalid()) {
            source.borrow_site = location;
          }
        }
      }

      void applyInferredWrites(const clang::CallExpr &call, state &current) {
        const auto *known = knownFunction(call);
        if (known == nullptr) {
          return;
        }
        // Several summary writes can land on one place, which then receives all of them.
        llvm::SmallVector<std::pair<write_targets, loans>, 2> updates;
        const auto update = [&](const write_targets &where, const loans &incoming) {
          for (const auto &target : where.places) {
            const auto found = std::ranges::find_if(updates, [&](const auto &entry) { return entry.first.places.front().variable == target.variable && entry.first.places.front().fields == target.fields; });
            if (found == updates.end()) {
              updates.emplace_back(write_targets{.places = {target}, .replaces = where.replaces}, incoming);
            } else {
              found->first.replaces = found->first.replaces && where.replaces;
              found->second.merge(incoming);
            }
          }
        };
        const auto whole = [](const clang::ValueDecl *variable) { return write_targets{.places = {{.variable = variable}}, .replaces = true}; };
        for (const auto &write : known->summary.writes) {
          const auto *parameter = llvm::dyn_cast<clang::ParmVarDecl>(write.first);
          if (parameter != nullptr && calleeParameter(*parameter, *known)) {
            // An explicit in/out contract is handled above, including an empty loan set.
            if (outputParameter(*parameter)) {
              continue;
            }
            const auto index = parameter->getFunctionScopeIndex() + argumentOffset(call);
            if (index < call.getNumArgs()) {
              update(writeTargets(reference(call.getArg(index), current), targets(call.getArg(index), current)), instantiate(write.second, call, current));
            }
          } else if (llvm::isa<clang::VarDecl>(write.first)) {
            if (visibleVariable(write.first)) {
              update(whole(write.first), instantiate(write.second, call, current));
            }
          } else if (const auto *object = receiver(call)) {
            if (llvm::isa<clang::CXXThisExpr>(clean(object))) {
              update(whole(write.first), instantiate(write.second, call, current));
            } else if (const auto *field = llvm::dyn_cast<clang::FieldDecl>(write.first)) {
              // The receiver's field lies at that field of each place the receiver can have.
              const bool captured = capturedReceiver(*call.getDirectCallee(), field);
              auto places = captured ? capturedThis(*call.getDirectCallee(), *object, current) : objectReference(*object, current);
              for (auto &source : places.values) {
                project(source, *field);
              }
              update(writeTargets(places, captured ? llvm::ArrayRef<const clang::ValueDecl *>{} : llvm::ArrayRef<const clang::ValueDecl *>{objectTargets(*object, current)}), instantiate(write.second, call, current));
            }
          }
        }
        for (auto &[where, incoming] : updates) {
          stampTemporary(incoming, call.getExprLoc());
          store(where, incoming, current);
        }
      }

      void assign(const clang::Expr &expression, state &current) {
        const auto *binary = llvm::dyn_cast<clang::BinaryOperator>(&expression);
        const auto *operation = llvm::dyn_cast<clang::CXXOperatorCallExpr>(&expression);
        if (binary == nullptr && (operation == nullptr || operation->getNumArgs() != 2)) {
          return;
        }
        const auto *left = binary != nullptr ? binary->getLHS() : operation->getArg(0);
        const auto *right = binary != nullptr ? binary->getRHS() : operation->getArg(1);
        if (transfersAllocation(left->getType())) {
          transferOwnership(movedFrom(right), targets(left, current), storage_kind::data, current);
        }
        if (!containsViews(left->getType())) {
          return;
        }
        auto incoming = viewType(left->getType()) ? value(right, current) : copiedValue(right, current);
        for (auto &source : incoming.values) {
          markBorrowSite(source, right->getBeginLoc());
        }
        // A library object keeps what it is assigned in its own layout.
        store(writeTargets(reference(left, current), targets(left, current)), operation != nullptr && libraryRecord(left->getType()) ? unplaced(incoming) : incoming, current);
      }

      void transfer(const clang::CFGBlock &block, state &current) {
        for (const auto &element : block) {
          if (const auto initialized = element.getAs<clang::CFGInitializer>()) {
            const auto *initializer = initialized->getInitializer();
            if (initializer->isMemberInitializer()) {
              const auto *field = initializer->getMember();
              if (containsViews(field->getType())) {
                auto incoming = field->getType()->isReferenceType() ? reference(initializer->getInit(), current) : value(initializer->getInit(), current);
                for (auto &source : incoming.values) {
                  markBorrowSite(source, initializer->getInit()->getBeginLoc());
                }
                current.values[field] = std::move(incoming);
                current.written.insert(field);
              }
              if (transfersAllocation(field->getType())) {
                transferOwnership(movedFrom(initializer->getInit()), {field}, storage_kind::data, current);
              }
            }
          }
          if (const auto lifetime = element.getAs<clang::CFGLifetimeEnds>()) {
            const auto *variable = lifetime->getVarDecl();
            if (!llvm::isa<clang::ParmVarDecl>(variable)) {
              invalidate({.variable = variable}, lifetime->getTriggerStmt(), current, true);
            }
          }
          if (const auto destructor = element.getAs<clang::CFGAutomaticObjDtor>()) {
            invalidate({.variable = destructor->getVarDecl()}, destructor->getTriggerStmt(), current, true);
          }
          const auto statement = element.getAs<clang::CFGStmt>();
          if (!statement) {
            continue;
          }
          const auto *node = statement->getStmt();
          if (const auto *declaration = llvm::dyn_cast<clang::DeclStmt>(node)) {
            for (const auto *entry : declaration->decls()) {
              const auto *variable = llvm::dyn_cast<clang::VarDecl>(entry);
              if (variable == nullptr || !variable->hasInit()) {
                continue;
              }
              if (variable->getType()->isReferenceType()) {
                current.references[variable] = reference(variable->getInit(), current);
                stampTemporary(current.references[variable], variable->getLocation());
              }
              auto incoming = value(variable->getInit(), current);
              stampTemporary(incoming, variable->getLocation());
              current.values[variable] = incoming;
              if (transfersAllocation(variable->getType())) {
                transferOwnership(movedFrom(variable->getInit()), {variable}, storage_kind::data, current);
              }
            }
          } else if (const auto *returned = llvm::dyn_cast<clang::ReturnStmt>(node)) {
            checkReturn(*returned, current);
          } else if (const auto *construction = llvm::dyn_cast<clang::CXXConstructExpr>(node)) {
            for (const auto *argument : construction->arguments()) {
              checkUse(value(argument, current), *construction);
            }
          } else if (const auto *call = llvm::dyn_cast<clang::CallExpr>(node)) {
            applyCall(*call, current);
          } else if (const auto *operation = llvm::dyn_cast<clang::BinaryOperator>(node)) {
            if (operation->isAssignmentOp()) {
              assign(*operation, current);
            }
          }
        }
      }
    };
  }

  struct lifetime_analysis::implementation {
    inference_cache cache;
  };

  lifetime_analysis::lifetime_analysis(bool errors)
      : implementation_(std::make_unique<implementation>()),
        errors_(errors) {}

  lifetime_analysis::~lifetime_analysis() = default;

  void lifetime_analysis::beginTranslationUnit() {
    reported_.clear();
    implementation_->cache.clear();
  }

  void lifetime_analysis::analyze(const clang::FunctionDecl &function, clang::ASTContext &context) {
    const auto *definition = function.getDefinition();
    if (definition == nullptr || definition->getBody() == nullptr || definition->isDependentContext()) {
      return;
    }

    clang::CFG::BuildOptions options;
    options.AddInitializers = true;
    options.AddImplicitDtors = true;
    options.AddTemporaryDtors = true;
    options.AddLifetime = true;
    auto graph = clang::CFG::buildCFG(definition, definition->getBody(), &context, options);
    if (!graph) {
      if (containsViews(definition->getReturnType())) {
        auto &diagnostics = context.getDiagnostics();
        const auto id = diagnostics.getCustomDiagID(errors_ ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning, "cannot analyze borrowed result [tbc-missing-contract]");
        diagnostics.Report(definition->getLocation(), id);
      }
      return;
    }

    auto entry = std::make_unique<function_entry>();
    entry->definition = definition;
    entry->graph = std::move(graph);
    auto &cache = implementation_->cache;
    if (cache.functions.try_emplace(definition->getCanonicalDecl(), std::move(entry)).second) {
      cache.order.push_back(definition->getCanonicalDecl());
    }
  }

  void lifetime_analysis::finishTranslationUnit(clang::ASTContext &context) {
    if (context.getDiagnostics().hasUncompilableErrorOccurred()) {
      return;
    }
    auto &cache = implementation_->cache;
    llvm::SmallVector<const clang::FunctionDecl *, 32> work;
    for (const auto *key : llvm::reverse(cache.order)) {
      work.push_back(key);
      cache.functions.find(key)->second->queued = true;
    }

    // Summaries grow monotonically; dependency requeueing also solves recursive calls.
    while (!work.empty()) {
      const auto *key = work.pop_back_val();
      auto &entry = *cache.functions.find(key)->second;
      entry.queued = false;
      function_analysis analysis(*entry.definition, context, errors_, reported_, cache);
      const auto inferred = analysis.run(*entry.graph);
      if (entry.summary.merge(inferred)) {
        for (const auto *dependent : entry.dependents) {
          auto &next = *cache.functions.find(dependent)->second;
          if (!next.queued) {
            next.queued = true;
            work.push_back(dependent);
          }
        }
      }
    }

    llvm::SmallVector<function_entry *, 32> ordered;
    for (const auto *key : cache.order) {
      ordered.push_back(cache.functions.find(key)->second.get());
    }
    std::ranges::stable_sort(ordered, [&](const auto *left, const auto *right) {
      return context.getSourceManager().isBeforeInTranslationUnit(left->definition->getBeginLoc(), right->definition->getBeginLoc());
    });
    for (const auto *entry : ordered) {
      function_analysis analysis(*entry->definition, context, errors_, reported_, cache);
      analysis.run(*entry->graph, true);
    }
  }
}
