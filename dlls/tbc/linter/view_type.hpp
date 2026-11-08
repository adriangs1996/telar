#ifndef TBC_LINTER_VIEW_TYPE_HPP
#define TBC_LINTER_VIEW_TYPE_HPP

#include <clang/AST/ASTContext.h>
#include <clang/AST/DeclTemplate.h>
#include <clang/AST/ExprCXX.h>
#include <clang/AST/Type.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/SmallPtrSet.h>

namespace tbc_lint {
  struct annotation {
    bool present = false;
    const clang::Type *region = nullptr;
  };

  inline annotation viewAnnotation(clang::QualType type, const clang::ASTContext &context) {
    while (!type.isNull()) {
      if (const auto *specialization = llvm::dyn_cast<clang::TemplateSpecializationType>(type.getTypePtr())) {
        const auto *declaration = specialization->getTemplateName().getAsTemplateDecl();
        if (declaration != nullptr && declaration->getQualifiedNameAsString() == "tbc::view") {
          const auto arguments = specialization->template_arguments();
          const clang::Type *region = nullptr;
          if (arguments.size() > 1 && arguments[1].getKind() == clang::TemplateArgument::Type) {
            region = arguments[1].getAsType().getCanonicalType().getTypePtr();
            const auto *record = region->getAsCXXRecordDecl();
            if (record != nullptr && record->getQualifiedNameAsString() == "tbc::lt::elided") {
              region = nullptr;
            }
          }

          return {.present = true, .region = region};
        }
      }

      const auto desugared = type.getSingleStepDesugaredType(context);
      if (desugared == type) {
        break;
      }

      type = desugared;
    }

    return {};
  }

  inline const clang::FunctionDecl &contractDeclaration(const clang::FunctionDecl &function, const clang::ASTContext &context) {
    const clang::FunctionDecl *selected = &function;
    for (const auto *declaration : function.redecls()) {
      const auto annotation = viewAnnotation(declaration->getDeclaredReturnType(), context);
      if (annotation.region != nullptr) {
        return *declaration;
      }
      if (annotation.present) {
        selected = declaration;
      }
    }
    if (!viewAnnotation(selected->getDeclaredReturnType(), context).present) {
      for (const auto *declaration : function.redecls()) {
        for (const auto *parameter : declaration->parameters()) {
          if (viewAnnotation(parameter->getType(), context).present) {
            return *declaration;
          }
        }
      }
    }
    return *selected;
  }

  inline bool selfRegion(const clang::Type *region) {
    const auto *record = region != nullptr ? region->getAsCXXRecordDecl() : nullptr;
    return record != nullptr && record->getQualifiedNameAsString() == "tbc::lt::self";
  }

  // A field labeled lt::self borrows only its own object.
  inline bool selfBorrowing(const clang::FieldDecl &field) {
    return selfRegion(viewAnnotation(field.getType(), field.getASTContext()).region);
  }

  inline bool staticRegion(const clang::Type *region) {
    const auto *record = region != nullptr ? region->getAsCXXRecordDecl() : nullptr;
    return record != nullptr && record->getQualifiedNameAsString() == "tbc::lt::static_storage";
  }

  // A deduced return type repeats the label of what it returns, which the declaration never stated.
  inline annotation returnAnnotation(const clang::FunctionDecl &function, const clang::ASTContext &context) {
    return viewAnnotation(contractDeclaration(function, context).getDeclaredReturnType(), context);
  }

  inline annotation parameterAnnotation(const clang::ParmVarDecl &parameter, const clang::ASTContext &context) {
    const auto *function = llvm::dyn_cast<clang::FunctionDecl>(parameter.getDeclContext());
    if (function == nullptr) {
      return viewAnnotation(parameter.getType(), context);
    }
    const auto &contract = contractDeclaration(*function, context);
    return viewAnnotation(contract.getParamDecl(parameter.getFunctionScopeIndex())->getType(), context);
  }

  inline const clang::CXXRecordDecl *recordOf(clang::QualType type) {
    return type.getNonReferenceType()->getAsCXXRecordDecl();
  }

  inline bool standardRecord(clang::QualType type) {
    const auto *record = recordOf(type);
    if (record == nullptr) {
      return false;
    }
    const auto *context = record->getDeclContext();
    while (const auto *space = llvm::dyn_cast<clang::NamespaceDecl>(context)) {
      if (space->isStdNamespace()) {
        return true;
      }
      context = space->getParent();
    }

    return false;
  }

  // A record from code the project does not control: the standard library or a system header.
  inline bool libraryRecord(clang::QualType type) {
    const auto *record = recordOf(type);
    if (record == nullptr) {
      return false;
    }
    return standardRecord(type) || record->getASTContext().getSourceManager().isInSystemHeader(record->getLocation());
  }

