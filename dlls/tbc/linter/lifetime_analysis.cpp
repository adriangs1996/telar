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
    // A dereference step moves on to the objects that what the path reached so far designates; only
    // the part of an input a borrow stands for, and positions inside what an input designates, take it.
    struct projection {
      const clang::FieldDecl *field = nullptr;
      storage_kind level = storage_kind::object;
      bool dereference = false;

      bool operator==(const projection &) const = default;
    };

    // The most steps a path records. The steps past it are not known, which keeps the places finite
    // while loops walk through nested and recursive structures. Where an object holds a borrow is
    // recorded more coarsely than where a borrow points. Fields count against these bounds;
    // dereferences have their own, which leaves room for wrappers that reach a stream through
    // references.
    enum class path_bound : std::uint8_t {
      held = 2,
      steps = 4,
      dereferences = 3,
    };

    // The fields leading from a variable to a place inside it, outermost first.
    using field_path = llvm::SmallVector<projection, 2>;

    // A step that stands for any field of its object.
    bool cut(const projection &step) {
      return step.field == nullptr && !step.dereference;
    }

    // Appends a step unless the path is full or already cut at the step's level. The deepest level
    // merges every level below it, so its fields are not recorded. A dereference starts a new object; it
    // does not follow a cut, since what an unknown field designates is not known.
    void appendStep(field_path &path, projection step, path_bound bound = path_bound::steps) {
      const auto fields = static_cast<std::size_t>(std::ranges::count_if(path, [](const projection &earlier) { return !earlier.dereference; }));
      const auto dereferences = path.size() - fields;
      if (step.dereference) {
        if (dereferences <= std::to_underlying(path_bound::dereferences) && (path.empty() || !cut(path.back()))) {
          path.push_back({.dereference = true});
        }
        return;
      }
      if (step.level == storage_kind::deepest || fields >= std::to_underlying(bound)) {
        return;
      }
      if (!path.empty() && !path.back().dereference && (path.back().level > step.level || (path.back().level == step.level && path.back().field == nullptr))) {
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

    // A place inside a variable: the level of the object there, and the fields that lead to it. A
    // place inside what an input designates names that input and the part of it that designates.
    struct object_place {
      const clang::ValueDecl *variable = nullptr;
      storage_kind level = storage_kind::object;
      field_path path{};
      bool designated = false;
      field_path select{};

      bool operator==(const object_place &) const = default;
    };

    // The place a callee's place denotes once its own variable is replaced by an actual place.
    object_place rebased(object_place actual, const object_place &symbolic) {
      appendMoved(actual.path, symbolic.path, storage_kind::object, actual.level);
      actual.level = relocate(actual.level, symbolic.level);
      return actual;
    }

    // Whether two parts of one input can designate the same objects: as many dereferences, and on the
    // way to each, fields that agree as far as both are known. Inputs are assumed not to alias one
    // another, and neither do the objects reached through different dereferences of one input.
    bool sameDesignation(const field_path &left, const field_path &right) {
      std::size_t first = 0;
      std::size_t second = 0;
      while (true) {
        bool known = true;
        for (; first < left.size() && second < right.size() && !left[first].dereference && !right[second].dereference; ++first, ++second) {
          if (known && !cut(left[first]) && !cut(right[second]) && left[first].field != right[second].field) {
            return false;
          }
          known = known && !cut(left[first]) && !cut(right[second]);
        }
        for (; first < left.size() && !left[first].dereference; ++first) {
        }
        for (; second < right.size() && !right[second].dereference; ++second) {
        }
        if (first == left.size() || second == right.size()) {
          return first == left.size() && second == right.size();
        }
        ++first;
        ++second;
      }
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
        path = llvm::hash_combine(path, step.field, step.dereference);
      }
      return llvm::hash_combine(std::to_underlying(value.kind), std::to_underlying(value.storage), path, value.variable, value.expression, value.region, value.invalidated, value.full_expression, value.borrow_site.getRawEncoding());
    }

    // Whether a borrow held at one position stands for the same borrow held at another: the second
    // lies inside the first, or the first is cut before they differ.
    bool covers(const field_path &outer, const field_path &inner) {
      for (std::size_t index = 0; index < outer.size(); ++index) {
        if (cut(outer[index])) {
          return true;
        }
        if (index == inner.size() || inner[index].field != outer[index].field || inner[index].dereference != outer[index].dereference) {
          return false;
        }
      }

      return true;
    }

    // Whether one part of an input contains another: the second selects further fields of the same
    // object, or fields the first's cut already selects. A further dereference reaches other objects.
    bool coversSelect(const field_path &outer, const field_path &inner) {
      const auto fields = [&](std::size_t from) { return std::ranges::none_of(llvm::drop_begin(inner, static_cast<unsigned>(from)), [](const projection &step) { return step.dereference; }); };
      for (std::size_t index = 0; index < outer.size(); ++index) {
        if (index == inner.size()) {
          return false;
        }
        if (cut(outer[index])) {
          return fields(index);
        }
        if (outer[index] != inner[index]) {
          return false;
        }
      }

      return fields(outer.size());
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

    // The parts of inputs a function uses. Using a part uses every part inside it, so a part another
    // one contains adds nothing.
    bool addUse(loans &uses, const origin &use) {
      const auto same = [&](const origin &other) { return other.kind == use.kind && other.variable == use.variable; };
      if (std::ranges::any_of(uses.values, [&](const origin &other) { return same(other) && coversSelect(other.select, use.select); })) {
        return false;
      }
      llvm::erase_if(uses.values, [&](const origin &other) { return same(other) && coversSelect(use.select, other.select); });
      uses.values.push_back(use);
      return true;
    }

    enum class containment : std::uint8_t {
      inside,
      covering,
      apart,
    };

    // How a position inside an object relates to the subobject at some of its fields: inside it, at
    // an unknown position that covers it, or apart from it.
    containment contain(const field_path &position, const field_path &fields) {
      for (std::size_t index = 0; index < fields.size(); ++index) {
        if (index == position.size() || cut(position[index]) || cut(fields[index])) {
          return containment::covering;
        }
        if (position[index].field != fields[index].field || position[index].dereference != fields[index].dereference) {
          return containment::apart;
        }
      }

      return containment::inside;
    }

    // A borrow that stands for what an input held at its position, whatever input part that was.
    bool standsForInput(const origin &source) {
      return source.kind == origin_kind::parameter || source.kind == origin_kind::receiver_region || source.kind == origin_kind::captured_contents;
    }

    // What an object of a type owns one level below it: a smart pointer's object or a container's
    // elements. Null where that is not known.
    clang::QualType ownedType(clang::QualType type) {
      return smartPointer(type) ? memberType(type, "element_type") : elementType(type);
    }

    // Whether an object of one type can be the object another type designates: the same type, a base
    // or a derived class of it, raw bytes, or a type that is not known.
    bool compatible(clang::QualType expected, clang::QualType actual) {
      if (expected.isNull() || actual.isNull()) {
        return true;
      }
      expected = expected.getCanonicalType().getUnqualifiedType();
      actual = actual.getCanonicalType().getUnqualifiedType();
      if (expected == actual || expected->isVoidType() || expected->isCharType() || expected->isStdByteType() || standardType(expected, "byte")) {
        return true;
      }
      const auto *wanted = expected->getAsCXXRecordDecl();
      const auto *found = actual->getAsCXXRecordDecl();
      if (wanted == nullptr || found == nullptr) {
        return false;
      }
      if (!wanted->hasDefinition() || !found->hasDefinition()) {
        return true;
      }
      return wanted->getCanonicalDecl() == found->getCanonicalDecl() || wanted->isDerivedFrom(found) || found->isDerivedFrom(wanted);
    }

    // Whether a field belongs to a record type or one of its bases. A reference binding has no fields.
    bool memberOf(clang::QualType type, const clang::FieldDecl &field) {
      if (type->isReferenceType()) {
        return false;
      }
      const auto *record = type->getAsCXXRecordDecl();
      if (record == nullptr || !record->hasDefinition()) {
        return false;
      }
      record = record->getDefinition();
      if (field.getParent()->getCanonicalDecl() == record->getCanonicalDecl()) {
        return true;
      }
      return std::ranges::any_of(record->bases(), [&](const clang::CXXBaseSpecifier &base) { return memberOf(base.getType(), field); });
    }

    // The type of the part of an input a borrow stands for, or null where a step on the way is not known.
    // A receiver field holds its own type, which for a reference is the binding to its referent.
    clang::QualType partType(const origin &source) {
      if (source.variable == nullptr) {
        return {};
      }
      auto type = source.kind == origin_kind::receiver_region ? source.variable->getType() : source.variable->getType().getNonReferenceType();
      for (const auto &step : source.select) {
        if (type.isNull() || cut(step)) {
          return {};
        }
        if (step.dereference) {
          type = designatedType(type);
        } else if (memberOf(type, *step.field)) {
          type = step.field->getType();
        } else {
          return {};
        }
      }
      return type;
    }

    // The type of the object a borrow's place lies in, or null where a step on the way is not known. A
    // borrow standing for an input lies in what that part designates; any other lies in its variable,
    // or in its temporary.
    clang::QualType placeType(const origin &source) {
      clang::QualType type;
      if (standsForInput(source)) {
        const auto part = partType(source);
        type = part.isNull() ? clang::QualType{} : designatedType(part);
      } else if (llvm::isa_and_nonnull<clang::MaterializeTemporaryExpr>(source.expression)) {
        type = source.expression->getType().getNonReferenceType();
      } else if (source.variable != nullptr && source.kind != origin_kind::unknown) {
        type = source.variable->getType().getNonReferenceType();
      }
      auto level = storage_kind::object;
      const auto descend = [&](storage_kind to) {
        for (; !type.isNull() && level < to && level != storage_kind::deepest; level = deepen(level)) {
          type = ownedType(type);
        }
      };
      for (const auto &step : source.path) {
        descend(step.level);
        if (type.isNull() || step.field == nullptr || !memberOf(type, *step.field)) {
          return {};
        }
        type = step.field->getType().getNonReferenceType();
      }
      descend(source.storage);
      return type;
    }

    // The type of what a part of a callee's input designates, where it is known.
    clang::QualType designatedTypeOf(const clang::ValueDecl &input, field_path select) {
      auto kind = origin_kind::captured_contents;
      if (llvm::isa<clang::ParmVarDecl>(input)) {
        kind = origin_kind::parameter;
      } else if (llvm::isa<clang::FieldDecl>(input)) {
        kind = origin_kind::receiver_region;
      }
      const auto part = partType({.kind = kind, .select = std::move(select), .variable = &input});
      return part.isNull() ? clang::QualType{} : designatedType(part);
    }

    // The borrows among designations whose place can be an object of a type.
    loans ofType(const loans &designations, clang::QualType type) {
      loans result;
      for (const auto &designation : designations.values) {
        if (compatible(type, placeType(designation))) {
          result.add(designation);
        }
      }
      return result;
    }

    // Such a borrow, moved from its position to one inside it, stands for the same part of the input.
    // Where its position is cut, which part is not known, so it never narrows again. A field the part's
    // type does not have means the borrow came from elsewhere in its holder, which is not known either.
    void narrow(origin &source, const field_path &position) {
      if (!standsForInput(source)) {
        return;
      }
      if (std::ranges::any_of(source.held, cut)) {
        appendStep(source.select, {.field = nullptr}, path_bound::held);
        return;
      }
      for (std::size_t index = source.held.size(); index < position.size(); ++index) {
        const auto &step = position[index];
        const auto type = partType(source);
        if (!step.dereference && !cut(step) && !type.isNull() && !memberOf(type, *step.field)) {
          appendStep(source.select, {.field = nullptr}, path_bound::held);
          return;
        }
        appendStep(source.select, step, path_bound::held);
      }
    }

    // Where in what an input holds a borrow's place lies: past the part it stands for, a dereference,
    // then the fields inside the designated object. Storage that object owns is not laid out in fields.
    // The input itself is followed when it designates anything, and past a field only a reference is:
    // what a pointer held in a field designates stays merged with the object that holds the pointer.
    // There is no position either where the path cannot record the dereference.
    std::optional<field_path> designatedPosition(const origin &source) {
      const auto type = partType(source);
      const bool follows = type.isNull() || (source.select.empty() ? !designatedType(type).isNull() : type->isReferenceType());
      if (!follows) {
        return std::nullopt;
      }
      auto position = source.select;
      appendStep(position, {.dereference = true});
      if (position.size() == source.select.size()) {
        return std::nullopt;
      }
      bool owned = depth(source.storage) != 0;
      for (const auto &step : source.path) {
        if (depth(step.level) != 0) {
          owned = true;
          break;
        }
        appendStep(position, step, path_bound::held);
      }
      if (owned) {
        appendStep(position, {.field = nullptr}, path_bound::held);
      }
      return position;
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
      // What was written into the objects an input designates, held at positions inside what the
      // input holds, past a dereference.
      llvm::DenseMap<const clang::ValueDecl *, loans> designated;
      llvm::SmallPtrSet<const clang::ValueDecl *, 8> written;

      loans get(const clang::ValueDecl *key) const {
        return held(key);
      }

      // What a variable holds, without a copy.
      const loans &held(const clang::ValueDecl *key) const {
        static const loans nothing;
        const auto found = values.find(key);
        return found == values.end() ? nothing : found->second;
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
        for (const auto &entry : other.designated) {
          changed = designated[entry.first].merge(entry.second) || changed;
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
      // What the function writes into the objects its inputs designate, as the state keeps it.
      llvm::DenseMap<const clang::ValueDecl *, loans> designated;
      bool invalidates_environment = false;
      llvm::SmallVector<invalidation, 2> invalidates;
      // The parts of its parameters and receiver fields whose incoming contents the function uses.
      loans uses;

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

      static bool mergeWrites(llvm::DenseMap<const clang::ValueDecl *, loans> &into, const llvm::DenseMap<const clang::ValueDecl *, loans> &from) {
        bool changed = false;
        for (const auto &entry : from) {
          const auto inserted = into.try_emplace(entry.first);
          changed = inserted.second || changed;
          changed = inserted.first->second.merge(entry.second) || changed;
        }
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
        for (const auto &use : other.uses.values) {
          changed = addUse(uses, use) || changed;
        }
        changed = mergeWrites(writes, other.writes) || changed;
        changed = mergeWrites(designated, other.designated) || changed;

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
          // A branch on which alternative a variant holds tells each successor what it can hold there.
          const auto test = block->succ_size() == 2 ? alternativeTest(block->getLastCondition(), conditionVariable(*block)) : std::nullopt;
          bool taken = true;
          for (const auto &successor : block->succs()) {
            const auto *next = successor.getReachableBlock();
            const bool branch = std::exchange(taken, false);
            if (next == nullptr) {
              continue;
            }

            const auto id = next->getBlockID();
            bool changed = false;
            if (test) {
              auto refined = output;
              refine(*test, branch, refined);
              changed = inputs[id].merge(refined);
            } else {
              changed = inputs[id].merge(output);
            }
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
        const auto escape = [&](const loans &written) {
          for (const auto &source : written.values) {
            if (source.kind == origin_kind::local || source.kind == origin_kind::temporary) {
              report(issue::dangling, source.borrow_site.isValid() ? source.borrow_site : function_.getEndLoc(), &source);
            }
          }
        };
        for (const auto *key : exit.written) {
          if (llvm::isa<clang::FieldDecl>(key) || callerVisible(key) || by_reference_.contains(key)) {
            summary_.writes[key] = exit.get(key);
            escape(summary_.writes[key]);
          }
        }
        // Objects an input designates belong to the caller. Writes into them never replace, so what an
        // object held on entry, held back where it was, tells the caller nothing.
        for (const auto &[input, written] : exit.designated) {
          auto &kept = summary_.designated[input];
          for (const auto &source : written.values) {
            if (!standsForInput(source) || source.variable != input || source.select != source.held) {
              kept.add(source);
            }
          }
          escape(kept);
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

      // A test of which alternative a variant holds, as `std::holds_alternative<T>(v)` or
      // `std::get_if<T>(&v)` performs it.
      struct alternative_test {
        const clang::Expr *variant = nullptr;
        // Whether the expression points to the variant rather than designating it.
        bool through_pointer = false;
        clang::QualType alternative{};
        // Whether the variant holds the alternative when the test is true.
        bool holds = true;
      };

      static const clang::VarDecl *conditionVariable(const clang::CFGBlock &block) {
        const auto *terminator = block.getTerminatorStmt();
        if (const auto *branch = llvm::dyn_cast_or_null<clang::IfStmt>(terminator)) {
          return branch->getConditionVariable();
        }
        if (const auto *loop = llvm::dyn_cast_or_null<clang::WhileStmt>(terminator)) {
          return loop->getConditionVariable();
        }
        if (const auto *loop = llvm::dyn_cast_or_null<clang::ForStmt>(terminator)) {
          return loop->getConditionVariable();
        }
        return nullptr;
      }

      // The alternatives of a std::variant, in order.
      static llvm::SmallVector<clang::QualType, 4> alternatives(clang::QualType type) {
        llvm::SmallVector<clang::QualType, 4> result;
        const auto *record = llvm::dyn_cast_or_null<clang::ClassTemplateSpecializationDecl>(recordOf(type));
        if (record == nullptr || !standardType(type, "variant")) {
          return result;
        }
        const auto &arguments = record->getTemplateArgs();
        if (arguments.size() != 1 || arguments[0].getKind() != clang::TemplateArgument::Pack) {
          return result;
        }
        for (const auto &argument : arguments[0].pack_elements()) {
          result.push_back(argument.getAsType());
        }
        return result;
      }

      // Also negated, or through the variable a condition declares and tests.
      static std::optional<alternative_test> alternativeTest(const clang::Expr *condition, const clang::VarDecl *declared) {
        condition = clean(condition);
        if (condition == nullptr) {
          return std::nullopt;
        }
        if (const auto *negation = llvm::dyn_cast<clang::UnaryOperator>(condition); negation != nullptr && negation->getOpcode() == clang::UO_LNot) {
          auto test = alternativeTest(negation->getSubExpr(), declared);
          if (test) {
            test->holds = !test->holds;
          }
          return test;
        }
        if (const auto *reference = llvm::dyn_cast<clang::DeclRefExpr>(condition)) {
          return declared != nullptr && reference->getDecl() == declared && declared->hasInit() ? alternativeTest(declared->getInit(), nullptr) : std::nullopt;
        }
        const auto *call = llvm::dyn_cast<clang::CallExpr>(condition);
        const auto *callee = call == nullptr ? nullptr : call->getDirectCallee();
        const auto *name = callee == nullptr ? nullptr : callee->getIdentifier();
        if (name == nullptr || call->getNumArgs() != 1 || !standardDeclaration(*callee) || (name->getName() != "holds_alternative" && name->getName() != "get_if")) {
          return std::nullopt;
        }
        const auto *arguments = callee->getTemplateSpecializationArgs();
        if (arguments == nullptr || arguments->size() == 0) {
          return std::nullopt;
        }
        alternative_test test{.variant = clean(call->getArg(0))};
        if (name->getName() == "get_if") {
          const auto *address = llvm::dyn_cast<clang::UnaryOperator>(test.variant);
          test.through_pointer = address == nullptr || address->getOpcode() != clang::UO_AddrOf;
          test.variant = test.through_pointer ? test.variant : clean(address->getSubExpr());
        }
        const auto type = test.through_pointer ? test.variant->getType()->getPointeeType() : test.variant->getType();
        const auto &chosen = arguments->get(0);
        if (chosen.getKind() == clang::TemplateArgument::Type) {
          test.alternative = chosen.getAsType();
        } else if (chosen.getKind() == clang::TemplateArgument::Integral) {
          const auto choices = alternatives(type);
          const auto index = chosen.getAsIntegral().getZExtValue();
          if (index < choices.size()) {
            test.alternative = choices[index];
          }
        }
        if (test.alternative.isNull()) {
          return std::nullopt;
        }
        return test;
      }

      // On a branch where every alternative the variant can hold cannot borrow, it holds nothing borrowed.
      void refine(const alternative_test &test, bool taken, state &branch) {
        const auto choices = alternatives(test.through_pointer ? test.variant->getType()->getPointeeType() : test.variant->getType());
        if (choices.empty()) {
          return;
        }
        const bool holds = taken == test.holds;
        for (const auto &choice : choices) {
          if (holds == sameType(choice, test.alternative) && containsViews(choice)) {
            return;
          }
        }
        const auto where = writeTargets(test.through_pointer ? value(test.variant, branch) : reference(test.variant, branch), {});
        if (!where.replaces) {
          return;
        }
        for (const auto &target : where.places) {
          replaceHeld(branch.values[target.variable], target.variable->getType(), target.fields, {});
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
        for (auto *map : {&current.values, &current.references, &current.designated}) {
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
        for (auto *map : {&current.values, &current.references, &current.designated}) {
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

      // A by-value parameter is the callee's own copy; writes through a reference reach the caller, and
      // writes through a pointer or iterator land in what it designates.
      static bool callerVisible(const clang::ValueDecl *variable) {
        const auto *parameter = llvm::dyn_cast<clang::ParmVarDecl>(variable);
        return parameter != nullptr && parameter->getType()->isReferenceType();
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
          if (binding.variable == nullptr) {
            result.merge(current.get(key));
          } else if (standsForInput(binding)) {
            result.merge(designatedContents(binding, current));
          } else {
            result.merge(selected(current.get(binding.variable), inlineFields(binding.path)));
          }
        }
        return result;
      }

      // What the objects an input designates hold: a further part of that input, what they held on
      // entry, and what was written into them since. What a part not known to designate anything
      // designates stays merged with the input's own contents.
      static loans designatedContents(const origin &designation, const state &current) {
        const auto position = designatedPosition(designation);
        if (!position) {
          return selected(current.held(designation.variable), inlineFields(designation.path));
        }
        loans result;
        result.add({.kind = designation.kind, .select = *position, .variable = designation.variable});
        if (const auto found = current.designated.find(designation.variable); found != current.designated.end()) {
          result.merge(selected(found->second, *position));
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
          result.push_back({.variable = source.variable, .level = source.storage, .path = source.path, .designated = standsForInput(source), .select = source.select});
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
        // Whether the write lands in what the variable, an input, designates.
        bool designated = false;
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
          // An object an input designates lies outside the function, past a dereference of that input.
          if (const auto position = standsForInput(source) ? designatedPosition(source) : std::nullopt) {
            exact = false;
            write_target target{.variable = source.variable, .fields = *position, .designated = true};
            const auto same = [&](const write_target &other) { return other.variable == target.variable && other.fields == target.fields && other.designated; };
            if (std::ranges::none_of(result.places, same)) {
              result.places.push_back(std::move(target));
            }
            continue;
          }
          auto fields = exactPlace(source) || source.storage > storage_kind::object ? inlineFields(source.path) : field_path{};
          exact = exact && exactPlace(source) && fields.size() <= std::to_underlying(path_bound::held);
          fields.truncate(std::min<std::size_t>(fields.size(), std::to_underlying(path_bound::held)));
          write_target target{.variable = source.variable, .fields = std::move(fields)};
          const auto same = [&](const write_target &other) { return other.variable == target.variable && other.fields == target.fields && !other.designated; };
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
          if (target.designated) {
            current.designated[target.variable].merge(heldAt(incoming, target.fields));
            continue;
          }
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
            return field->getType()->isReferenceType() ? fieldContents(*member, *field, current) : fieldPlace(*member, *field, current);
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
        // A member pointer selects one field of its object, which lies in that object's storage.
        if (const auto *operation = llvm::dyn_cast<clang::BinaryOperator>(expression); operation != nullptr && operation->isPtrMemOp()) {
          return operation->getOpcode() == clang::BO_PtrMemD ? reference(operation->getLHS(), current) : value(operation->getLHS(), current);
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
        return rebased({.variable = actual.variable, .level = actual.storage, .path = actual.path, .designated = standsForInput(actual), .select = actual.select}, {.level = symbolic.level, .path = steps});
      }

      // Inside a lambda, `this` is the object the closure captured. A field of the closure is its own.
      static bool capturedReceiver(const clang::FunctionDecl &callee, const clang::ValueDecl *field) {
        const auto *method = llvm::dyn_cast<clang::CXXMethodDecl>(&callee);
        return method != nullptr && method->getParent()->isLambda() && (field == nullptr || llvm::cast<clang::FieldDecl>(field)->getParent() != method->getParent());
      }

      // What a receiver holds at one of a callee's fields. Inside a lambda, a field of the enclosing
      // class belongs to the object the closure captured.
      loans receiverField(const clang::FunctionDecl &callee, const clang::Expr &object, const clang::FieldDecl &field, const state &current) {
        if (capturedReceiver(callee, &field)) {
          return selected(referencedContents(capturedThis(callee, object, current), current), field);
        }
        return llvm::isa<clang::CXXThisExpr>(clean(&object)) ? current.get(&field) : selected(receiverContents(object, current), field);
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
          // A reference member holds where its referent lies, as a constructor's initializer gives it.
          const bool binds = positioned && fields[index]->getType()->isReferenceType();
          auto contents = binds ? reference(initializer->getInit(index), current) : value(initializer->getInit(index), current);
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
        if (const auto *operation = llvm::dyn_cast<clang::BinaryOperator>(expression); operation != nullptr && operation->isPtrMemOp()) {
          return designates ? value(expression, current) : ownedBy(reference(expression, current));
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
        return source.kind == origin_kind::parameter || source.kind == origin_kind::parameter_storage;
      }

      // Substitutes one argument for a summary's symbolic parameter origin.
      loans argumentLoans(const origin &source, const clang::Expr &argument, const state &current) {
        return source.kind == origin_kind::parameter ? value(&argument, current) : reference(&argument, current);
      }

      // The part of an actual input that a summary's borrow stands for, through the objects it designates.
      loans selectedAlong(loans actual, const field_path &select, const state &current) {
        field_path fields;
        for (const auto &step : select) {
          if (!step.dereference) {
            fields.push_back(step);
            continue;
          }
          actual = referencedContents(selected(actual, fields), current);
          fields.clear();
        }
        return selected(actual, fields);
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
          const auto *field = llvm::dyn_cast<clang::FieldDecl>(write.first);
          if (field == nullptr) {
            continue;
          }
          field_path at;
          appendField(at, *field, storage_kind::object);
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
              actual = selectedAlong(actual, source.select, current);
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

      // What a summary's symbolic input stands for at a call, through the part of it the borrow selects,
      // before the borrow's place inside it is located. Nothing for an argument the call does not pass.
      std::optional<loans> actualFor(const origin &source, const clang::CallExpr &call, const state &current) {
        loans actual;
        if (parameterOrigin(source)) {
          const auto index = llvm::cast<clang::ParmVarDecl>(source.variable)->getFunctionScopeIndex() + argumentOffset(call);
          if (index >= call.getNumArgs()) {
            return std::nullopt;
          }
          actual = argumentLoans(source, *call.getArg(index), current);
        } else if (source.kind == origin_kind::receiver_region) {
          if (const auto *object = receiver(call)) {
            actual = receiverField(*call.getDirectCallee(), *object, *llvm::cast<clang::FieldDecl>(source.variable), current);
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
        } else {
          actual.add({.kind = origin_kind::unknown, .expression = &call});
        }
        if (!source.select.empty()) {
          actual = selectedAlong(actual, source.select, current);
        }
        return actual;
      }

      loans instantiate(const loans &symbolic, const clang::CallExpr &call, const state &current) {
        loans result;
        // Borrows of one part of one input share what that part stands for at this call.
        llvm::SmallVector<std::pair<const origin *, std::optional<loans>>, 8> resolved;
        for (const auto &source : symbolic.values) {
          // Static storage and the environment are the same places at every call.
          if (source.kind == origin_kind::static_storage || source.kind == origin_kind::environment || source.kind == origin_kind::unknown) {
            result.add(source);
            continue;
          }
          const auto same = [&](const auto &entry) { return entry.first->kind == source.kind && entry.first->variable == source.variable && entry.first->select == source.select; };
          auto found = std::ranges::find_if(resolved, same);
          if (found == resolved.end()) {
            resolved.emplace_back(&source, actualFor(source, call, current));
            found = std::prev(resolved.end());
          }
          if (!found->second) {
            continue;
          }
          auto actual = *found->second;
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
        // Borrows of one place, which differ only in where they are held, share what it holds.
        llvm::SmallVector<std::tuple<const origin *, field_path>, 4> visited;
        const auto first = [&](const origin &source, field_path at) {
          const auto same = [&](const auto &entry) { return std::get<0>(entry)->kind == source.kind && std::get<0>(entry)->variable == source.variable && std::get<0>(entry)->select == source.select && std::get<0>(entry)->storage == source.storage && std::get<1>(entry) == at; };
          if (std::ranges::any_of(visited, same)) {
            return false;
          }
          visited.emplace_back(&source, std::move(at));
          return true;
        };
        for (const auto &source : binding.values) {
          // An extended temporary is identified by its expression; its variable only bounds its lifetime.
          const bool extended_temporary = source.kind == origin_kind::local && llvm::isa_and_nonnull<clang::MaterializeTemporaryExpr>(source.expression);
          if (source.kind == origin_kind::unknown) {
            result.add(source);
          } else if (standsForInput(source)) {
            if (first(source, source.path)) {
              result.merge(designatedContents(source, current));
            }
          } else if (source.variable != nullptr && !extended_temporary) {
            if (first(source, inlineFields(source.path))) {
              result.merge(selected(readPlace(source.variable, current), inlineFields(source.path)));
            }
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
        // A static result's referent outlives every caller and borrows from none of the inputs.
        if (staticRegion(result_annotation.region)) {
          return {};
        }
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
        // A range that yields the result supplies it, so a value of its element type, like the one
        // std::ranges::find searches for, is not where the iterator points.
        bool ranged = false;
        for (unsigned index = offset; index < call.getNumArgs(); ++index) {
          ranged = ranged || yields(*call.getArg(index), call.getType());
        }
        for (unsigned index = offset; index < call.getNumArgs(); ++index) {
          const auto *argument = call.getArg(index);
          if (pointerLike(argument->getType())) {
            result.merge(value(argument, current));
          } else if (!ranged && call.getType()->isPointerType() && sameType(call.getType()->getPointeeType(), argument->getType())) {
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
          return containsViews(objectType(object)) ? referencedContents(value(&object, current), current) : loans{};
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
        // Which field a member pointer selects is not known, so its object's contents stand in for it.
        if (const auto *operation = llvm::dyn_cast<clang::BinaryOperator>(expression); operation != nullptr && operation->isPtrMemOp()) {
          if (!containsViews(operation->getType())) {
            return {};
          }
          return operation->getOpcode() == clang::BO_PtrMemD ? value(operation->getLHS(), current) : pointeeContents(*operation, operation->getLHS(), true, current);
        }
        if (const auto *member = llvm::dyn_cast<clang::MemberExpr>(expression)) {
          const auto *field = llvm::dyn_cast<clang::FieldDecl>(member->getMemberDecl());
          const bool borrowed = containsViews(member->getType()) || (field != nullptr && field->getType()->isReferenceType());
          // A reference field holds where its referent lies; reading it needs a live referent and yields
          // what the referent holds.
          if (field != nullptr && field->getType()->isReferenceType()) {
            const auto binding = fieldContents(*member, *field, current);
            checkUse(binding, *member);
            return containsViews(member->getType()) ? referencedContents(binding, current) : loans{};
          }
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
          // What a caller passed in is used here, so a call to this function uses that part of it. Handing
          // on where a parameter lies lets the receiver read all of it.
          if (source.variable != nullptr && (parameterOrigin(source) || source.kind == origin_kind::receiver_region)) {
            addUse(summary_.uses, {.kind = source.kind, .select = source.select, .variable = source.variable});
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
        // Callers do not check what they pass, so not even a labeled input can supply a static result,
        // and the environment can be replaced while its storage is still in use.
        if (staticRegion(output.region)) {
          return source.kind == origin_kind::static_storage;
        }
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
          // A declared contract, elided or labeled, is what callers without the body rely on.
          if (source.kind == origin_kind::local || source.kind == origin_kind::temporary) {
            report(issue::dangling, statement.getReturnLoc(), &source);
          } else if (output.present && source.kind != origin_kind::unknown && !allowed(source, output)) {
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
        // A place an input designates is reached only through the same part of that input.
        const auto reaches = [&](const origin &source) {
          if (standsForInput(source) != target.designated || (target.designated && !sameDesignation(source.select, target.select))) {
            return false;
          }
          return levels.contains(source.storage) && within(source.path, target);
        };
        for (auto *map : {&current.values, &current.references, &current.designated}) {
          for (auto &entry : *map) {
            for (auto &source : entry.second.values) {
              if (source.variable == owner && source.invalidated == nullptr && (destroyed || reaches(source))) {
                source.invalidated = trigger;
              }
            }
          }
        }
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
        // Calling a member function needs a live object. What it reads of the object's contents depends on
        // the function.
        if (object != nullptr) {
          checkUse(objectReference(*object, current), call);
          if (summarized == nullptr && !overwritten && !structural(*callee, objectType(*object))) {
            checkUse(receiverContents(*object, current), call);
          }
        }
        const auto offset = argumentOffset(call);
        for (unsigned index = 0; index < call.getNumArgs(); ++index) {
          const auto *argument = call.getArg(index);
          if (overwritten && argument == object) {
            continue;
          }
          // Reading an argument checks the places it reads through, whether or not its contents are used.
          // A variadic argument reaches no parameter a summary describes.
          const auto contents = value(argument, current);
          if (summarized == nullptr || (index >= offset && index - offset >= summarized->definition->getNumParams())) {
            checkUse(contents, call);
          }
          // A project function the checker cannot see may also read what a pointer argument designates.
          if (summarized == nullptr && !libraryFunction(*callee) && pointerLike(argument->getType())) {
            checkUse(referencedContents(contents, current), call);
          }
        }
        if (summarized != nullptr) {
          checkUse(instantiate(summarized->summary.uses, call, current), call);
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
          // Emplacement forwards to the element's constructor, which only a standard element or a pointer is
          // known to keep.
          const bool forwarded = name.starts_with("emplace") || name == "try_emplace";
          if (insertion && !element.isNull() && containsViews(element) && (!forwarded || libraryRecord(element) || viewType(element) || element->isPointerType())) {
            loans incoming;
            for (unsigned index = offset; index < call.getNumArgs(); ++index) {
              const auto *argument = call.getArg(index);
              // Where to insert is a position in the container itself.
              if (index == offset && positionIn(type, argument->getType())) {
                continue;
              }
              // An iterator range inserts copies of the elements it designates. Any other argument is the
              // element itself or what the element's constructor receives, a pointer included.
              if (pointerLike(argument->getType()) && !forwarded && !sameType(argument->getType(), element)) {
                incoming.merge(referencedContents(value(argument, current), current));
              } else {
                incoming.merge(copiedValue(argument, current));
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
        // Many places lie in the same part of one input, which the call resolves once.
        llvm::SmallVector<std::tuple<const clang::ValueDecl *, field_path, loans>, 4> designations;
        const auto designated = [&](const object_place &target) -> const loans & {
          const auto found = std::ranges::find_if(designations, [&](const auto &entry) { return std::get<0>(entry) == target.variable && std::get<1>(entry) == target.select; });
          if (found != designations.end()) {
            return std::get<2>(*found);
          }
          // Only an object of the type the callee's part designates can be what it invalidated.
          const auto actual = actualInput(*target.variable, call, *known, current);
          const auto type = designatedTypeOf(*target.variable, target.select);
          return std::get<2>(designations.emplace_back(target.variable, target.select, actual ? ofType(selectedAlong(*actual, target.select, current), type) : loans{}));
        };
        for (const auto &[target, range] : known->summary.invalidates) {
          // A place the callee's input designates lies where the same part of the actual input designates.
          if (target.designated) {
            for (const auto &designation : designated(target).values) {
              if (const auto place = placeWithin(designation, target)) {
                invalidate(*place, &call, current, false, range);
              }
            }
            continue;
          }
          const auto *parameter = llvm::dyn_cast<clang::ParmVarDecl>(target.variable);
          if (parameter != nullptr && calleeParameter(*parameter, *known)) {
            const auto index = parameter->getFunctionScopeIndex() + argumentOffset(call);
            if (index >= call.getNumArgs()) {
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

      // What a callee's input holds at a call: the argument for a parameter, or what the receiver holds at
      // a field. A variable the caller shares, like a by-reference capture, is the caller's own.
      std::optional<loans> actualInput(const clang::ValueDecl &input, const clang::CallExpr &call, const function_entry &callee, const state &current) {
        if (const auto *parameter = llvm::dyn_cast<clang::ParmVarDecl>(&input); parameter != nullptr && calleeParameter(*parameter, callee)) {
          const auto index = parameter->getFunctionScopeIndex() + argumentOffset(call);
          if (index >= call.getNumArgs()) {
            return std::nullopt;
          }
          return value(call.getArg(index), current);
        }
        if (const auto *field = llvm::dyn_cast<clang::FieldDecl>(&input)) {
          const auto *object = receiver(call);
          if (object == nullptr) {
            return std::nullopt;
          }
          return receiverField(*call.getDirectCallee(), *object, *field, current);
        }
        if (visibleVariable(&input)) {
          return readPlace(&input, current);
        }
        return std::nullopt;
      }

      // The objects a position inside what an input holds designates, through each of its dereferences.
      loans designatedBy(const loans &actual, const field_path &position, const state &current) {
        loans designations;
        auto contents = actual;
        field_path fields;
        bool designates = false;
        for (const auto &step : position) {
          if (!step.dereference) {
            fields.push_back(step);
            continue;
          }
          if (designates) {
            contents = referencedContents(designations, current);
          }
          designations = selected(contents, fields);
          fields.clear();
          designates = true;
        }
        return designations;
      }

      // Stores borrows held at positions inside what a callee's input holds, past at least one
      // dereference, into the objects those positions designate, which must have the type the callee's
      // part designates. Borrows that share the way there are stored together.
      void storeThrough(const loans &actual, const clang::ValueDecl &input, llvm::ArrayRef<origin> incoming, state &current) {
        llvm::SmallVector<std::pair<field_path, loans>, 4> groups;
        for (auto borrow : incoming) {
          std::size_t split = 0;
          for (std::size_t index = 0; index < borrow.held.size(); ++index) {
            split = borrow.held[index].dereference ? index + 1 : split;
          }
          if (split == 0) {
            continue;
          }
          field_path way(borrow.held.begin(), borrow.held.begin() + static_cast<std::ptrdiff_t>(split));
          borrow.held.erase(borrow.held.begin(), borrow.held.begin() + static_cast<std::ptrdiff_t>(split));
          auto found = std::ranges::find_if(groups, [&](const auto &group) { return group.first == way; });
          if (found == groups.end()) {
            found = groups.insert(groups.end(), {std::move(way), loans{}});
          }
          found->second.add(borrow);
        }
        for (const auto &[way, group] : groups) {
          const auto type = designatedTypeOf(input, field_path(way.begin(), std::prev(way.end())));
          auto where = writeTargets(ofType(designatedBy(actual, way, current), type), {});
          where.replaces = false;
          store(where, group, current);
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
        // What the callee wrote into objects its inputs designate lands in what the actual inputs designate.
        for (const auto &[input, written] : known->summary.designated) {
          const auto actual = actualInput(*input, call, *known, current);
          if (!actual) {
            continue;
          }
          auto incoming = instantiate(written, call, current);
          stampTemporary(incoming, call.getExprLoc());
          storeThrough(*actual, *input, incoming.values, current);
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
    // Calls reach definitions the matcher never visits: bodies imported from a module and the
    // instantiations of its templates. Unanalyzed, each would be an opaque call without a summary.
    // The order grows while it is walked, so discovery is transitive.
    const auto &sources = context.getSourceManager();
    for (std::size_t index = 0; index < cache.order.size(); ++index) {
      const auto &graph = *cache.functions.find(cache.order[index])->second->graph;
      for (const auto *block : graph) {
        for (const auto &element : *block) {
          const auto statement = element.getAs<clang::CFGStmt>();
          if (!statement) {
            continue;
          }
          const clang::FunctionDecl *callee = nullptr;
          if (const auto *call = llvm::dyn_cast<clang::CallExpr>(statement->getStmt())) {
            callee = call->getDirectCallee();
          } else if (const auto *construct = llvm::dyn_cast<clang::CXXConstructExpr>(statement->getStmt())) {
            callee = construct->getConstructor();
          }
          const auto *definition = callee != nullptr ? callee->getDefinition() : nullptr;
          if (definition != nullptr && !cache.functions.contains(definition->getCanonicalDecl()) && !sources.isInSystemHeader(sources.getExpansionLoc(definition->getLocation()))) {
            analyze(*definition, context);
          }
        }
      }
    }

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
