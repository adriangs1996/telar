#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/memory.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QString>
#include <QVariantMap>
#include <array>
#include <cstddef>
#include <cstring>
#include <span>

#pragma once

import telar.gui.presentation.activity_order;
import telar.gui.model.replicas;

namespace telar::gui::qt {

  template <Allocator Memory>
  QVariantMap projectRecord(const Workspace<Memory>& workspace, const WorkspaceReplica<Memory>& workspaces, std::span<const Agent<Memory>> agents, bool selected) {
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