  inline bool standardType(clang::QualType type, llvm::StringRef name) {
    const auto *record = recordOf(type);
    return record != nullptr && standardRecord(type) && record->getName() == name;
  }

  inline bool rangeView(clang::QualType type);

  inline bool nativeView(clang::QualType type) {
    return standardType(type, "basic_string_view") || standardType(type, "span") || standardType(type, "reference_wrapper") || standardType(type, "initializer_list") || rangeView(type);
  }

  inline bool standardDeclaration(const clang::Decl &declaration) {
    for (const auto *context = declaration.getDeclContext(); context != nullptr; context = context->getParent()) {
      if (context->isStdNamespace()) {
        return true;
      }
    }

    return false;
  }

  // A standard function by its unqualified name; its qualified spelling depends on the library's
  // inline namespace, as libc++'s std::__1::move shows.
  inline bool standardFunction(const clang::FunctionDecl *function, llvm::StringRef name) {
    return function != nullptr && function->getIdentifier() != nullptr && function->getName() == name && standardDeclaration(*function);
  }

  // A standard range adaptor views the range it adapts, as std::views::reverse over a span does: its
  // elements are that range's. One that owns its range, as std::ranges::owning_view does, is not a view.
  inline bool rangeView(clang::QualType type) {
    const auto *specialization = llvm::dyn_cast_or_null<clang::ClassTemplateSpecializationDecl>(type->getAsCXXRecordDecl());
    if (specialization == nullptr || !specialization->hasDefinition() || specialization->getName() == "owning_view" || !standardDeclaration(*specialization)) {
      return false;
    }
    bool adaptor = false;
    specialization->getDefinition()->forallBases([&](const clang::CXXRecordDecl *base) {
      adaptor = adaptor || (base->getName() == "view_interface" && standardDeclaration(*base));
      return true;
    });
    if (!adaptor) {
      return false;
    }
    if (specialization->getName() == "ref_view") {
      return true;
    }
    for (const auto &argument : specialization->getTemplateArgs().asArray()) {
      if (argument.getKind() == clang::TemplateArgument::Type && nativeView(argument.getAsType())) {
        return true;
      }
    }
    return false;
  }

  inline bool sameType(clang::QualType left, clang::QualType right) {
    return left.getNonReferenceType().getCanonicalType().getUnqualifiedType() == right.getNonReferenceType().getCanonicalType().getUnqualifiedType();
  }

  // Whether one of a record's member typedefs names a type.
  inline bool namesMemberType(clang::QualType owner, std::initializer_list<const char *> names, clang::QualType type) {
    const auto *record = recordOf(owner);
    if (record == nullptr || record->getDefinition() == nullptr) {
      return false;
    }
    auto &identifiers = record->getASTContext().Idents;
    for (const char *name : names) {
      for (const auto *declaration : record->getDefinition()->lookup(&identifiers.get(name))) {
        const auto *alias = llvm::dyn_cast<clang::TypedefNameDecl>(declaration);
        if (alias != nullptr && sameType(alias->getUnderlyingType(), type)) {
          return true;
        }
      }
    }

    return false;
  }

  // Whether a range's iterators or pointers have a given type, using the standard container typedefs.
  inline bool yields(const clang::Expr &argument, clang::QualType result) {
    const auto range = argument.getType().getNonReferenceType();
    if (const auto *array = range->getAsArrayTypeUnsafe()) {
      return result->isPointerType() && sameType(result->getPointeeType(), array->getElementType());
    }
    return namesMemberType(range, {"iterator", "const_iterator", "reverse_iterator", "const_reverse_iterator", "pointer", "const_pointer"}, result);
  }

  // Whether a type is one of a container's own iterators, as the position an insertion takes.
  inline bool positionIn(clang::QualType container, clang::QualType type) {
    return namesMemberType(container, {"iterator", "const_iterator"}, type);
  }

  inline bool declaresMember(clang::QualType type, llvm::StringRef name) {
    const auto *record = recordOf(type);
    if (record == nullptr || record->getDefinition() == nullptr) {
      return false;
    }
    return !record->getDefinition()->lookup(&record->getASTContext().Idents.get(name)).empty();
  }

  // A standard smart pointer, recognized by its element_type.
  inline bool smartPointer(clang::QualType type) {
    return standardRecord(type) && !nativeView(type) && declaresMember(type, "element_type");
  }

