import { useEffect, useRef } from 'react';

/** Calls [onReach] when the returned sentinel comes within ~400px of the viewport. */
export function useInfiniteScroll(onReach: () => void, enabled: boolean) {
  const sentinel = useRef<HTMLDivElement>(null);
  const callback = useRef(onReach);
  useEffect(() => {
    callback.current = onReach;
  });
  useEffect(() => {
    const node = sentinel.current;
    if (!node || !enabled) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry?.isIntersecting) callback.current();
      },
      { rootMargin: '0px 0px 400px 0px' },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [enabled]);
  return sentinel;
}
