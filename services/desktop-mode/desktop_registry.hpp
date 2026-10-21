#pragma once

#include "desktop_state.hpp"
#include <map>
#include <set>
#include <string>

class DesktopRegistry final {
public:
  explicit DesktopRegistry(std::string runtime_socket);

  static std::string directory();
  void load();
  std::optional<std::string> space(std::uint64_t workspace) const;
  void save(const DesktopState &state);

private:
  std::string runtime_;
  std::string origin_;
  std::set<std::uint64_t> cloned_;
  std::map<std::string, std::string> bindings_;
  bool loaded_ = false;

  std::string key(std::uint64_t workspace) const;
};
