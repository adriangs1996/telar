pragma ComponentBehavior: Bound

import QtQuick
import Telar.Gui

// Add a machine and set it up: pair it by the address its gateway prints, choose the telar it
// runs and what setup brings there, apply it and sign its agents in. Each step is the
// controller's; this panel draws its state and passes on what the person types and chooses.
Item {
    id: root
    objectName: "machineWizard"

    required property MachineWizardController controller
    required property var colors
    required property var typography
    property real ratio: 1
    readonly property var state: controller.state
    readonly property int step: state.step ?? 0
    readonly property bool helper: state.helper ?? false
    readonly property var problems: state.problems ?? ({})
    property alias field: address
    signal cancelled()

    readonly property real sectionGap: 16 * ratio
    readonly property real labelGap: 6 * ratio
    readonly property real rowGap: 4 * ratio
    readonly property real titleLeading: 1.35
    readonly property real smallLeading: 1.4
    readonly property real buttonHeight: 32 * ratio
    readonly property real buttonPadding: 14 * ratio
    readonly property real chipHeight: 26 * ratio
    readonly property real cardPadding: 12 * ratio
    readonly property real radius: ChromeStyle.controlRadius * ratio
    readonly property real smallRow: Math.ceil((typography.small ?? 0) * smallLeading)
    readonly property real bodyRow: Math.ceil((typography.body ?? 0) * smallLeading)

    implicitHeight: column.implicitHeight

    function primaryText() {
        if (root.helper)
            return "I have the address";
        switch (root.step) {
        case 0:
            return root.state.paired ? "Continue" : "Pair";
        case 2:
            return "Apply";
        case 4:
            return root.state.running ? "Continue" : "Finish";
        case 5:
            return "Open machine";
        default:
            return "Continue";
        }
    }

    function hintText() {
        if (root.helper)
            return "Back returns to the address";
        if (root.state.running)
            return root.step === 0 ? "Pairing…" : "Closing lets setup finish there";
        if (root.step === 0 && !root.state.paired)
            return "Nothing is saved until the gateway accepts the code";
        if (root.step === 4)
            return "Each agent can wait";
        return "";
    }

    // What the person types reaches the controller as it is typed; a field takes the controller's
    // value only where it differs, as when a failed address is cleared or a name derived.
    function synchronize() {
        if (address.text.trim() !== (root.state.address ?? "")) {
            address.text = root.state.address ?? "";
            address.input.cursorPosition = address.text.length;
        }
        if (label.text.trim() !== (root.state.label ?? "")) {
            label.text = root.state.label ?? "";
            label.input.cursorPosition = label.text.length;
        }
    }

    Component.onCompleted: {
        synchronize();
        address.input.forceActiveFocus();
    }

    Connections {
        target: root.controller
        function onChanged() {
            root.synchronize();
        }
    }

    component Label: ChromeText {
        width: parent?.width ?? 0
        height: root.bodyRow
        color: root.colors.text
        pixelSize: root.typography.body ?? 1
        emphasized: true
    }

    component Caption: ChromeText {
        width: parent?.width ?? 0
        height: root.smallRow
        color: root.colors.subtext0
        pixelSize: root.typography.small ?? 1
    }

    // A paragraph that wraps to the width it is given.
    component Paragraph: Text {
        width: parent?.width ?? 0
        wrapMode: Text.Wrap
        color: root.colors.subtext0
        font.pixelSize: root.typography.small ?? 1
        lineHeight: root.smallLeading
    }

    component Card: Item {
        id: card
        default property alias content: inner.data
        property color tone: root.colors.surface0
        width: parent?.width ?? 0
        height: inner.implicitHeight + 2 * root.cardPadding

        NativeRoundedRectangle {
            anchors.fill: parent
            color: Qt.alpha(card.tone, 0.16)
            radius: root.radius
            borderColor: card.tone
            borderAlpha: 0.5
            borderWidth: 1 / Screen.devicePixelRatio
        }

        Column {
            id: inner
            x: root.cardPadding
            y: root.cardPadding
            width: parent.width - 2 * root.cardPadding
            spacing: root.labelGap
        }
    }

    component Button: FormButton {
        width: textAdvance + 2 * root.buttonPadding
        height: root.buttonHeight
        colors: root.colors
        pixelSize: root.typography.body ?? 1
        radius: root.radius
        disabledAlpha: 0.45
        pressedAlpha: 0.75
    }

    // A choice among several, drawn as a row the person picks.
    component Choice: Item {
        id: choice
        property string title
        property string detail
        property bool chosen: false
        property bool available: true
        signal picked()
        width: parent?.width ?? 0
        height: choiceText.implicitHeight + 2 * 8 * root.ratio
        opacity: available ? 1 : 0.5

        NativeRoundedRectangle {
            anchors.fill: parent
            color: choice.chosen ? root.colors.surface1 : root.colors.surface0
            radius: root.radius
            visible: choice.chosen || choicePointer.containsMouse
        }

        ChromeText {
            id: mark
            x: 10 * root.ratio
            width: root.typography.body ?? 1
            height: parent.height
            text: choice.chosen ? "●" : "○"
            color: choice.chosen ? root.colors.accent : root.colors.subtext0
            pixelSize: root.typography.body ?? 1
        }

        Column {
            id: choiceText
            x: mark.x + mark.width + 10 * root.ratio
            y: 8 * root.ratio
            width: parent.width - x - 10 * root.ratio

            Label {
                text: choice.title
                emphasized: false
            }

            Paragraph {
                text: choice.detail
                visible: text.length > 0
            }
        }

        ActionPointer {
            id: choicePointer
            anchors.fill: parent
            enabled: choice.available
            identity: "machineWizardChoice:" + choice.title
            onActivated: choice.picked()
        }
    }

    component Toggle: Choice {
        id: toggle
        property bool on: false
        chosen: on
    }

    // One step of setup as it reports it: done, failed, skipped, running or still to come.
    component SetupRow: Item {
        id: setupRow
        required property var modelData
        readonly property string status: modelData.status ?? ""
        readonly property var notes: modelData.notes ?? []
        width: parent?.width ?? 0
        height: rowText.implicitHeight + 2 * 4 * root.ratio

        ChromeText {
            id: glyph
            y: 4 * root.ratio
            width: root.typography.body ?? 1
            height: root.bodyRow
            text: ({ok: "✓", changed: "✓", failed: "✕", skipped: "–", pending: "…", running: "●"})[setupRow.status] ?? "·"
            color: ({ok: root.colors.green, changed: root.colors.green, failed: root.colors.red, pending: root.colors.peach, running: root.colors.accent})[setupRow.status] ?? root.colors.subtext0
            pixelSize: root.typography.body ?? 1
        }

        Column {
            id: rowText
            x: glyph.width + 10 * root.ratio
            y: 4 * root.ratio
            width: parent.width - x

            ChromeText {
                width: parent.width
                height: root.bodyRow
                text: setupRow.modelData.title ?? ""
                color: setupRow.status === "" ? root.colors.subtext0 : root.colors.text
                pixelSize: root.typography.body ?? 1
            }

            Paragraph {
                text: setupRow.modelData.detail ?? ""
                visible: text.length > 0 && setupRow.status !== "running"
            }

            Repeater {
                model: setupRow.notes

                Paragraph {
                    required property string modelData
                    text: "· " + modelData
                }
            }
        }
    }

    Column {
        id: column
        width: parent.width
        spacing: root.sectionGap

        // Title, then where the wizard is.
        Column {
            width: parent.width
            spacing: root.labelGap

            ChromeText {
                width: parent.width
                height: Math.ceil((root.typography.title ?? 0) * root.titleLeading)
                text: root.state.existing ? "Set up " + (root.state.label ?? "") : "Add machine"
                color: root.colors.text
                pixelSize: root.typography.title ?? 1
                emphasized: true
            }

            Row {
                objectName: "machineWizardSteps"
                spacing: 4 * root.ratio

                Repeater {
                    model: root.state.steps ?? []

                    Item {
                        id: stepChip
                        required property int index
                        required property string modelData
                        readonly property bool current: index === root.step
                        readonly property bool done: index < root.step
                        width: chipText.implicitWidth + 16 * root.ratio
                        height: root.chipHeight

                        NativeRoundedRectangle {
                            anchors.fill: parent
                            color: root.colors.surface1
                            radius: root.radius
                            visible: stepChip.current
                        }

                        ChromeText {
                            id: chipText
                            anchors.centerIn: parent
                            width: implicitWidth
                            height: parent.height
                            text: (stepChip.done ? "✓ " : "") + stepChip.modelData
                            color: stepChip.current ? root.colors.text : root.colors.subtext0
                            pixelSize: root.typography.small ?? 1
                            emphasized: stepChip.current
                        }
                    }
                }
            }
        }

        // Pair: the address the machine's gateway printed.
        Column {
            objectName: "machineWizardPair"
            width: parent.width
            spacing: root.sectionGap
            visible: root.step === 0 && !root.helper

            Column {
                width: parent.width
                spacing: root.labelGap

                Label {
                    text: "Pairing address"
                }

                PromptField {
                    id: address
                    width: parent.width
                    inputName: root.visible && root.step === 0 && !root.helper ? "commandSearch" : "machineWizardAddress"
                    colors: root.colors
                    typography: root.typography
                    ratio: root.ratio
                    placeholderText: "telar://HOST:PORT#KEY.CODE"
                    input.enabled: !root.state.paired && !root.state.running
                    onEdited: root.controller.setField("address", text)
                    onSubmitted: root.controller.next()
                    onCancelled: root.cancelled()
                    onTabbed: label.input.forceActiveFocus()
                }

                Caption {
                    text: root.problems.address ?? (root.state.paired ? "Paired: the code is spent, and the address saved without it" : (root.state.parsed?.code ? "Pairing code included · valid once, for ten minutes" : "What telar server pair printed on that machine"))
                    color: root.problems.address ? root.colors.red : (root.state.parsed?.code || root.state.paired ? root.colors.green : root.colors.subtext0)
                }

                ChromeText {
                    objectName: "machineWizardPrepare"
                    width: implicitWidth
                    height: root.smallRow
                    visible: !root.state.paired
                    text: "Don't have an address yet? Prepare the machine"
                    color: root.colors.accent
                    pixelSize: root.typography.small ?? 1

                    ActionPointer {
                        anchors.fill: parent
                        identity: "machineWizardPrepare"
                        onActivated: root.controller.openHelper(false)
                    }
                }
            }

            Row {
                width: parent.width
                spacing: 12 * root.ratio

                Column {
                    width: (parent.width - parent.spacing) * 0.45
                    spacing: root.labelGap

                    Label {
                        text: "Name"
                    }

                    PromptField {
                        id: label
                        width: parent.width
                        inputName: "machineWizardLabel"
                        colors: root.colors
                        typography: root.typography
                        ratio: root.ratio
                        placeholderText: "box"
                        input.enabled: !root.state.paired && !root.state.running
                        onEdited: root.controller.setField("label", text)
                        onSubmitted: root.controller.next()
                        onCancelled: root.cancelled()
                        onTabbed: address.input.forceActiveFocus()
                    }

                    Caption {
                        text: root.problems.label ?? (root.state.label ? "How this window names it" : "")
                        color: root.problems.label ? root.colors.red : root.colors.subtext0
                    }
                }

                Column {
                    width: (parent.width - parent.spacing) * 0.55
                    spacing: root.labelGap

                    Label {
                        text: "This Mac appears there as"
                    }

                    ChromeText {
                        width: parent.width
                        height: root.buttonHeight
                        text: root.state.localName ?? ""
                        color: root.colors.subtext0
                        pixelSize: root.typography.body ?? 1
                    }

                    Caption {
                        text: "Shown by telar server access list there"
                    }
                }
            }

            Row {
                spacing: 8 * root.ratio
                visible: root.state.parsed?.host !== undefined && !root.state.failure

                Repeater {
                    model: [["Host", root.state.parsed?.host ?? ""], ["Port", root.state.parsed?.port ?? ""], ["Gateway key", root.state.parsed?.key ?? ""]]

                    Item {
                        id: fact
                        required property var modelData
                        width: Math.max(factName.implicitWidth, factValue.implicitWidth) + 20 * root.ratio
                        height: 2 * root.smallRow + 12 * root.ratio

                        NativeRoundedRectangle {
                            anchors.fill: parent
                            color: root.colors.surface0
                            radius: root.radius
                        }

                        ChromeText {
                            id: factName
                            x: 10 * root.ratio
                            y: 6 * root.ratio
                            width: implicitWidth
                            height: root.smallRow
                            text: fact.modelData[0]
                            color: root.colors.subtext0
                            pixelSize: root.typography.small ?? 1
                        }

                        ChromeText {
                            id: factValue
                            x: 10 * root.ratio
                            y: 6 * root.ratio + root.smallRow
                            width: implicitWidth
                            height: root.smallRow
                            text: fact.modelData[1]
                            color: root.colors.text
                            pixelSize: root.typography.small ?? 1
                        }
                    }
                }
            }

            Card {
                visible: (root.state.failure ?? "").length > 0 && root.step === 0
                tone: root.colors.red

                Label {
                    text: "The machine was not paired"
                }

                Paragraph {
                    text: root.state.failure ?? ""
                    color: root.colors.text
                }

                Paragraph {
                    text: "A gateway that does not answer usually needs its port opened, or an address printed with the host and port this Mac reaches it by."
                }

                Row {
                    spacing: 8 * root.ratio

                    Button {
                        objectName: "machineWizardFixReach"
                        text: "Fix how this Mac reaches it"
                        primary: true
                        identity: "machineWizardFixReach"
                        onActivated: root.controller.openHelper(true)
                    }
                }
            }
        }

        // Prepare the machine: what to open there, and the command that prints its address.
        Column {
            objectName: "machineWizardHelper"
            width: parent.width
            spacing: root.sectionGap
            visible: root.step === 0 && root.helper

            Column {
                width: parent.width
                spacing: root.labelGap

                Label {
                    text: "How this Mac reaches the machine"
                }

                Flow {
                    width: parent.width
                    spacing: 6 * root.ratio

                    Repeater {
                        model: root.state.reaches ?? []

                        Button {
                            required property var modelData
                            text: modelData.name
                            height: root.chipHeight
                            primary: modelData.key === root.state.reach
                            identity: "machineWizardReach:" + modelData.key
                            onActivated: root.controller.setField("reach", modelData.key)
                        }
                    }
                }
            }

            Row {
                width: parent.width
                spacing: 12 * root.ratio

                Column {
                    width: (parent.width - parent.spacing) * 0.6
                    spacing: root.labelGap

                    Label {
                        text: root.state.reachField ?? ""
                    }

                    PromptField {
                        id: reachAs
                        width: parent.width
                        inputName: "machineWizardReachAs"
                        colors: root.colors
                        typography: root.typography
                        ratio: root.ratio
                        text: root.state.reachAs ?? ""
                        placeholderText: root.state.reachPlaceholder ?? ""
                        onEdited: root.controller.setField("reachAs", text)
                        onSubmitted: root.controller.next()
                        onCancelled: root.cancelled()
                    }

                    Caption {
                        text: root.problems.reachAs ?? "Goes in the address as --host"
                        color: root.problems.reachAs ? root.colors.red : root.colors.subtext0
                    }
                }

                Column {
                    width: (parent.width - parent.spacing) * 0.4
                    spacing: root.labelGap

                    Label {
                        text: root.state.reach === "forward" ? "Port this Mac dials" : "Gateway port"
                    }

                    PromptField {
                        width: parent.width
                        inputName: "machineWizardPort"
                        colors: root.colors
                        typography: root.typography
                        ratio: root.ratio
                        text: root.state.reach === "forward" ? (root.state.dialPort ?? "") : (root.state.listenPort ?? "")
                        placeholderText: root.state.reach === "forward" ? "9000" : "8352"
                        onEdited: root.controller.setField(root.state.reach === "forward" ? "dialPort" : "listenPort", text)
                        onSubmitted: root.controller.next()
                        onCancelled: root.cancelled()
                    }

                    Caption {
                        text: root.state.reach === "forward" ? (root.problems.dialPort ?? "Goes in the address as --port") : (root.problems.listenPort ?? "Where its gateway listens")
                        color: root.problems.dialPort || root.problems.listenPort ? root.colors.red : root.colors.subtext0
                    }
                }
            }

            Card {
                Paragraph {
                    text: root.state.openLine ?? ""
                    color: root.colors.text
                    font.pixelSize: root.typography.body ?? 1
                }

                Paragraph {
                    text: "One TCP port carries everything: the window, commands, Git and forwarded ports. Nothing opens on this Mac."
                }
            }

            Column {
                width: parent.width
                spacing: root.labelGap

                Label {
                    text: "Then run this there, as the account whose terminals you want here"
                }

                Row {
                    spacing: 6 * root.ratio

                    Button {
                        text: "Telar isn't there yet"
                        height: root.chipHeight
                        primary: !root.state.installed
                        identity: "machineWizardInstalled:false"
                        onActivated: root.controller.setOption("installed", false)
                    }

                    Button {
                        text: "Telar is already there"
                        height: root.chipHeight
                        primary: root.state.installed ?? false
                        identity: "machineWizardInstalled:true"
                        onActivated: root.controller.setOption("installed", true)
                    }
                }

                Item {
                    width: parent.width
                    height: command.implicitHeight + 2 * root.cardPadding

                    NativeRoundedRectangle {
                        anchors.fill: parent
                        color: root.colors.surface_dim
                        radius: root.radius
                    }

                    Text {
                        id: command
                        objectName: "machineWizardCommand"
                        x: root.cardPadding
                        y: root.cardPadding
                        width: parent.width - 2 * root.cardPadding - copy.width - root.cardPadding
                        text: (root.state.command ?? "").replace(" | ", " \\\n  | ")
                        wrapMode: Text.WrapAnywhere
                        color: root.colors.text
                        font.family: root.typography.primaryFamily ?? ""
                        font.pixelSize: root.typography.small ?? 1
                    }

                    Button {
                        id: copy
                        anchors.right: parent.right
                        anchors.rightMargin: root.cardPadding
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Copy"
                        height: root.chipHeight
                        identity: "machineWizardCopy"
                        onActivated: root.controller.copyCommand()
                    }
                }

                Paragraph {
                    text: root.state.installed ? "From a source build, keep telar, telar-runtime, telar-config-check and telar-gateway in one directory there." : "Installs telar under ~/.local/bin without root, starts its gateway as a service of that account, and prints an address that starts with telar://."
                }
            }
        }

        // Telar: where the build the machine runs comes from.
        Column {
            objectName: "machineWizardTelar"
            width: parent.width
            spacing: root.rowGap
            visible: root.step === 1

            Label {
                text: "Install telar from"
            }

            Choice {
                title: "Official release"
                detail: "The machine downloads the release for its platform and checks it against its SHA-256."
                chosen: root.state.source === "release"
                onPicked: root.controller.setField("source", "release")
            }

            Choice {
                title: "This build"
                detail: "Sent with --binary: " + (root.state.thisBuild ?? "") + ". Only where the machine runs this platform."
                chosen: root.state.source === "build"
                onPicked: root.controller.setField("source", "build")
            }

            Choice {
                title: "A build on disk"
                detail: "Sent with --binary: a telar built for that machine, with its companions beside it."
                chosen: root.state.source === "disk"
                onPicked: root.controller.setField("source", "disk")
            }

            PromptField {
                width: parent.width
                visible: root.state.source === "disk"
                inputName: "machineWizardDisk"
                colors: root.colors
                typography: root.typography
                ratio: root.ratio
                text: root.state.diskPath ?? ""
                placeholderText: "/path/to/build/telar"
                onEdited: root.controller.setField("diskPath", text)
                onSubmitted: root.controller.next()
                onCancelled: root.cancelled()
            }
        }

        // Agents: what setup brings there besides telar.
        Column {
            objectName: "machineWizardAgents"
            width: parent.width
            spacing: root.rowGap
            visible: root.step === 2

            Label {
                text: "Bring there"
            }

            Toggle {
                title: "Coding agents"
                detail: "The agents you have here, with their official installers. One that misses a prerequisite there is said, not skipped in silence."
                on: root.state.agents ?? true
                onPicked: root.controller.setOption("agents", !on)
            }

            Toggle {
                title: "My agent settings"
                detail: "Their configuration, never a credential: allowlisted files, without secrets."
                on: root.state.configuration ?? true
                onPicked: root.controller.setOption("configuration", !on)
            }

            Toggle {
                title: "Neovim for editor panes"
                detail: "The machine downloads it and keeps it only if its checksum is the one this build expects."
                on: root.state.editor ?? true
                onPicked: root.controller.setOption("editor", !on)
            }
        }

        // Apply and Sign in: setup's steps as it reports them, and what it asks.
        Column {
            objectName: "machineWizardProgress"
            width: parent.width
            spacing: root.rowGap
            visible: root.step === 3 || root.step === 4

            Repeater {
                model: root.state.rows ?? []

                SetupRow {}
            }

            Repeater {
                model: root.step === 4 ? (root.state.logins ?? []) : []

                Card {
                    id: loginCard
                    required property var modelData
                    tone: root.colors.accent

                    Label {
                        text: modelData.agent + ": open the page and sign in"
                    }

                    Paragraph {
                        text: modelData.url
                        color: root.colors.text
                        wrapMode: Text.WrapAnywhere
                    }

                    Paragraph {
                        text: "Code: " + modelData.code
                        visible: (modelData.code ?? "").length > 0
                        color: root.colors.text
                    }

                    Button {
                        text: "Open the page"
                        primary: true
                        identity: "machineWizardLogin:" + loginCard.modelData.agent
                        onActivated: root.controller.openLink(loginCard.modelData.url)
                    }
                }
            }

            Card {
                objectName: "machineWizardQuestion"
                visible: (root.state.question?.kind ?? "").length > 0
                tone: root.colors.peach

                Paragraph {
                    text: root.state.question?.text ?? ""
                    color: root.colors.text
                    font.pixelSize: root.typography.body ?? 1
                }

                PromptField {
                    id: reply
                    width: parent.width
                    visible: root.state.question?.kind === "login_code"
                    inputName: "machineWizardReply"
                    colors: root.colors
                    typography: root.typography
                    ratio: root.ratio
                    placeholderText: "Paste the code"
                    onSubmitted: root.controller.answer(text)
                    onCancelled: root.cancelled()
                }

                Row {
                    spacing: 8 * root.ratio

                    Button {
                        text: root.state.question?.kind === "login_code" ? "Sign in" : (root.state.question?.kind === "stop_runtime" ? "Stop it and start this build" : "Yes")
                        primary: true
                        identity: "machineWizardAnswerYes"
                        onActivated: root.controller.answer(root.state.question?.kind === "login_code" ? reply.text : "true")
                    }

                    Button {
                        text: root.state.question?.kind === "login_code" ? "Later" : (root.state.question?.kind === "stop_runtime" ? "Keep it" : "No")
                        identity: "machineWizardAnswerNo"
                        onActivated: root.controller.answer(root.state.question?.kind === "login_code" ? "" : "false")
                    }
                }
            }

            Card {
                visible: root.step === 3 && !root.state.running && (root.state.failure ?? "").length > 0
                tone: root.colors.red

                Label {
                    text: "Setup stopped at a step"
                }

                Paragraph {
                    text: root.state.failure ?? ""
                    color: root.colors.text
                }

                Paragraph {
                    text: "Everything before it is in place. Try again once what it says is fixed."
                }

                Button {
                    text: "Try again"
                    primary: true
                    identity: "machineWizardRetry"
                    onActivated: root.controller.retry()
                }
            }
        }

        // Ready: what was set up.
        Column {
            objectName: "machineWizardReady"
            width: parent.width
            spacing: root.labelGap
            visible: root.step === 5

            Repeater {
                model: [["Machine", root.state.label ?? ""], ["Address", root.state.destination ?? ""], ["Telar there", root.state.telarPath ?? ""]]

                Item {
                    id: readyFact
                    required property var modelData
                    width: parent.width
                    height: root.bodyRow
                    visible: (modelData[1] ?? "").length > 0

                    ChromeText {
                        width: 110 * root.ratio
                        height: parent.height
                        text: readyFact.modelData[0]
                        color: root.colors.subtext0
                        pixelSize: root.typography.body ?? 1
                    }

                    ChromeText {
                        x: 110 * root.ratio
                        width: parent.width - x
                        height: parent.height
                        text: readyFact.modelData[1]
                        color: root.colors.text
                        pixelSize: root.typography.body ?? 1
                        elide: Text.ElideMiddle
                    }
                }
            }

            Paragraph {
                text: "Saved in machines.json. A localhost link in its panes opens here through a forwarded port, and closing the window leaves its panes and agents running there."
            }
        }

        // Back, what the step says, and the step's own action.
        Item {
            width: parent.width
            height: root.buttonHeight

            Button {
                id: backButton
                objectName: "machineWizardBack"
                text: "Back"
                quiet: true
                interactive: !root.state.running && (root.helper || (root.step > (root.state.existing ? 1 : 0) && root.step < 3 && !(root.step === 1 && root.state.paired && !root.state.existing)))
                identity: "machineWizardBack"
                onActivated: root.controller.back()
            }

            ChromeText {
                anchors.left: backButton.right
                anchors.leftMargin: 10 * root.ratio
                anchors.right: next.left
                anchors.rightMargin: 10 * root.ratio
                height: parent.height
                text: root.hintText()
                color: root.colors.subtext0
                pixelSize: root.typography.small ?? 1
            }

            Button {
                id: next
                objectName: "machineWizardNext"
                anchors.right: parent.right
                text: root.primaryText()
                primary: true
                interactive: root.state.canContinue ?? false
                identity: "machineWizardNext"
                onActivated: root.controller.next()
            }
        }
    }
}
