import type { Metadata } from "next";
import { notFound } from "next/navigation";
import PageHeading from "@/components/docs/PageHeading";
import { DOC_SECTIONS, findDoc } from "@/lib/docs";

type Props = { params: Promise<{ slug: string }> };

// Every page in lib/docs.ts is prerendered; any other slug is a 404.
export function generateStaticParams() {
  return DOC_SECTIONS.flatMap((section) => section.pages.map((page) => ({ slug: page.slug })));
}

export const dynamicParams = false;

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params;
  const doc = findDoc(slug);
  return doc ? { title: doc.page.title, description: doc.page.lead } : {};
}

export default async function DocPage({ params }: Props) {
  const { slug } = await params;
  if (!findDoc(slug)) notFound();
  const { default: Content } = await import(`@/content/docs/${slug}.mdx`);

  return (
    <>
      <PageHeading slug={slug} />
      <article className="doc">
        <Content />
      </article>
    </>
  );
}
