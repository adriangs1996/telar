#pragma once

#include "telar_base/text/json.hpp"
#include "telar_base/text/utf8.hpp"

namespace telar::runtime {

enum class JsonKind { object,
                      array,
                      string,
                      literal };

template <Allocator Memory>
class JsonNode {
public:
  explicit JsonNode(Memory &memory, JsonKind kind = JsonKind::object)
      : name_(AllocatorRef<char, Memory>{memory}), text_(AllocatorRef<char, Memory>{memory}), children_(AllocatorRef<JsonNode, Memory>{memory}), kind_(kind) {}

  static JsonNode parse(Memory &memory, std::string_view source) {
    validateUtf8(source);
    return fromValue(memory, JsonValue::parse(source, maximum_depth));
  }

  JsonKind kind() const noexcept { return kind_; }
  std::string_view text() const noexcept { return text_; }
  std::span<JsonNode> children() noexcept { return children_; }
  std::span<const JsonNode> children() const noexcept { return children_; }

  JsonNode *find(std::string_view name) noexcept {
    if (kind_ != JsonKind::object) {
      return nullptr;
    }

    const auto found = std::ranges::find_if(children_, [name](const auto &child) { return child.name_ == name; });
    return found == children_.end() ? nullptr : &*found;
  }

  const JsonNode *find(std::string_view name) const noexcept {
    return const_cast<JsonNode *>(this)->find(name);
  }

  JsonNode &ensure(std::string_view name, JsonKind kind) {
    if (kind_ != JsonKind::object) {
      throw std::invalid_argument{"Expected JSON object"};
    }
    if (auto *existing = find(name)) {
      if (existing->kind_ != kind) {
        throw std::invalid_argument{"Unexpected JSON field type"};
      }

      return *existing;
    }

    JsonNode child{memory(), kind};
    child.name_ = name;
    children_.push_back(std::move(child));
    return children_.back();
  }

  void setString(std::string_view name, std::string_view value) {
    auto &child = ensure(name, JsonKind::string);
    child.text_ = value;
  }

  void setLiteral(std::string_view name, std::string_view value) {
    auto &child = ensure(name, JsonKind::literal);
    child.text_ = value;
  }

  void append(JsonNode child) {
    if (kind_ != JsonKind::array) {
      throw std::invalid_argument{"Expected JSON array"};
    }

    children_.push_back(std::move(child));
  }

  void erase(std::size_t index) {
    children_.erase(children_.begin() + index);
  }

  void remove(std::string_view name) {
    std::erase_if(children_, [name](const auto &child) { return child.name_ == name; });
  }

  String<Memory> format() const {
    String<Memory> output{AllocatorRef<char, Memory>{memory()}};
    appendFormatted(output, 0);
    output += '\n';
    return output;
  }

private:
  static constexpr unsigned maximum_depth = 256;
  static constexpr unsigned indentation = 2;

  Memory &memory() const noexcept { return text_.get_allocator().memory(); }

  static JsonNode fromValue(Memory &memory, JsonValue value) {
    const auto encoded = value.encoded();
    const auto kind = encoded.starts_with('{') ? JsonKind::object : encoded.starts_with('[') ? JsonKind::array
                                                                : encoded.starts_with('"')   ? JsonKind::string
                                                                                             : JsonKind::literal;
    JsonNode node{memory, kind};
    if (kind == JsonKind::object) {
      value.eachMember([&](JsonValue key, JsonValue item) {
        auto child = fromValue(memory, item);
        key.string(child.name_);
        node.children_.push_back(std::move(child));
      });

      Vector<std::string_view, Memory> names{AllocatorRef<std::string_view, Memory>{memory}};
      names.reserve(node.children_.size());
      for (const auto &child : node.children_) {
        names.push_back(child.name_);
      }
      std::ranges::sort(names);
      if (std::adjacent_find(names.begin(), names.end()) != names.end()) {
        throw std::invalid_argument{"Duplicate JSON field"};
      }
    } else if (kind == JsonKind::array) {
      value.eachElement([&](JsonValue item) { node.children_.push_back(fromValue(memory, item)); });
    } else if (kind == JsonKind::string) {
      value.string(node.text_);
    } else {
      node.text_ = encoded;
    }

    return node;
  }

  void appendFormatted(String<Memory> &output, unsigned depth) const {
    if (kind_ == JsonKind::string) {
      appendJsonString(output, text_);
      return;
    }
    if (kind_ == JsonKind::literal) {
      output += text_;
      return;
    }

    output += kind_ == JsonKind::object ? '{' : '[';
    for (std::size_t index = 0; index < children_.size(); ++index) {
      output += index == 0 ? "\n" : ",\n";
      output.append((depth + 1) * indentation, ' ');
      const auto &child = children_[index];
      if (kind_ == JsonKind::object) {
        appendJsonString(output, child.name_);
        output += ": ";
      }

      child.appendFormatted(output, depth + 1);
    }
    if (!children_.empty()) {
      output += '\n';
      output.append(depth * indentation, ' ');
    }

    output += kind_ == JsonKind::object ? '}' : ']';
  }

  String<Memory> name_;
  String<Memory> text_;
  Vector<JsonNode, Memory> children_;
  JsonKind kind_;
};

}
