export module telar.gui.ui.app.chrome.workspaces:project_projection;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.foundation.agents;
import telar.gui.foundation.model;
import telar.gui.application;
import telar.gui.foundation.core;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  template <Allocator Memory>
  [[tbc::generic]] QVariantMap projectRecord(const Workspace<Memory>& workspace, const WorkspaceReplica<Memory>& workspaces, std::span<const Agent<Memory>> agents, bool selected, const application::workbench::WorkspaceMark& mark) {
    auto record = workspaceRecord(workspace, selected, mark);
    const auto activity = application::activity::ProjectActivity::derive(workspaces, agents, workspace.location.id);
    application::activity::ProjectActivity::Text summary;

    record.insert(u"facts"_s, toQString(activity.summary(summary).valueOr(std::string_view{})));
    record.insert(u"attention"_s, toQString(activity.attentionLabel().view()));
    const auto color = activity.urgent ? AgentStatusPresentation::color(agents[*activity.urgent].status) : PaletteRole::overlay1;

    record.insert(u"attentionColor"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(color)]));

    return record;
  }

}