  // A smart pointer that cannot be copied is the only owner of its object, so resetting it destroys the object.
  inline bool uniqueOwner(clang::QualType type) {
    if (!smartPointer(type)) {
      return false;
    }
    for (const auto *constructor : recordOf(type)->getDefinition()->ctors()) {
      if (constructor->isCopyConstructor() && constructor->isDeleted()) {
        return true;
      }
    }

    return false;
  }

  // Moving a smart pointer or an allocator-aware container hands its allocation to the destination.
  // A string is excluded: its small-buffer storage does not move with it.
  inline clang::QualType memberType(clang::QualType owner, llvm::StringRef name);

  inline bool transfersAllocation(clang::QualType type) {
    if (standardType(type, "optional")) {
      // An optional owner hands over what the owner it holds owns.
      const auto value = memberType(type, "value_type");
      return !value.isNull() && transfersAllocation(value);
    }
    return smartPointer(type) || (standardRecord(type) && !standardType(type, "basic_string") && declaresMember(type, "allocator_type"));
  }

  // A record's member typedef.
  inline clang::QualType memberType(clang::QualType owner, llvm::StringRef name) {
    const auto *record = recordOf(owner);
    if (record == nullptr || record->getDefinition() == nullptr) {
      return {};
    }
    for (const auto *declaration : record->getDefinition()->lookup(&record->getASTContext().Idents.get(name))) {
      if (const auto *alias = llvm::dyn_cast<clang::TypedefNameDecl>(declaration)) {
        return alias->getUnderlyingType();
      }
    }

    return {};
  }

  // A container's element type, from its value_type typedef.
  inline clang::QualType elementType(clang::QualType container) {
    return memberType(container, "value_type");
  }

  // A standard iterator designates elements it does not own, like a pointer.
  inline bool iteratorRecord(clang::QualType type) {
    const auto *record = recordOf(type);
    if (record == nullptr || !libraryRecord(type) || record->getDefinition() == nullptr) {
      return false;
    }
    auto &category = record->getASTContext().Idents.get("iterator_category");
    return !record->getDefinition()->lookup(&category).empty();
  }

  inline bool pointerLike(clang::QualType type) {
    type = type.getNonReferenceType();
    return type->isPointerType() || iteratorRecord(type);
  }

  // A result that designates storage, alone or paired as std::map::insert returns it.
  inline bool pointsIntoStorage(clang::QualType type) {
    type = type.getNonReferenceType();
    if (pointerLike(type)) {
      return true;
    }
    const auto *pair = llvm::dyn_cast_or_null<clang::ClassTemplateSpecializationDecl>(recordOf(type));
    if (pair == nullptr || !standardType(type, "pair")) {
      return false;
    }
    for (const auto &argument : pair->getTemplateArgs().asArray()) {
      if (argument.getKind() == clang::TemplateArgument::Type && pointerLike(argument.getAsType())) {
        return true;
      }
    }

    return false;
  }

  // Whether a standard wrapper converts an owning argument into a view element, as
  // std::optional<std::string_view>{text} does. Pairs and tuples map arguments by position.
  inline bool viewsInto(const clang::CXXConstructExpr &construction, unsigned index) {
    const auto wrapper = construction.getType();
    const auto count = construction.getNumArgs();
    const auto argument = construction.getArg(index)->getType().getNonReferenceType();
    // The owners that standard views are built from: string_view from strings, span from arrays and vectors.
    const bool owner = argument->isArrayType() || standardType(argument, "basic_string") || standardType(argument, "vector") || standardType(argument, "array");
    const auto *specialization = llvm::dyn_cast_or_null<clang::ClassTemplateSpecializationDecl>(recordOf(wrapper));
    if (!owner || specialization == nullptr) {
      return false;
    }
    llvm::SmallVector<clang::QualType, 4> elements;
    for (const auto &template_argument : specialization->getTemplateArgs().asArray()) {
      if (template_argument.getKind() == clang::TemplateArgument::Pack) {
        for (const auto &element : template_argument.pack_elements()) {
          elements.push_back(element.getAsType());
        }
      } else if (template_argument.getKind() == clang::TemplateArgument::Type) {
        elements.push_back(template_argument.getAsType());
      }
    }
    const bool positional = (standardType(wrapper, "pair") || standardType(wrapper, "tuple")) && elements.size() == count;
    for (unsigned element = 0; element < elements.size(); ++element) {
      if ((!positional || element == index) && (nativeView(elements[element]) || elements[element]->isPointerType())) {
        return true;
      }
    }

    return false;
  }

  inline bool containsViews(clang::QualType type, llvm::SmallPtrSetImpl<const clang::Type *> &seen);
  inline bool containsViews(clang::QualType type);

