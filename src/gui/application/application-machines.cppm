// The machines as ui drives them: the roster a window holds, the profiles it saves, how the
// chrome shows them and how a connection to one fails. The window holds its roster across the
// sessions of its machines, so these are types ui holds, not use cases of a session.
export module telar.gui.application:machines;

import telar.gui.features.machines;

export namespace telar::gui::application::machines {

  using features::machines::MachineActivityTarget;
  using features::machines::MachineAddress;
  using features::machines::MachineChromeGeometry;
  using features::machines::MachineClientKey;
  using features::machines::MachineConnectionPolicy;
  using features::machines::MachineDiscovery;
  using features::machines::MachineEdit;
  using features::machines::MachineEditKind;
  using features::machines::MachineError;
  using features::machines::MachineFacts;
  using features::machines::MachineFailure;
  using features::machines::MachineFieldRules;
  using features::machines::MachineFields;
  using features::machines::MachineLimits;
  using features::machines::MachineMetrics;
  using features::machines::MachineObservation;
  using features::machines::MachineOpening;
  using features::machines::MachinePhase;
  using features::machines::MachinePicker;
  using features::machines::MachinePickerTarget;
  using features::machines::MachineProfile;
  using features::machines::MachineProfileCodec;
  using features::machines::MachineProfileEdits;
  using features::machines::MachineProfileMessages;
  using features::machines::MachineProfiles;
  using features::machines::MachineProfileStore;
  using features::machines::MachineRemoteCommand;
  using features::machines::MachineRuntimeLocation;
  using features::machines::Machines;
  using features::machines::MachineToken;
  using features::machines::OwnedMachineEdit;

}
