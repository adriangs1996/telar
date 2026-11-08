// A window is a view of a runtime that owns the panes; the same window can
// view a runtime on another machine over SSH.
export default function RuntimeDiagram() {
  return (
    <svg className="runtime-diagram" viewBox="0 0 530 250" role="img" aria-label="A window connects to a local runtime that owns the panes and agents and survives the window; another window connects over SSH to a runtime on a remote machine">
      <rect className="box" x="10" y="30" width="130" height="64" rx="10" />
      <text className="name" x="28" y="58">Window</text>
      <text x="28" y="78">Qt Quick view</text>

      <rect className="box live" x="195" y="20" width="150" height="84" rx="10" />
      <text className="name" x="213" y="50">Runtime</text>
      <text x="213" y="70">PTYs · panes</text>
      <text x="213" y="88">history · agents</text>
      <path className="wire" d="M140 62 H195" />

      <rect className="box" x="395" y="14" width="125" height="26" rx="6" />
      <text x="407" y="31">pane · zsh</text>
      <rect className="box" x="395" y="48" width="125" height="26" rx="6" />
      <text x="407" y="65">pane · nvim</text>
      <rect className="box live" x="395" y="82" width="125" height="26" rx="6" />
      <text x="407" y="99">agent · claude</text>
      <path className="wire" d="M345 62 C370 62 370 27 395 27 M345 62 H395 M345 62 C370 62 370 95 395 95" />

      <path className="wire cut" d="M75 94 V160" />
      <text x="84" y="132">quit · reopen</text>

      <rect className="box" x="10" y="160" width="130" height="64" rx="10" />
      <text className="name" x="28" y="188">Window</text>
      <text x="28" y="208">on your laptop</text>
      <rect className="box" x="195" y="160" width="150" height="64" rx="10" />
      <text className="name" x="213" y="188">Runtime</text>
      <text x="213" y="208">dev@box</text>
      <path className="wire ssh" d="M140 192 H195" />
      <text x="150" y="182">ssh</text>
    </svg>
  );
}
