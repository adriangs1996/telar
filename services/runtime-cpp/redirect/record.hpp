#pragma once

#include "record_file.hpp"
#include "pf_rules.hpp"
#include "log_interface.hpp"

namespace telar::runtime::redirect {

template <Allocator Memory>
class Record {
public:
  explicit Record(Memory &memory, const PfIdentity<Memory> &identity, std::string_view endpoint)
      : memory_(memory), endpoint_(endpoint, AllocatorRef<char, Memory>{memory}), file_(memory, identity.label) {}

  std::optional<std::uint64_t> load() {
    const auto content = file_.load();
    if (!content) {
      return std::nullopt;
    }
    const auto newline = content->find('\n');
    if (newline == String<Memory>::npos || std::string_view{*content}.substr(0, newline) != endpoint_) {
      throw std::runtime_error{"Redirect recovery record belongs to another endpoint"};
    }
    auto value = std::string_view{*content}.substr(newline + 1);
    const auto log = value.find('\n');
    if (log != std::string_view::npos) {
      const auto name = value.substr(log + 1);
      unsigned index = LogInterface::maximum;
      const auto parsed = std::from_chars(name.data(), name.data() + name.size(), index);
      if (parsed.ec != std::errc{} || parsed.ptr != name.data() + name.size() || index >= LogInterface::maximum) {
        throw std::runtime_error{"Invalid redirect log recovery record"};
      }
      log_index_ = index;
      value = value.substr(0, log);
    }
    std::uint64_t token = 0;
    const auto result = std::from_chars(value.data(), value.data() + value.size(), token);
    if (result.ec != std::errc{} || result.ptr != value.data() + value.size()) {
      throw std::runtime_error{"Invalid redirect recovery token"};
    }
    last_token_ = token;
    return token;
  }

  void save(std::uint64_t token) {
    String<Memory> content{endpoint_, AllocatorRef<char, Memory>{memory_}};
    content += '\n';
    std::array<char, 32> value{};
    const auto result = std::to_chars(value.data(), value.data() + value.size(), token);
    content.append(value.data(), static_cast<std::size_t>(result.ptr - value.data()));
    if (log_index_) {
      content += '\n';
      const auto log = std::to_chars(value.data(), value.data() + value.size(), *log_index_);
      content.append(value.data(), static_cast<std::size_t>(log.ptr - value.data()));
    }
    file_.save(content);
    last_token_ = token;
  }

  void saveLog(unsigned index) {
    if (!last_token_ || index >= LogInterface::maximum) { throw std::runtime_error{"Redirect session must exist before reserving a log interface"}; }
    const auto previous = log_index_;
    log_index_ = index;
    try {
      save(*last_token_);
    } catch (...) {
      log_index_ = previous;
      throw;
    }
  }

  void clear() {
    if (log_index_) {
      LogInterface::remove(*log_index_);
      log_index_.reset();
      save(last_token_.value_or(0));
    }
    file_.clear();
    log_index_.reset();
    last_token_.reset();
  }

private:
  Memory &memory_;
  String<Memory> endpoint_;
  RecordFile<Memory> file_;
  std::optional<unsigned> log_index_;
  std::optional<std::uint64_t> last_token_;
};

}
