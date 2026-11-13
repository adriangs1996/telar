#include "interface_bodies.hpp"

#include <clang/AST/ASTContext.h>
#include <clang/AST/Attr.h>
#include <clang/AST/Decl.h>
#include <clang/AST/DeclCXX.h>
#include <clang/AST/DeclFriend.h>
#include <clang/AST/DeclTemplate.h>
#include <clang/AST/ExprCXX.h>
#include <clang/Basic/Diagnostic.h>
#include <clang/Basic/Module.h>
#include <clang/Basic/SourceManager.h>
#include <llvm/ADT/STLExtras.h>
#include <llvm/ADT/SmallVector.h>
#include <llvm/Support/MemoryBuffer.h>

#include <cstdint>

namespace tbc_lint {
  namespace {
    enum class violation : std::uint8_t {
      body,
      not_inline,
    };

    struct body {
      clang::SourceLocation location;
      violation kind;
    };

    bool annotated(const clang::Decl &declaration) {
      return llvm::any_of(declaration.redecls(), [](const clang::Decl *redeclaration) {
        return llvm::any_of(redeclaration->specific_attrs<clang::AnnotateAttr>(), [](const clang::AnnotateAttr *attribute) {
          return attribute->getAnnotation() == "tbc::hot_path";
        });
      });
    }

    // A class marked as a hot path covers its members, and a class template covers its specializations.
    bool insideMarkedClass(const clang::DeclContext *context, bool lexical) {
      for (; context != nullptr; context = lexical ? context->getLexicalParent() : context->getParent()) {
        const auto *record = llvm::dyn_cast<clang::CXXRecordDecl>(context);
        if (record == nullptr) {
          continue;
        }

        if (annotated(*record)) {
          return true;
        }

        const auto *specialization = llvm::dyn_cast<clang::ClassTemplateSpecializationDecl>(record);
        if (specialization != nullptr && annotated(*specialization->getSpecializedTemplate()->getTemplatedDecl())) {
          return true;
        }
      }

      return false;
    }

    // The semantic parents reach the class of a member defined outside it; the lexical ones, the class
    // that defines a friend.
    bool marked(const clang::Decl &declaration) {
      return annotated(declaration) || insideMarkedClass(declaration.getDeclContext(), false) || insideMarkedClass(declaration.getLexicalDeclContext(), true);
    }

    // Collects the bodies a module interface unit keeps in its purview. A body's local classes and
    // lambdas belong to it, so the walk never enters one.
    class interface_walk {
    public:
      interface_walk(const clang::SourceManager &sources, llvm::SmallVectorImpl<body> &bodies)
          : sources_(sources),
            bodies_(bodies) {}

      // Walks only the declarations this unit parsed, so that nothing imported is loaded.
      void walk(const clang::DeclContext &context) {
        for (const auto *declaration : context.noload_decls()) {
          visit(*declaration);
        }
      }

    private:
      // The global module fragment holds what headers declare, and the private module fragment is no
      // part of the interface.
      [[nodiscard]] bool inPurview(const clang::Decl &declaration) const {
        const auto *owner = declaration.getOwningModule();

        return owner != nullptr && owner->isNamedModule() && owner->Kind != clang::Module::PrivateModuleFragment && !sources_.isInSystemHeader(declaration.getLocation());
      }

      void visit(const clang::Decl &declaration) {
        if (declaration.isFromASTFile() || declaration.isImplicit() || !inPurview(declaration)) {
          return;
        }

        if (const auto *function = llvm::dyn_cast<clang::FunctionDecl>(&declaration)) {
          check(*function);
        } else if (const auto *pattern = llvm::dyn_cast<clang::FunctionTemplateDecl>(&declaration)) {
          check(*pattern->getTemplatedDecl());
        } else if (const auto *class_pattern = llvm::dyn_cast<clang::ClassTemplateDecl>(&declaration)) {
          visit(*class_pattern->getTemplatedDecl());
        } else if (const auto *variable_pattern = llvm::dyn_cast<clang::VarTemplateDecl>(&declaration)) {
          visit(*variable_pattern->getTemplatedDecl());
        } else if (const auto *variable = llvm::dyn_cast<clang::VarDecl>(&declaration)) {
          lambdas(variable->getInit(), *variable);
        } else if (const auto *field = llvm::dyn_cast<clang::FieldDecl>(&declaration)) {
          lambdas(field->getInClassInitializer(), *field);
        } else if (const auto *friendship = llvm::dyn_cast<clang::FriendDecl>(&declaration)) {
          if (const auto *befriended = friendship->getFriendDecl()) {
            visit(*befriended);
          }
        } else if (const auto *record = llvm::dyn_cast<clang::CXXRecordDecl>(&declaration)) {
          if (record->getTemplateSpecializationKind() != clang::TSK_ImplicitInstantiation) {
            walk(*record);
          }
        } else if (const auto *context = llvm::dyn_cast<clang::DeclContext>(&declaration)) {
          walk(*context);
        }
      }

