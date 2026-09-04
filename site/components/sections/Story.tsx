type Props = { title: string; intro: React.ReactNode; children?: React.ReactNode; wide?: boolean };

// The content of one pane: a title, a short introduction, and the thing that
// shows it. Wide panes put the demo beside the text; narrow ones stack it.
export default function Story({ title, intro, children, wide = false }: Props) {
  return (
    <div className={`p-6 md:p-9 lg:p-11 ${wide ? "lg:grid lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:gap-14" : ""}`}>
      <div>
        <h2 className="display-sm text-[clamp(1.6rem,2.6vw,2.3rem)]">{title}</h2>
        <div className="prose-measure mt-5 space-y-4 text-subtext">{intro}</div>
      </div>
      {children ? <div className={`min-w-0 ${wide ? "mt-10 lg:mt-0" : "mt-9"}`}>{children}</div> : null}
    </div>
  );
}
