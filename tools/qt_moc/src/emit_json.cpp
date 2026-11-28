#include "meta_model.hpp"

#include <sstream>
#include <string>

namespace {

  using namespace telar::qt_moc;

  std::string jsonEscape(const std::string& text) {
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

  const char* accessName(Access access) {
    switch (access) {
    case Access::public_:
      return "public";
    case Access::protected_:
      return "protected";
    case Access::private_:
      return "private";
    }
  }

  void emitMethodArray(std::ostringstream& out, const char* key, const std::vector<MethodMeta>& methods, int base_index, bool& need_comma) {
    if (methods.empty()) {
      return;
    }

    if (need_comma) {
      out << ",\n";
    }
    need_comma = true;
    out << "        \"" << key << "\": [\n";
    for (std::size_t idx = 0; idx < methods.size(); ++idx) {
      const auto& m = methods[idx];

      out << "          {\n";
      out << "            \"access\": \"" << accessName(m.access) << "\",\n";
      if (!m.params.empty()) {
        out << "            \"arguments\": [\n";
        for (std::size_t p = 0; p < m.params.size(); ++p) {
          out << "              {\"name\": \"" << jsonEscape(m.params[p].name) << "\", \"type\": \"" << jsonEscape(m.params[p].normalized_type) << "\"}";
          if (p + 1 < m.params.size()) {
            out << ",";
          }
          out << "\n";
        }

        out << "            ],\n";
      }

      if (m.is_cloned) {
        out << "            \"isCloned\": true,\n";
      }

      out << "            \"index\": " << (base_index + static_cast<int>(idx)) << ",\n";
      out << "            \"lineNumber\": " << m.line << ",\n";
      out << "            \"name\": \"" << jsonEscape(m.name) << "\",\n";
      out << "            \"returnType\": \"" << jsonEscape(m.normalized_return_type) << "\"\n";
      out << "          }";
      if (idx + 1 < methods.size()) {
        out << ",";
      }
      out << "\n";
    }

    out << "        ]";
  }

}

namespace telar::qt_moc {

  std::string emitMetatypesJson(const UnitMeta& unit) {
    std::ostringstream out;

    out << "[\n";
    out << "  {\n";
    out << "    \"classes\": [\n";
    for (std::size_t ci = 0; ci < unit.classes.size(); ++ci) {
      const auto& cls = unit.classes[ci];
      bool need_comma = false;

      out << "      {\n";
      if (!cls.class_infos.empty()) {
        out << "        \"classInfos\": [\n";
        for (std::size_t i = 0; i < cls.class_infos.size(); ++i) {
          out << "          {\"name\": \"" << jsonEscape(cls.class_infos[i].name) << "\", \"value\": \"" << jsonEscape(cls.class_infos[i].value) << "\"}";
          if (i + 1 < cls.class_infos.size()) {
            out << ",";
          }
          out << "\n";
        }

        out << "        ]";
        need_comma = true;
      }

      if (need_comma) {
        out << ",\n";
      }
      out << "        \"className\": \"" << jsonEscape(cls.class_name) << "\"";
      need_comma = true;

      if (!cls.enums.empty()) {
        out << ",\n        \"enums\": [\n";
        for (std::size_t ei = 0; ei < cls.enums.size(); ++ei) {
          const auto& en = cls.enums[ei];

          out << "          {\n";
          out << "            \"isClass\": " << (en.is_scoped ? "true" : "false") << ",\n";
          out << "            \"isFlag\": false,\n";
          out << "            \"lineNumber\": " << en.line << ",\n";
          out << "            \"name\": \"" << jsonEscape(en.name) << "\",\n";
          out << "            \"type\": \"" << jsonEscape(en.underlying_type) << "\",\n";
          out << "            \"values\": [";
          for (std::size_t vi = 0; vi < en.values.size(); ++vi) {
            if (vi > 0) {
              out << ", ";
            }
            out << "\"" << jsonEscape(en.values[vi].name) << "\"";
          }

          out << "]\n";
          out << "          }";
          if (ei + 1 < cls.enums.size()) {
            out << ",";
          }
          out << "\n";
        }

        out << "        ]";
      }

      out << ",\n        \"lineNumber\": " << cls.line;
      if (cls.is_namespace) {
        out << ",\n        \"namespace\": true";
      } else {
        out << ",\n        \"object\": true";
      }

      if (!cls.properties.empty()) {
        out << ",\n        \"properties\": [\n";
        for (std::size_t pi = 0; pi < cls.properties.size(); ++pi) {
          const auto& p = cls.properties[pi];

          out << "          {\n";
          out << "            \"constant\": " << (p.constant ? "true" : "false") << ",\n";
          out << "            \"designable\": true,\n";
          out << "            \"final\": " << (p.is_final ? "true" : "false") << ",\n";
          out << "            \"index\": " << pi << ",\n";
          out << "            \"lineNumber\": " << p.line << ",\n";
          out << "            \"name\": \"" << jsonEscape(p.name) << "\",\n";
          if (!p.notify.empty()) {
            out << "            \"notify\": \"" << jsonEscape(p.notify) << "\",\n";
          }

          out << "            \"override\": false,\n";
          out << "            \"read\": \"" << jsonEscape(p.read) << "\",\n";
          out << "            \"required\": " << (p.required ? "true" : "false") << ",\n";
          if (!p.reset.empty()) {
            out << "            \"reset\": \"" << jsonEscape(p.reset) << "\",\n";
          }

          out << "            \"scriptable\": true,\n";
          out << "            \"stored\": true,\n";
          out << "            \"type\": \"" << jsonEscape(p.string_type) << "\",\n";
          out << "            \"user\": false,\n";
          out << "            \"virtual\": false";
          if (!p.write.empty()) {
            out << ",\n            \"write\": \"" << jsonEscape(p.write) << "\"";
          }

          out << "\n          }";
          if (pi + 1 < cls.properties.size()) {
            out << ",";
          }
          out << "\n";
        }

        out << "        ]";
      }

      out << ",\n        \"qualifiedClassName\": \"" << jsonEscape(cls.qualified_name) << "\"";
      emitMethodArray(out, "signals", cls.signals, 0, need_comma);
      emitMethodArray(out, "slots", cls.slots, static_cast<int>(cls.signals.size()), need_comma);
      emitMethodArray(out, "methods", cls.invokables, static_cast<int>(cls.signals.size() + cls.slots.size()), need_comma);
      if (!cls.super_class.empty()) {
        out << ",\n        \"superClasses\": [{\"access\": \"public\", \"name\": \"" << jsonEscape(cls.super_class) << "\"}]";
      }

      out << "\n      }";
      if (ci + 1 < unit.classes.size()) {
        out << ",";
      }
      out << "\n";
    }

    out << "    ],\n";
    out << "    \"inputFile\": \"" << jsonEscape(unit.input_file) << "\",\n";
    out << "    \"outputRevision\": 69\n";
    out << "  }\n";
    out << "]\n";
    return out.str();
  }

  std::string mergeMetatypesJson(const std::vector<std::string>& json_texts) {
    std::ostringstream out;
    bool first = true;

    out << "[\n";
    for (const auto& text : json_texts) {
      const auto open = text.find('{');
      const auto close = text.rfind('}');
      if (open == std::string::npos || close == std::string::npos || close <= open) {
        continue;
      }

      if (!first) {
        out << ",\n";
      }

      first = false;
      out << text.substr(open, close - open + 1);
    }

    out << "\n]\n";
    return out.str();
  }

}
