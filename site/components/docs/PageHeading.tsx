import Link from "next/link";
import { findDoc, REPOSITORY } from "@/lib/docs";

// Breadcrumbs, title, lead and source link of one page, from the one table of
// contents in lib/docs.ts.
export default function PageHeading({ slug }: { slug: string }) {
  const doc = findDoc(slug);
  if (!doc) return null;
  const source = `${REPOSITORY}/edit/main/site/content/docs/${slug || "index"}.mdx`;

  return (
    <header className="docs-heading">
      <p className="docs-breadcrumbs">
        <Link href="/docs">Telar Docs</Link>
        {doc.section && (
          <>
            <span aria-hidden="true">/</span>
            <span>{doc.section.title}</span>
          </>
        )}
      </p>
      <h1>{doc.page.title}</h1>
      <p className="docs-lead">{doc.page.lead}</p>
      <a className="docs-edit" href={source}>
        Edit on GitHub
      </a>
    </header>
  );
}