  // A library type that releases memory in its destructor owns it. One with a trivial destructor cannot,
  // so whatever it points to is borrowed. Standard types keep their own models.
  inline bool libraryOwner(clang::QualType type) {
    const auto *record = recordOf(type);
    if (record == nullptr || !libraryRecord(type)) {
      return false;
    }
    return standardRecord(type) || record->getDefinition() == nullptr || !record->getDefinition()->hasTrivialDestructor();
  }

  inline bool libraryView(clang::QualType type) {
    return libraryRecord(type) && !libraryOwner(type) && !iteratorRecord(type) && containsViews(type);
  }

  inline bool viewType(clang::QualType type) {
    return nativeView(type) || libraryView(type);
  }

  inline bool templateHoldsViews(llvm::ArrayRef<clang::TemplateArgument> arguments, llvm::SmallPtrSetImpl<const clang::Type *> &seen) {
    for (const auto &argument : arguments) {
      if (argument.getKind() == clang::TemplateArgument::Pack && templateHoldsViews(argument.pack_elements(), seen)) {
        return true;
      }
      if (argument.getKind() == clang::TemplateArgument::Type && containsViews(argument.getAsType(), seen)) {
        return true;
      }
    }

    return false;
  }

  inline bool containsViews(clang::QualType type, llvm::SmallPtrSetImpl<const clang::Type *> &seen) {
    if (type->isReferenceType()) {
      return true;
    }
    type = type.getCanonicalType();
    if (!seen.insert(type.getTypePtr()).second) {
      return false;
    }
    if (nativeView(type) || type->isPointerType()) {
      return true;
    }
    if (standardType(type, "basic_string")) {
      return false;
    }
    if (const auto *array = llvm::dyn_cast<clang::ArrayType>(type.getTypePtr())) {
      return containsViews(array->getElementType(), seen);
    }
    if (const auto *record = recordOf(type)) {
      if (libraryRecord(type)) {
        if (iteratorRecord(type)) {
          return true;
        }
        // A library owner holds views only through its type arguments. A std::function can hold any
        // callable, so it keeps whatever the callable it wraps borrows.
        if (libraryOwner(type)) {
          // Outside the standard library, only a container is known to hold its type arguments.
          const auto *specialization = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(record);
          const bool holds = standardRecord(type) || declaresMember(type, "value_type");
          return specialization != nullptr && holds && (standardType(type, "function") || templateHoldsViews(specialization->getTemplateArgs().asArray(), seen));
        }
      }
      if (const auto *definition = record->getDefinition()) {
        for (const auto *field : definition->fields()) {
          if (!selfBorrowing(*field) && containsViews(field->getType(), seen)) {
            return true;
          }
        }
        for (const auto &base : definition->bases()) {
          if (containsViews(base.getType(), seen)) {
            return true;
          }
        }
      }
    }

    return false;
  }

  inline bool containsViews(clang::QualType type) {
    llvm::SmallPtrSet<const clang::Type *, 16> seen;
    return containsViews(type, seen);
  }

  // The type of what a value designates: a pointer's or a reference's pointee, a smart pointer's
  // element, a view's or an iterator's elements, or what a container's elements designate. Null where
  // the type designates nothing known.
  inline clang::QualType designatedType(clang::QualType type) {
    if (type->isReferenceType() || type->isPointerType()) {
      return type->getPointeeType();
    }
    if (smartPointer(type)) {
      return memberType(type, "element_type");
    }
    if (standardType(type, "reference_wrapper")) {
      return memberType(type, "type");
    }
    if (nativeView(type) || iteratorRecord(type)) {
      return elementType(type);
    }
    const auto element = elementType(type);
    return element.isNull() ? clang::QualType{} : designatedType(element);
  }

  // Moving an object of this type leaves everything it owns where it is. A string does not qualify:
  // its small-buffer storage moves with it. Other library types are assumed to own storage inline.
  inline bool ownsNothingInline(clang::QualType type) {
    type = type.getCanonicalType();
    if (type->isReferenceType() || type->isScalarType() || viewType(type) || transfersAllocation(type)) {
      return true;
    }
    if (const auto *array = llvm::dyn_cast<clang::ConstantArrayType>(type.getTypePtr())) {
      return ownsNothingInline(array->getElementType());
    }
    const auto *record = recordOf(type);
    if (record == nullptr || libraryRecord(type) || record->getDefinition() == nullptr) {
      return false;
    }
    for (const auto *field : record->getDefinition()->fields()) {
      if (!ownsNothingInline(field->getType())) {
        return false;
      }
    }
    for (const auto &base : record->getDefinition()->bases()) {
      if (!ownsNothingInline(base.getType())) {
        return false;
      }
    }

    return true;
  }
}

#endif
