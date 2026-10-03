import { useRef, type MouseEvent, type PointerEvent } from 'react';

/**
 * Long-press on touch, right-click with a mouse. iOS Safari fires no
 * `contextmenu` for a long press, so touch is timed here.
 */
export function useLongPress(onLongPress: (() => void) | undefined, ms = 520) {
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const origin = useRef<{ x: number; y: number } | null>(null);
  // The click that follows a long press is not a tap.
  const fired = useRef(false);
  if (!onLongPress) return {};
  const cancel = () => {
    clearTimeout(timer.current);
    origin.current = null;
  };
  return {
    onPointerDown: (event: PointerEvent) => {
      fired.current = false;
      if (event.pointerType === 'mouse') return;
      origin.current = { x: event.clientX, y: event.clientY };
      timer.current = setTimeout(() => {
        origin.current = null;
        fired.current = true;
        // Not every browser has vibrate (Safari does not).
        if ('vibrate' in navigator) navigator.vibrate(10);
        onLongPress();
      }, ms);
    },
    onClickCapture: (event: MouseEvent) => {
      if (!fired.current) return;
      fired.current = false;
      event.preventDefault();
      event.stopPropagation();
    },
    onPointerMove: (event: PointerEvent) => {
      const start = origin.current;
      if (start && Math.hypot(event.clientX - start.x, event.clientY - start.y) > 10) cancel();
    },
    onPointerUp: cancel,
    onPointerCancel: cancel,
    onContextMenu: (event: MouseEvent) => {
      event.preventDefault();
      cancel();
      onLongPress();
    },
  };
}
