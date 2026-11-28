#include "meta_model.hpp"

#include <cctype>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

  using namespace telar::qt_moc;

  struct StringTable {
    std::vector<std::string> entries;
    std::unordered_map<std::string, int> indices;

    int add(const std::string& text) {
      if (const auto found = indices.find(text); found != indices.end()) {
        return found->second;
      }

      const auto index = static_cast<int>(entries.size());

      entries.push_back(text);
      indices.emplace(text, index);
      return index;
    }
  };

  std::string escapeCpp(const std::string& text) {
    std::string out;

    out.reserve(text.size() + 2);
    for (const char ch : text) {
      switch (ch) {
      case '\\':
        out += "\\\\";
        break;
      case '"':
        out += "\\\"";
        break;
      case '\n':
        out += "\\n";
        break;
      default:
        out += ch;
        break;
      }
    }

    return out;
  }

  std::string builtinMetaType(const std::string& normalized) {
    if (normalized == "void") {
      return "QMetaType::Void";
    }
    if (normalized == "bool") {
      return "QMetaType::Bool";
    }
    if (normalized == "int") {
      return "QMetaType::Int";
    }
    if (normalized == "unsigned int" || normalized == "uint") {
      return "QMetaType::UInt";
    }
    if (normalized == "double") {
      return "QMetaType::Double";
    }
    if (normalized == "qreal") {
      return "QMetaType::QReal";
    }
    if (normalized == "float") {
      return "QMetaType::Float";
    }
    if (normalized == "long long" || normalized == "qlonglong" || normalized == "qint64") {
      return "QMetaType::LongLong";
    }
    if (normalized == "unsigned long long" || normalized == "qulonglong" || normalized == "quint64") {
      return "QMetaType::ULongLong";
    }
    if (normalized == "QString") {
      return "QMetaType::QString";
    }
    if (normalized == "QByteArray") {
      return "QMetaType::QByteArray";
    }
    if (normalized == "QVariant") {
      return "QMetaType::QVariant";
    }
    if (normalized == "QVariantList") {
      return "QMetaType::QVariantList";
    }
    if (normalized == "QVariantMap") {
      return "QMetaType::QVariantMap";
    }
    if (normalized == "QStringList") {
      return "QMetaType::QStringList";
    }
    if (normalized == "QUrl") {
      return "QMetaType::QUrl";
    }
    if (normalized == "QObject*") {
      return "QMetaType::QObjectStar";
    }
    return {};
  }

  std::string typeExpr(StringTable& strings, const std::string& normalized, bool& is_builtin) {
    const auto builtin = builtinMetaType(normalized);
    if (!builtin.empty()) {
      is_builtin = true;
      return builtin;
    }

    is_builtin = false;
    return "0x80000000 | " + std::to_string(strings.add(normalized));
  }

  std::string accessFlag(Access access) {
    switch (access) {
    case Access::public_:
      return "QMC::AccessPublic";
    case Access::protected_:
      return "QMC::AccessProtected";
    case Access::private_:
      return "QMC::AccessPrivate";
    }
  }

  std::string stdSetterName(const std::string& prop_name) {
    if (prop_name.empty()) {
      return {};
    }

    std::string expected = "set";

    expected.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(prop_name[0]))));
    expected.append(prop_name.substr(1));
    return expected;
  }

  std::string sanitizeTag(const std::string& qualified) {
    std::string out = "qt_meta_";

    for (const char ch : qualified) {
      if (std::isalnum(static_cast<unsigned char>(ch))) {
        out.push_back(ch);
      } else {
        out.push_back('_');
      }
    }

    return out;
  }

  std::string methodSignature(const MethodMeta& method) {
    std::string sig = method.return_type + "(";

    for (std::size_t idx = 0; idx < method.params.size(); ++idx) {
      if (idx > 0) {
        sig += ", ";
      }

      sig += method.params[idx].type;
    }

    sig += ")";
    if (method.is_const) {
      sig += " const";
    }

    return sig;
  }

  void emitMethodList(std::ostringstream& out, StringTable& strings, const std::vector<MethodMeta>& methods, const char* helper_name) {
    for (const auto& method : methods) {
      const int name_idx = strings.add(method.name);
      const int empty_idx = strings.add("");
      bool ret_builtin = false;
      const auto ret_expr = typeExpr(strings, method.normalized_return_type, ret_builtin);
      std::string flags = accessFlag(method.access);

      if (method.is_cloned) {
        flags += " | QMC::MethodCloned";
      }

      out << "    QtMocHelpers::" << helper_name << "<" << methodSignature(method) << ">("
          << name_idx << ", " << empty_idx << ", " << flags << ", " << ret_expr;
      if (!method.params.empty()) {
        out << ", {{\n";
        for (std::size_t idx = 0; idx < method.params.size(); ++idx) {
          bool param_builtin = false;
          const auto param_expr = typeExpr(strings, method.params[idx].normalized_type, param_builtin);
          const int param_name_idx = strings.add(method.params[idx].name);

          out << "      { " << param_expr << ", " << param_name_idx << " },\n";
        }

        out << "    }}";
      }

      out << "),\n";
    }
  }

  void emitClass(std::ostringstream& out, const ClassMeta& cls) {
    StringTable strings;

    strings.add(cls.qualified_name);

    std::vector<std::pair<int, int>> class_info_pairs;

    for (const auto& info : cls.class_infos) {
      class_info_pairs.emplace_back(strings.add(info.name), strings.add(info.value));
    }

    std::ostringstream methods_buf;

    emitMethodList(methods_buf, strings, cls.signals, "SignalData");
    emitMethodList(methods_buf, strings, cls.slots, "SlotData");
    emitMethodList(methods_buf, strings, cls.invokables, "MethodData");

    std::ostringstream props_buf;

    for (const auto& prop : cls.properties) {
      const int name_idx = strings.add(prop.name);
      bool builtin = false;
      const auto type_id = typeExpr(strings, prop.string_type, builtin);
      std::string flags = "QMC::DefaultPropertyFlags";

      if (!prop.write.empty()) {
        flags += " | QMC::Writable";
      }

      if (!prop.reset.empty()) {
        flags += " | QMC::Resettable";
      }

      if (prop.constant) {
        flags += " | QMC::Constant";
      }

      if (prop.is_final) {
        flags += " | QMC::Final";
      }

      if (prop.required) {
        flags += " | QMC::Required";
      }

      if (!builtin) {
        flags += " | QMC::EnumOrFlag";
      }

      if (!prop.write.empty() && prop.write == stdSetterName(prop.name)) {
        flags += " | QMC::StdCppSet";
      }

      props_buf << "    QtMocHelpers::PropertyData<" << prop.type << ">("
                << name_idx << ", " << type_id << ", " << flags;
      if (prop.notify_index >= 0) {
        props_buf << ", " << prop.notify_index;
      }

      props_buf << "),\n";
    }

    std::ostringstream enums_buf;

    for (const auto& en : cls.enums) {
      const int name_idx = strings.add(en.name);
      const std::string flags = en.is_scoped ? "QMC::EnumFlags{} | QMC::EnumIsScoped" : "QMC::EnumFlags{}";

      enums_buf << "    QtMocHelpers::EnumData<" << en.qualified_name << ">("
                << name_idx << ", " << name_idx << ", " << flags << ").add({\n";
      for (const auto& val : en.values) {
        const int val_idx = strings.add(val.name);

        enums_buf << "      { " << val_idx << ", " << en.qualified_name << "::" << val.name << " },\n";
      }

      enums_buf << "    }),\n";
    }

    const auto tag = sanitizeTag(cls.qualified_name);

    out << "namespace {\n\n";
    out << "  struct " << tag << "_tag {};\n\n";
    out << "  constexpr auto " << tag << "_create() {\n";
    out << "    namespace QMC = QtMocConstants;\n";
    out << "    QtMocHelpers::StringRefStorage qt_stringData {\n";
    for (std::size_t idx = 0; idx < strings.entries.size(); ++idx) {
      out << "      \"" << escapeCpp(strings.entries[idx]) << "\"";
      if (idx + 1 < strings.entries.size()) {
        out << ",";
      }

      out << "\n";
    }

    out << "    };\n\n";
    out << "    QtMocHelpers::UintData qt_methods {\n"
        << methods_buf.str() << "    };\n";
    out << "    QtMocHelpers::UintData qt_properties {\n"
        << props_buf.str() << "    };\n";
    out << "    QtMocHelpers::UintData qt_enums {\n"
        << enums_buf.str() << "    };\n";
    out << "    QtMocHelpers::UintData qt_constructors {};\n";
    if (class_info_pairs.empty()) {
      out << "    QtMocHelpers::ClassInfos<0> qt_classinfo {};\n";
    } else {
      out << "    QtMocHelpers::ClassInfos qt_classinfo({\n";
      for (const auto& [k, v] : class_info_pairs) {
        out << "      { " << k << ", " << v << " },\n";
      }

      out << "    });\n";
    }

    if (cls.is_namespace) {
      out << "    return QtMocHelpers::metaObjectData<void, " << tag << "_tag>(QMC::PropertyAccessInStaticMetaCall, qt_stringData, qt_methods, qt_properties, qt_enums, qt_constructors, qt_classinfo);\n";
    } else {
      out << "    return QtMocHelpers::metaObjectData<" << cls.qualified_name << ", void>(QMC::MetaObjectFlag{}, qt_stringData, qt_methods, qt_properties, qt_enums, qt_constructors, qt_classinfo);\n";
    }

    out << "  }\n\n";
    out << "  constexpr auto " << tag << "_content = " << tag << "_create();\n";
    out << "  constexpr auto " << tag << "_static = " << tag << "_content.staticData;\n";
    out << "  constexpr auto " << tag << "_relocating = " << tag << "_content.relocatingData;\n\n";
    out << "}\n\n";

    if (cls.is_namespace) {
      out << "constinit const QMetaObject " << cls.qualified_name << "::staticMetaObject = { {\n";
      out << "  nullptr,\n";
      out << "  " << tag << "_static.stringdata,\n";
      out << "  " << tag << "_static.data,\n";
      out << "  nullptr,\n";
      out << "  nullptr,\n";
      out << "  " << tag << "_relocating.metaTypes,\n";
      out << "  nullptr,\n";
      out << "} };\n\n";
      return;
    }

    out << "constinit const QMetaObject " << cls.qualified_name << "::staticMetaObject = { {\n";
    out << "  QMetaObject::SuperData::link<" << cls.super_class << "::staticMetaObject>(),\n";
    out << "  " << tag << "_static.stringdata,\n";
    out << "  " << tag << "_static.data,\n";
    out << "  qt_static_metacall,\n";
    out << "  nullptr,\n";
    out << "  " << tag << "_relocating.metaTypes,\n";
    out << "  nullptr,\n";
    out << "} };\n\n";

    std::vector<const MethodMeta*> all_methods;

    for (const auto& m : cls.signals) {
      all_methods.push_back(&m);
    }
    for (const auto& m : cls.slots) {
      all_methods.push_back(&m);
    }
    for (const auto& m : cls.invokables) {
      all_methods.push_back(&m);
    }

    bool any_method_qobj_param = false;

    for (const auto* m : all_methods) {
      for (const auto& p : m->params) {
        any_method_qobj_param = any_method_qobj_param || p.is_qobject_ptr;
      }
    }

    bool any_prop_qobj_ptr = false;

    for (const auto& prop : cls.properties) {
      any_prop_qobj_ptr = any_prop_qobj_ptr || prop.is_qobject_ptr;
    }

    out << "void " << cls.qualified_name << "::qt_static_metacall(QObject* _o, QMetaObject::Call _c, int _id, void** _a) {\n";
    out << "  auto* _t = static_cast<" << cls.qualified_name << "*>(_o);\n";
    out << "  static_cast<void>(_t);\n";
    out << "  static_cast<void>(_c);\n";
    out << "  static_cast<void>(_id);\n";
    out << "  static_cast<void>(_a);\n";

    if (!all_methods.empty()) {
      out << "  if (_c == QMetaObject::InvokeMetaMethod) {\n";
      out << "    switch (_id) {\n";
      for (std::size_t idx = 0; idx < all_methods.size(); ++idx) {
        const auto& m = *all_methods[idx];

        out << "    case " << idx << ": ";
        if (m.normalized_return_type != "void") {
          out << "{ auto _r = ";
        }

        if (m.is_static) {
          out << cls.qualified_name << "::" << m.name << "(";
        } else {
          out << "_t->" << m.name << "(";
        }

        for (std::size_t p = 0; p < m.params.size(); ++p) {
          if (p > 0) {
            out << ", ";
          }
          out << "(*reinterpret_cast<std::add_pointer_t<" << m.params[p].normalized_type << ">>(_a[" << (p + 1) << "]))";
        }

        if (m.normalized_return_type != "void") {
          out << "); if (_a[0]) *reinterpret_cast<" << m.normalized_return_type << "*>(_a[0]) = std::move(_r); } break;\n";
        } else {
          out << "); break;\n";
        }
      }

      out << "    default: break;\n";
      out << "    }\n";
      out << "  }\n";
    }

    if (any_method_qobj_param) {
      out << "  if (_c == QMetaObject::RegisterMethodArgumentMetaType) {\n";
      out << "    switch (_id) {\n";
      out << "    default: *reinterpret_cast<QMetaType*>(_a[0]) = QMetaType(); break;\n";
      for (std::size_t idx = 0; idx < all_methods.size(); ++idx) {
        const auto& m = *all_methods[idx];
        bool has_ptr = false;

        for (const auto& p : m.params) {
          has_ptr = has_ptr || p.is_qobject_ptr;
        }
        if (!has_ptr) {
          continue;
        }

        out << "    case " << idx << ":\n";
        out << "      switch (*reinterpret_cast<int*>(_a[1])) {\n";
        out << "      default: *reinterpret_cast<QMetaType*>(_a[0]) = QMetaType(); break;\n";
        for (std::size_t p = 0; p < m.params.size(); ++p) {
          if (m.params[p].is_qobject_ptr) {
            out << "      case " << p << ": *reinterpret_cast<QMetaType*>(_a[0]) = QMetaType::fromType<" << m.params[p].normalized_type << ">(); break;\n";
          }
        }

        out << "      }\n";
        out << "      break;\n";
      }

      out << "    }\n";
      out << "  }\n";
    }

    if (!cls.signals.empty()) {
      out << "  if (_c == QMetaObject::IndexOfMethod) {\n";
      for (std::size_t idx = 0; idx < cls.signals.size(); ++idx) {
        const auto& s = cls.signals[idx];
        if (s.is_cloned) {
          continue;
        }

        out << "    if (QtMocHelpers::indexOfMethod<" << s.return_type << " (" << cls.qualified_name << "::*)(";
        for (std::size_t p = 0; p < s.params.size(); ++p) {
          if (p > 0) {
            out << ", ";
          }
          out << s.params[p].type;
        }

        out << ")" << (s.is_const ? " const" : "") << ">(_a, &" << cls.qualified_name << "::" << s.name << ", " << idx << ")) {\n";
        out << "      return;\n";
        out << "    }\n";
      }

      out << "  }\n";
    }

    if (any_prop_qobj_ptr) {
      out << "  if (_c == QMetaObject::RegisterPropertyMetaType) {\n";
      out << "    switch (_id) {\n";
      out << "    default: *reinterpret_cast<int*>(_a[0]) = -1; break;\n";
      for (std::size_t idx = 0; idx < cls.properties.size(); ++idx) {
        if (cls.properties[idx].is_qobject_ptr) {
          out << "    case " << idx << ": *reinterpret_cast<int*>(_a[0]) = qRegisterMetaType<" << cls.properties[idx].type << ">(); break;\n";
        }
      }

      out << "    }\n";
      out << "  }\n";
    }

    if (!cls.properties.empty()) {
      out << "  if (_c == QMetaObject::ReadProperty) {\n";
      out << "    void* _v = _a[0];\n";
      out << "    switch (_id) {\n";
      for (std::size_t idx = 0; idx < cls.properties.size(); ++idx) {
        const auto& prop = cls.properties[idx];

        out << "    case " << idx << ": *reinterpret_cast<" << prop.type << "*>(_v) = _t->" << prop.read << "(); break;\n";
      }

      out << "    default: break;\n";
      out << "    }\n";
      out << "  }\n";

      bool any_write = false;
      bool any_reset = false;

      for (const auto& prop : cls.properties) {
        any_write = any_write || !prop.write.empty();
        any_reset = any_reset || !prop.reset.empty();
      }

      if (any_write) {
        out << "  if (_c == QMetaObject::WriteProperty) {\n";
        out << "    void* _v = _a[0];\n";
        out << "    switch (_id) {\n";
        for (std::size_t idx = 0; idx < cls.properties.size(); ++idx) {
          const auto& prop = cls.properties[idx];
          if (!prop.write.empty()) {
            out << "    case " << idx << ": _t->" << prop.write << "(*reinterpret_cast<" << prop.type << "*>(_v)); break;\n";
          }
        }

        out << "    default: break;\n";
        out << "    }\n";
        out << "  }\n";
      }

      if (any_reset) {
        out << "  if (_c == QMetaObject::ResetProperty) {\n";
        out << "    switch (_id) {\n";
        for (std::size_t idx = 0; idx < cls.properties.size(); ++idx) {
          const auto& prop = cls.properties[idx];
          if (!prop.reset.empty()) {
            out << "    case " << idx << ": _t->" << prop.reset << "(); break;\n";
          }
        }

        out << "    default: break;\n";
        out << "    }\n";
        out << "  }\n";
      }
    }

    out << "}\n\n";

    out << "const QMetaObject* " << cls.qualified_name << "::metaObject() const {\n";
    out << "  return QObject::d_ptr->metaObject ? QObject::d_ptr->dynamicMetaObject() : &staticMetaObject;\n";
    out << "}\n\n";

    out << "void* " << cls.qualified_name << "::qt_metacast(const char* _clname) {\n";
    out << "  if (!_clname) {\n";
    out << "    return nullptr;\n";
    out << "  }\n";
    out << "  if (!std::strcmp(_clname, " << tag << "_static.strings)) {\n";
    out << "    return static_cast<void*>(this);\n";
    out << "  }\n";
    out << "  return " << cls.super_class << "::qt_metacast(_clname);\n";
    out << "}\n\n";

    out << "int " << cls.qualified_name << "::qt_metacall(QMetaObject::Call _c, int _id, void** _a) {\n";
    out << "  _id = " << cls.super_class << "::qt_metacall(_c, _id, _a);\n";
    out << "  if (_id < 0) {\n";
    out << "    return _id;\n";
    out << "  }\n";
    if (!all_methods.empty()) {
      out << "  if (_c == QMetaObject::InvokeMetaMethod) {\n";
      out << "    if (_id < " << all_methods.size() << ") {\n";
      out << "      qt_static_metacall(this, _c, _id, _a);\n";
      out << "    }\n";
      out << "    _id -= " << all_methods.size() << ";\n";
      out << "  }\n";
      out << "  if (_c == QMetaObject::RegisterMethodArgumentMetaType) {\n";
      out << "    if (_id < " << all_methods.size() << ") {\n";
      if (any_method_qobj_param) {
        out << "      qt_static_metacall(this, _c, _id, _a);\n";
      } else {
        out << "      *reinterpret_cast<QMetaType*>(_a[0]) = QMetaType();\n";
      }

      out << "    }\n";
      out << "    _id -= " << all_methods.size() << ";\n";
      out << "  }\n";
    }

    if (!cls.properties.empty()) {
      out << "  if (_c == QMetaObject::ReadProperty || _c == QMetaObject::WriteProperty || _c == QMetaObject::ResetProperty || _c == QMetaObject::BindableProperty || _c == QMetaObject::RegisterPropertyMetaType) {\n";
      out << "    qt_static_metacall(this, _c, _id, _a);\n";
      out << "    _id -= " << cls.properties.size() << ";\n";
      out << "  }\n";
    }

    out << "  return _id;\n";
    out << "}\n\n";

    for (std::size_t idx = 0; idx < cls.signals.size(); ++idx) {
      const auto& sig = cls.signals[idx];
      if (sig.is_cloned) {
        continue;
      }

      out << sig.return_type << " " << cls.qualified_name << "::" << sig.name << "(";
      for (std::size_t p = 0; p < sig.params.size(); ++p) {
        if (p > 0) {
          out << ", ";
        }
        out << sig.params[p].type << " _t" << (p + 1);
      }

      out << ")" << (sig.is_const ? " const" : "") << " {\n";
      if (sig.params.empty()) {
        out << "  QMetaObject::activate(this, &staticMetaObject, " << idx << ", nullptr);\n";
      } else {
        out << "  QMetaObject::activate<void>(this, &staticMetaObject, " << idx << ", nullptr";
        for (std::size_t p = 0; p < sig.params.size(); ++p) {
          out << ", _t" << (p + 1);
        }

        out << ");\n";
      }

      out << "}\n\n";
    }
  }

}

namespace telar::qt_moc {

  std::string primaryModuleName(const std::string& module_name) {
    const auto colon = module_name.find(':');

    return colon == std::string::npos ? module_name : module_name.substr(0, colon);
  }

  std::string emitMocCpp(const UnitMeta& unit, const std::string& qt_module, bool fragment) {
    std::ostringstream out;

    out << "// Generated by telar-moc (Qt 6.12 meta-object revision 69).\n";
    if (!fragment) {
      const auto primary = primaryModuleName(unit.module_name);
      if (!primary.empty()) {
        out << "module " << primary << ";\n\n";
      }

      out << "import std;\n";
      out << "import " << qt_module << ";\n";

      std::unordered_map<std::string, bool> emitted;

      emitted.emplace("std", true);
      emitted.emplace(qt_module, true);
      if (!primary.empty()) {
        emitted.emplace(primary, true);
      }

      for (const auto& mod : unit.imported_modules) {
        if (emitted.emplace(mod, true).second) {
          out << "import " << mod << ";\n";
        }
      }

      out << "\n";
    }

    for (const auto& cls : unit.classes) {
      emitClass(out, cls);
    }

    return out.str();
  }

}
