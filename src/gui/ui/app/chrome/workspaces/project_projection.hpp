#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "ui/kit/models/projection.hpp"
#include <QString>
#include <QVariantMap>
#include <array>
#include <cstddef>
#include <cstring>
#include <span>

#pragma once

import telar.gui.foundation.agents;
import telar.gui.foundation.model;
import telar.gui.application;

namespace telar::gui::qt {

  template <Allocator Memory>
  QVariantMap projectRecord(const Workspace<Memory>& workspace, const WorkspaceReplica<Memory>& workspaces, std::span<const Agent<Memory>> agents, bool selected, const application::workbench::WorkspaceMark& mark) {
    auto record = workspaceRecord(workspace, selected, mark);
    const auto activity = application::activity::ProjectActivity::derive(workspaces, agents, workspace.location.id);
    application::activity::ProjectActivity::Text summary;

    record.insert(QStringLiteral("facts"), toQString(activity.summary(summary).valueOr(std::string_view{})));
    record.insert(QStringLiteral("attention"), toQString(activity.attentionLabel().view()));
    const auto color = activity.urgent ? AgentStatusPresentation::color(agents[*activity.urgent].status) : PaletteRole::overlay1;

    record.insert(QStringLiteral("attentionColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(color)]));

    return record;
  }

}
