import Reveal from "@/components/Reveal";

type Props = {
  number: string;
  title: React.ReactNode;
  children: React.ReactNode;
  figure: React.ReactNode;
  tag?: string;
  flip?: boolean;
};

// One numbered row: the number and the text on one side, the moving figure
// on the other. `flip` puts the figure first so consecutive rows zigzag.
export default function Feature({ number, title, children, figure, tag, flip = false }: Props) {
  return (
    <Reveal as="li" className="hairline grid gap-10 px-5 py-14 md:px-8 md:py-20 lg:grid-cols-12 lg:gap-12">
      <div className={`lg:col-span-5 ${flip ? "lg:order-2" : ""}`} style={{ ["--i" as string]: 0 }}>
        <div className="flex items-end gap-4">
          <span className="feature-number" aria-hidden="true">
            {number}
          </span>
          {tag ? (
            <span className="mb-2 rounded-sm border border-line px-2 py-0.5 font-mono text-[10.5px] tracking-[0.14em] text-peach uppercase">{tag}</span>
          ) : null}
        </div>
        <h3 className="title mt-6 text-[clamp(1.6rem,2.8vw,2.3rem)]">{title}</h3>
        <div className="measure mt-5 space-y-4 text-[16px] text-subtext">{children}</div>
      </div>
      <div className={`min-w-0 lg:col-span-7 ${flip ? "lg:order-1" : ""}`} style={{ ["--i" as string]: 1 }}>
        {figure}
      </div>
    </Reveal>
  );
}
