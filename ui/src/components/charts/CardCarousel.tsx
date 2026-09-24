import { useEffect, useRef, useState, type ReactNode } from 'react';

import { Card } from '@/components/ui/Surface';

import styles from './Charts.module.css';

export type CarouselPage = { title: string; caption?: string; content: ReactNode };

/**
 * Swipeable chart cards with a title that follows the page (CardCarousel).
 * Advances itself every [intervalMs] — but never while the user is touching
 * it, while the tab is hidden, or when reduced motion is requested.
 */
export function CardCarousel({ pages, height, intervalMs = 10_000 }: { pages: CarouselPage[]; height: number; intervalMs?: number }) {
  const track = useRef<HTMLDivElement>(null);
  const [index, setIndex] = useState(0);
  const interacting = useRef(false);
  const current = pages[Math.min(index, pages.length - 1)];

  // Follow the scroll position so the title and dots always match the card.
  useEffect(() => {
    const node = track.current;
    if (!node) return;
    let frame = 0;
    const onScroll = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const width = node.clientWidth || 1;
        setIndex(Math.round(node.scrollLeft / width));
      });
    };
    node.addEventListener('scroll', onScroll, { passive: true });
    return () => {
      node.removeEventListener('scroll', onScroll);
      cancelAnimationFrame(frame);
    };
  }, []);

  useEffect(() => {
    if (pages.length < 2) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const timer = setInterval(() => {
      const node = track.current;
      if (!node || interacting.current || document.hidden) return;
      const next = (Math.round(node.scrollLeft / (node.clientWidth || 1)) + 1) % pages.length;
      node.scrollTo({ left: next * node.clientWidth, behavior: 'smooth' });
    }, intervalMs);
    return () => clearInterval(timer);
  }, [pages.length, intervalMs]);

  if (!current) return null;

  return (
    <section aria-roledescription="carousel" aria-label="Charts">
      <div className={styles.carouselHead}>
        <h2 key={current.title} className={`t-section ${styles.carouselTitle}`}>
          {current.title}
        </h2>
        {current.caption ? <span className="t-label-sm">{current.caption}</span> : null}
        {pages.length > 1 ? (
          <div className={styles.dots} aria-hidden>
            {pages.map((page, i) => (
              <span key={page.title} className={[styles.dot, i === index && styles.dotOn].filter(Boolean).join(' ')} />
            ))}
          </div>
        ) : null}
      </div>
      <div
        ref={track}
        className={styles.track}
        onPointerDown={() => (interacting.current = true)}
        onPointerUp={() => (interacting.current = false)}
        onPointerCancel={() => (interacting.current = false)}
        onMouseEnter={() => (interacting.current = true)}
        onMouseLeave={() => (interacting.current = false)}
      >
        {pages.map((page, i) => (
          <div
            key={page.title}
            className={styles.page}
            style={{ height }}
            aria-roledescription="slide"
            aria-label={`${page.title}, card ${i + 1} of ${pages.length}`}
          >
            <Card>{page.content}</Card>
          </div>
        ))}
      </div>
    </section>
  );
}
