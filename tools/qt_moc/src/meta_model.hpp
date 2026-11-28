#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace telar::qt_moc {

  enum class Access : std::uint8_t {
    public_,
    protected_,
    private_,
  };

  enum class MethodKind : std::uint8_t {
    signal,
    slot,
    invokable,
  };

  struct ParamMeta {
    std::string name;
    std::string type;
    std::string normalized_type;
    bool is_qobject_ptr = false;
  };

  struct MethodMeta {
    MethodKind kind = MethodKind::signal;
    Access access = Access::public_;
    std::string name;
    std::string return_type;
    std::string normalized_return_type;
    std::vector<ParamMeta> params;
    bool is_const = false;
    bool is_static = false;
    bool is_cloned = false;
    unsigned line = 0;
  };

  struct PropertyMeta {
    std::string name;
    std::string type;
    std::string normalized_type;
    std::string string_type;
    std::string read;
    std::string write;
    std::string notify;
    std::string reset;
    int notify_index = -1;
    bool constant = false;
    bool is_final = false;
    bool required = false;
    bool is_qobject_ptr = false;
    bool is_enum_or_flag = false;
    unsigned line = 0;
  };

  struct EnumeratorMeta {
    std::string name;
    std::int64_t value = 0;
  };

  struct EnumMeta {
    std::string name;
    std::string qualified_name;
    std::string underlying_type;
    bool is_scoped = true;
    std::vector<EnumeratorMeta> values;
    unsigned line = 0;
  };

  struct ClassInfoMeta {
    std::string name;
    std::string value;
  };

  struct ClassMeta {
    std::string module_name;
    std::string class_name;
    std::string qualified_name;
    std::string super_class;
    bool is_namespace = false;
    bool qml_exposed = false;
    bool inherits_quick_item = false;
    unsigned line = 0;
    std::vector<ClassInfoMeta> class_infos;
    std::vector<MethodMeta> signals;
    std::vector<MethodMeta> slots;
    std::vector<MethodMeta> invokables;
    std::vector<PropertyMeta> properties;
    std::vector<EnumMeta> enums;
  };

  struct UnitMeta {
    std::string input_file;
    std::string module_name;
    std::vector<std::string> imported_modules;
    std::vector<ClassMeta> classes;
    std::vector<std::string> errors;
  };

  std::string primaryModuleName(const std::string& module_name);
  std::string escapeString(std::string_view text);
  std::string emitMocCpp(const UnitMeta& unit, const std::string& qt_module, bool fragment);
  std::string emitMetatypesJson(const UnitMeta& unit);
  std::string mergeMetatypesJson(const std::vector<std::string>& json_texts);
  std::string emitQmlMeta(const UnitMeta& unit);
  std::string emitQmlRegistrations(const std::vector<UnitMeta>& units, const std::string& qt_module, const std::string& uri, int major, int minor);
  UnitMeta parseQmlMeta(const std::string& text);

}
