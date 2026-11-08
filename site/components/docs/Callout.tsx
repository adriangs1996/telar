type Kind = "note" | "tip" | "warning";

const LABELS: Record<Kind, string> = { note: "Note", tip: "Tip", warning: "Warning" };

function Callout({ kind, children }: { kind: Kind; children: React.ReactNode }) {
  return (
    <aside className="docs-callout" data-kind={kind}>
      <p className="docs-callout-label">{LABELS[kind]}</p>
      {children}
    </aside>
  );
}

export const Note = ({ children }: { children: React.ReactNode }) => <Callout kind="note">{children}</Callout>;
export const Tip = ({ children }: { children: React.ReactNode }) => <Callout kind="tip">{children}</Callout>;
export const Warning = ({ children }: { children: React.ReactNode }) => <Callout kind="warning">{children}</Callout>;