      // Constexpr and consteval bodies are what importers evaluate, so they belong to the interface. A
      // marked template reaches importers as it is; any other marked function only when it is inline.
      void check(const clang::FunctionDecl &function) {
        if (!function.doesThisDeclarationHaveABody() || function.isDefaulted() || function.isDeleted() || function.isConstexpr()) {
          return;
        }

        if (function.getTemplateSpecializationKind() == clang::TSK_ImplicitInstantiation) {
          return;
        }

        const auto *primary = function.getPrimaryTemplate();
        const auto hot = marked(function) || (primary != nullptr && annotated(*primary->getTemplatedDecl()));
        if (!hot) {
          bodies_.push_back(body{.location = function.getLocation(), .kind = violation::body});
        } else if (!function.isTemplated() && !function.isInlined()) {
          bodies_.push_back(body{.location = function.getLocation(), .kind = violation::not_inline});
        }
      }

      // A lambda that initializes a variable or a field is a body of its own. One of a constexpr variable
      // that importers can evaluate stays, as a constexpr function does.
      void lambdas(const clang::Stmt *statement, const clang::DeclaratorDecl &owner) {
        if (statement == nullptr) {
          return;
        }

        if (const auto *lambda = llvm::dyn_cast<clang::LambdaExpr>(statement)) {
          const auto *variable = llvm::dyn_cast<clang::VarDecl>(&owner);
          const auto evaluated = variable != nullptr && variable->isConstexpr() && lambda->getCallOperator()->isConstexpr();
          if (!evaluated && !marked(owner)) {
            bodies_.push_back(body{.location = lambda->getBeginLoc(), .kind = violation::body});
          }

          return;
        }

        for (const auto *child : statement->children()) {
          lambdas(child, owner);
        }
      }

      const clang::SourceManager &sources_;
      llvm::SmallVectorImpl<body> &bodies_;
    };

    bool moduleName(llvm::StringRef name) {
      llvm::SmallVector<llvm::StringRef, 8> parts;

      name.split(parts, '.');

      return llvm::all_of(parts, [](llvm::StringRef part) {
        return !part.empty() && !llvm::isDigit(part.front()) && llvm::all_of(part, [](char character) {
          return llvm::isAlnum(character) || character == '_';
        });
      });
    }
  }

  llvm::Expected<llvm::StringSet<>> readInterfaceAllowlist(llvm::StringRef path) {
    auto buffer = llvm::MemoryBuffer::getFile(path, /*IsText=*/true);
    if (!buffer) {
      return llvm::createStringError(buffer.getError(), "cannot read " + path + ": " + buffer.getError().message());
    }

    llvm::StringSet<> modules;
    llvm::SmallVector<llvm::StringRef, 128> lines;

    (*buffer)->getBuffer().split(lines, '\n');

    for (std::size_t index = 0; index < lines.size(); ++index) {
      const auto line = lines[index].trim();
      if (line.empty() || line.starts_with("#")) {
        continue;
      }

      if (!moduleName(line)) {
        return llvm::createStringError(std::make_error_code(std::errc::invalid_argument), path + ":" + llvm::Twine(index + 1) + ": '" + line + "' is not a module name");
      }

      modules.insert(line);
    }

    return modules;
  }

  interface_modules::interface_modules(llvm::StringSet<> allowed)
      : allowed_(std::move(allowed)) {}

  bool interface_modules::allowed(llvm::StringRef module) const {
    return allowed_.contains(module);
  }

  void interface_modules::record(llvm::StringRef module, unsigned bodies) {
    const std::scoped_lock lock(mutex_);

    bodies_[module] += bodies;
  }

  bool interface_modules::reportStale(llvm::raw_ostream &output, bool errors, llvm::StringRef allowlist) const {
    const std::scoped_lock lock(mutex_);
    llvm::SmallVector<llvm::StringRef, 8> stale;

    for (const auto &module : bodies_) {
      if (module.getValue() == 0 && allowed(module.getKey())) {
        stale.push_back(module.getKey());
      }
    }

    llvm::sort(stale);

    for (const auto module : stale) {
      output << allowlist << ": " << (errors ? "error" : "warning") << ": module '" << module << "' keeps no function body in its interfaces; remove it from the allowlist [tbc-interface-body]\n";
    }

    return !stale.empty();
  }

  interface_body_check::interface_body_check(interface_modules &modules, bool errors)
      : modules_(modules),
        errors_(errors) {}

  void interface_body_check::HandleTranslationUnit(clang::ASTContext &context) {
    const auto *unit = context.getCurrentNamedModule();
    if (unit == nullptr || !unit->isModuleInterfaceUnit()) {
      return;
    }

    // An invalid unit has an incomplete AST, so its declarations are not what the author wrote.
    auto &diagnostics = context.getDiagnostics();
    if (diagnostics.hasErrorOccurred()) {
      return;
    }

    llvm::SmallVector<body, 16> bodies;

    interface_walk(context.getSourceManager(), bodies).walk(*context.getTranslationUnitDecl());

    const auto module = unit->getPrimaryModuleInterfaceName();

    modules_.record(module, static_cast<unsigned>(bodies.size()));

    if (modules_.allowed(module)) {
      return;
    }

    const auto severity = errors_ ? clang::DiagnosticsEngine::Error : clang::DiagnosticsEngine::Warning;
    const auto in_interface = diagnostics.getCustomDiagID(severity, "function body in the interface of module '%0'; define it in an implementation unit, or mark a hot path TBC_HOT_PATH [tbc-interface-body]");
    const auto not_inline = diagnostics.getCustomDiagID(severity, "hot path in the interface of module '%0' is not inline, so importers cannot inline its body [tbc-interface-body]");

    for (const auto &found : bodies) {
      diagnostics.Report(found.location, found.kind == violation::body ? in_interface : not_inline) << module;
    }
  }
}
