import { useRef, useState, type PointerEvent, type ReactNode } from 'react';

import { Icon } from './Icon';

const THRESHOLD = 0.32;

/**
 * Swipe a row left to delete it (Dismissible, end-to-start). Vertical
 * scrolling is untouched: the gesture only engages once the finger has
 * clearly moved sideways. [onDelete] decides — usually after a confirmation —
 * and the row springs back either way.
 */
export function SwipeRow({ children, onDelete, label = 'Delete' }: { children: ReactNode; onDelete: () => void; label?: string }) {
  const [offset, setOffset] = useState(0);
  const [dragging, setDragging] = useState(false);
  const gesture = useRef<{ x: number; y: number; width: number; engaged: boolean; id: number } | null>(null);

  const onPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (event.pointerType === 'mouse') return;
    gesture.current = {
      x: event.clientX,
      y: event.clientY,
      width: event.currentTarget.offsetWidth,
      engaged: false,
      id: event.pointerId,
    };
  };

  const onPointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const g = gesture.current;
    if (!g) return;
    const dx = event.clientX - g.x;
    const dy = event.clientY - g.y;
    if (!g.engaged) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) {
        gesture.current = null;
        return;
      }
      if (dx < -10 && Math.abs(dx) > Math.abs(dy)) {
        g.engaged = true;
        setDragging(true);
        event.currentTarget.setPointerCapture(g.id);
      } else {
        return;
      }
    }
    setOffset(Math.min(0, Math.max(dx, -g.width)));
  };

  const finish = () => {
    const g = gesture.current;
    gesture.current = null;
    setDragging(false);
    if (g?.engaged && -offset > g.width * THRESHOLD) onDelete();
    setOffset(0);
  };

  const revealed = Math.min(1, -offset / 80);

  return (
    <div style={{ position: 'relative', overflow: 'hidden', touchAction: 'pan-y' }}>
      <div
        aria-hidden
        style={{
          position: 'absolute',
          inset: 0,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'flex-end',
          gap: 8,
          paddingRight: 18,
          background: 'var(--error)',
          color: 'var(--on-error)',
          fontSize: 14,
          fontWeight: 600,
          opacity: revealed,
        }}
      >
        <Icon name="delete" size={20} />
        {label}
      </div>
      <div
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={finish}
        onPointerCancel={finish}
        onClickCapture={(event) => {
          // A swipe must not also count as a tap on the row.
          if (dragging || offset !== 0) {
            event.preventDefault();
            event.stopPropagation();
          }
        }}
        style={{
          position: 'relative',
          background: 'var(--surface)',
          transform: `translateX(${offset}px)`,
          transition: dragging ? 'none' : 'transform 240ms var(--ease-standard)',
        }}
      >
        {children}
      </div>
    </div>
  );
}
