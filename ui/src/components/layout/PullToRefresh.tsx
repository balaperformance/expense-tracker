import { useQueryClient } from '@tanstack/react-query';
import { useEffect, useRef, useState } from 'react';

import { Icon } from '@/components/ui/Icon';

const THRESHOLD = 72;
const MAX_PULL = 110;

/**
 * Pull down at the top of a screen to refresh it (RefreshIndicator). An
 * installed PWA has no browser reload gesture, so this is the only way to
 * ask for fresh figures on demand. Refetches whatever is on screen.
 */
export function PullToRefresh() {
  const client = useQueryClient();
  const [pull, setPull] = useState(0);
  const [refreshing, setRefreshing] = useState(false);
  const [dragging, setDragging] = useState(false);
  const start = useRef<{ y: number; x: number } | null>(null);
  const distance = useRef(0);
  const refreshingRef = useRef(false);

  useEffect(() => {
    const blocked = (target: EventTarget | null) =>
      document.documentElement.style.overflow === 'hidden' ||
      (target instanceof Element && target.closest('[role="dialog"], [role="alertdialog"], textarea, [data-no-pull]') != null);

    const onStart = (event: TouchEvent) => {
      const touch = event.touches[0];
      if (!touch || window.scrollY > 0 || refreshingRef.current || blocked(event.target)) return;
      start.current = { y: touch.clientY, x: touch.clientX };
      distance.current = 0;
    };
    const onMove = (event: TouchEvent) => {
      const origin = start.current;
      const touch = event.touches[0];
      if (!origin || !touch) return;
      const dy = touch.clientY - origin.y;
      if (dy <= 0 || Math.abs(touch.clientX - origin.x) > dy) {
        if (distance.current === 0) start.current = null;
        return;
      }
      // Resistance: the indicator moves slower than the finger.
      distance.current = Math.min(MAX_PULL, dy * 0.5);
      setDragging(true);
      setPull(distance.current);
    };
    const onEnd = () => {
      if (!start.current) return;
      start.current = null;
      setDragging(false);
      if (distance.current >= THRESHOLD * 0.5 + 20) {
        refreshingRef.current = true;
        setRefreshing(true);
        setPull(THRESHOLD * 0.6);
        void client.refetchQueries({ type: 'active' }).finally(() => {
          refreshingRef.current = false;
          setRefreshing(false);
          setPull(0);
        });
      } else {
        setPull(0);
      }
      distance.current = 0;
    };

    document.addEventListener('touchstart', onStart, { passive: true });
    document.addEventListener('touchmove', onMove, { passive: true });
    document.addEventListener('touchend', onEnd);
    document.addEventListener('touchcancel', onEnd);
    return () => {
      document.removeEventListener('touchstart', onStart);
      document.removeEventListener('touchmove', onMove);
      document.removeEventListener('touchend', onEnd);
      document.removeEventListener('touchcancel', onEnd);
    };
  }, [client]);

  const progress = Math.min(1, pull / (THRESHOLD * 0.5 + 20));
  if (pull === 0 && !refreshing) return null;

  return (
    <div
      aria-live="polite"
      aria-label={refreshing ? 'Refreshing' : undefined}
      style={{
        position: 'fixed',
        zIndex: 35,
        top: `calc(var(--safe-top) + ${Math.round(pull)}px)`,
        left: '50%',
        width: 36,
        height: 36,
        marginLeft: -18,
        borderRadius: '50%',
        display: 'grid',
        placeItems: 'center',
        background: 'var(--surface)',
        boxShadow: 'var(--shadow-strong)',
        color: 'var(--primary)',
        opacity: refreshing ? 1 : progress,
        transition: dragging ? 'none' : 'top 200ms var(--ease-standard), opacity 200ms',
      }}
    >
      <span
        style={{
          display: 'grid',
          transform: `rotate(${progress * 270}deg)`,
          animation: refreshing ? 'spin 0.8s linear infinite' : undefined,
        }}
      >
        <Icon name="refresh" size={20} />
      </span>
    </div>
  );
}
