#pragma once

#include "../../text/json.hpp"

namespace telar::runtime::cli::hooks {

template <Allocator Memory>
class Object {
public:
  explicit Object(Memory &memory, JsonValue value, bool reject_duplicates = false)
      : memory_(memory), members_(AllocatorRef<Member, Memory>{memory}), reject_duplicates_(reject_duplicates) {
    if (!value.encoded().starts_with('{')) {
      throw std::invalid_argument{"Expected hook object"};
    }

    value.eachMember([&](JsonValue key, JsonValue entry) {
      String<Memory> name{AllocatorRef<char, Memory>{memory_}};
      key.string(name);
      members_.push_back(Member{.name = std::move(name), .value = entry, .text = std::nullopt, .position = members_.size()});
    });

    indexMembers();
  }

  std::optional<JsonValue> value(std::string_view name) const {
    const auto *member = find(name);
    if (member != nullptr) {
      checkUnique(*member);
    }
    return member == nullptr ? std::nullopt : std::optional{member->value};
  }

  std::optional<std::string_view> optionalText(std::string_view name) {
    auto *member = find(name);
    if (member == nullptr) {
      return std::nullopt;
    }

    checkUnique(*member);
    if (member->value.encoded() == "null") {
      return std::nullopt;
    }

    return decode(*member);
  }

  std::string_view text(std::string_view name) {
    auto *member = find(name);
    return member == nullptr ? std::string_view{} : decode(*member);
  }

  std::optional<std::string_view> stringField(std::string_view name) {
    const auto field = value(name);
    return field && field->encoded().starts_with('"') ? optionalText(name) : std::nullopt;
  }

  std::optional<bool> boolean(std::string_view name) const {
    const auto field = value(name);
    if (!field || field->encoded() == "null") {
      return std::nullopt;
    }
    if (field->encoded() != "true" && field->encoded() != "false") {
      throw std::invalid_argument{"Expected hook boolean"};
    }

    return field->boolean();
  }

  template <typename Integer>
  std::optional<Integer> integer(std::string_view name) {
    const auto field = value(name);
    if (!field || field->encoded() == "null") {
      return std::nullopt;
    }

    const auto input = field->encoded().starts_with('"') ? text(name) : field->encoded();
    Integer result{};
    const auto parsed = std::from_chars(input.data(), input.data() + input.size(), result);
    if (parsed.ec != std::errc{} || parsed.ptr != input.data() + input.size()) {
      throw std::invalid_argument{"Expected hook integer"};
    }

    return result;
  }

  void requireUnique() const {
    for (const auto &member : members_) {
      if (member.duplicate) {
        throw std::invalid_argument{"Duplicate hook field"};
      }
    }
  }

  template <typename Consumer>
  void eachValue(Consumer &&consume) const {
    for (const auto &member : members_) {
      consume(member.value);
    }
  }

private:
  struct Member {
    String<Memory> name;
    JsonValue value;
    std::optional<String<Memory>> text;
    std::size_t position;
    bool duplicate = false;
  };

  Member *find(std::string_view name) noexcept {
    const auto found = std::lower_bound(members_.begin(), members_.end(), name, [](const Member &member, std::string_view key) { return member.name < key; });
    return found != members_.end() && found->name == name ? &*found : nullptr;
  }

  const Member *find(std::string_view name) const noexcept {
    return const_cast<Object *>(this)->find(name);
  }

  void indexMembers() {
    std::ranges::sort(members_, [](const Member &left, const Member &right) { return left.name == right.name ? left.position < right.position : left.name < right.name; });
    std::size_t unique = 0;
    for (std::size_t index = 0; index < members_.size(); ++index) {
      if (unique != 0 && members_[unique - 1].name == members_[index].name) {
        members_[unique - 1] = std::move(members_[index]);
        members_[unique - 1].duplicate = true;
      } else {
        if (unique != index) {
          members_[unique] = std::move(members_[index]);
        }

        ++unique;
      }
    }

    members_.erase(members_.begin() + unique, members_.end());
  }

  std::string_view decode(Member &member) {
    checkUnique(member);
    if (!member.text) {
      String<Memory> decoded{AllocatorRef<char, Memory>{memory_}};
      member.value.string(decoded);
      member.text = std::move(decoded);
    }

    return *member.text;
  }

  void checkUnique(const Member &member) const {
    if (reject_duplicates_ && member.duplicate) {
      throw std::invalid_argument{"Duplicate hook field"};
    }
  }

  Memory &memory_;
  Vector<Member, Memory> members_;
  bool reject_duplicates_;
};

template <Allocator Memory>
Object(Memory &memory, JsonValue value, bool reject_duplicates = false) -> Object<Memory>;

}
