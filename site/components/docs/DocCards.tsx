import Link from "next/link";
import { DOC_SECTIONS } from "@/lib/docs";

// Every page of the documentation, grouped as the sidebar groups them.
export default function DocCards() {
  return (
    <div className="docs-cards">
      {DOC_SECTIONS.map((section) => (
        <section key={section.title}>
          <h2 id={section.title.toLowerCase()}>{section.title}</h2>
          <div className="docs-card-grid">
            {section.pages.map((page) => (
              <Link key={page.slug} href={`/docs/${page.slug}`} className="docs-card">
                <span className="docs-card-title">{page.title}</span>
                <span className="docs-card-lead">{page.lead}</span>
              </Link>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
