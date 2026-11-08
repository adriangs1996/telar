import type { MDXComponents } from "mdx/types";
import Link from "next/link";
import { Note, Tip, Warning } from "@/components/docs/Callout";
import DocCards from "@/components/docs/DocCards";

// A heading carries a self-link, as each heading's anchor is its address.
function heading(Tag: "h2" | "h3" | "h4") {
  return function Heading({ id, children }: { id?: string; children?: React.ReactNode }) {
    return (
      <Tag id={id}>
        {children}
        {id && (
          <a href={`#${id}`} className="docs-anchor" aria-label="Link to this section">
            #
          </a>
        )}
      </Tag>
    );
  };
}

const components: MDXComponents = {
  h2: heading("h2"),
  h3: heading("h3"),
  h4: heading("h4"),
  a: ({ href = "", children }) =>
    href.startsWith("/") || href.startsWith("#") ? <Link href={href}>{children}</Link> : <a href={href}>{children}</a>,
  table: ({ children }) => (
    <div className="docs-table">
      <table>{children}</table>
    </div>
  ),
  Note,
  Tip,
  Warning,
  DocCards,
};

export function useMDXComponents(): MDXComponents {
  return components;
}
