#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include <string_view>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <stdexcept>
#include "telar_client/serializers/telar_cells.hpp"
#include <charconv>
#include <cstring>
#include <system_error>
#include <cmath>
#include <tuple>
#include "projection.hpp"
#include <QString>
#include <QVariantMap>

#pragma once
#include "core/memory.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.presentation.activity_order;

namespace telar::gui::qt {

template <Allocator Memory>
QVariantMap projectRecord(const Workspace<Memory> &workspace, const WorkspaceReplica<Memory> &workspaces, std::span<const Agent<Memory>> agents, bool selected) {
  auto record = workspaceRecord(workspace, selected);
  const auto activity = ProjectActivity::derive(workspaces, agents, workspace.location.id);
  ProjectActivity::Text summary;
  record.insert(QStringLiteral("detail"), toQString(activity.summary(summary).value_or(workspace.path)));
  record.insert(QStringLiteral("attention"), toQString(activity.attentionLabel().view()));
  const auto color = activity.urgent ? AgentStatusPresentation::color(agents[*activity.urgent].status) : PaletteRole::overlay1;
  record.insert(QStringLiteral("attentionColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(color)]));

  return record;
}

}
