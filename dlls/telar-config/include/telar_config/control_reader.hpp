#pragma once

#include "telar_config/terminal/control/policy.hpp"
#include "telar_lua/value.hpp"
#include <algorithm>

namespace telar::runtime::config {

inline void readControlPolicy(const lua::Value &table, control::Policy &policy) {
  if (!table.present()) {
    return;
  }

  table.onlyFields({"clipboard_read", "clipboard_write", "title_report", "checksum_report", "color_format", "answerback"});
  const auto access = [](const lua::Value &value, control::Access fallback) {
    if (!value.present()) {
      return fallback;
    }
    const auto text = value.string();
    if (text == "deny") {
      return control::Access::deny;
    }
    if (text == "ask") {
      return control::Access::ask;
    }
    if (text == "allow") {
      return control::Access::allow;
    }
    value.fail("must be deny, ask or allow");
  };
  policy.clipboard_read = access(table.field("clipboard_read"), policy.clipboard_read);
  policy.clipboard_write = access(table.field("clipboard_write"), policy.clipboard_write);
  policy.title_report = table.field("title_report").boolean(policy.title_report);
  policy.checksum_report = table.field("checksum_report").boolean(policy.checksum_report);

  const auto format = table.field("color_format");
  if (format.present()) {
    const auto text = format.string();
    if (text == "none") {
      policy.color_format = control::ColorFormat::none;
    } else if (text == "8-bit") {
      policy.color_format = control::ColorFormat::eight_bit;
    } else if (text == "16-bit") {
      policy.color_format = control::ColorFormat::sixteen_bit;
    } else {
      format.fail("must be none, 8-bit or 16-bit");
    }
  }

  const auto answerback = table.field("answerback");
  if (answerback.present()) {
    const auto text = answerback.string();
    if (text.size() > policy.answerback.size()) {
      answerback.fail("exceeds 1024 bytes");
    }
    std::copy(text.begin(), text.end(), policy.answerback.begin());
    policy.answerback_length = static_cast<std::uint16_t>(text.size());
  }
}

}
