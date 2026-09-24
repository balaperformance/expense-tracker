import { useCallback, useState } from 'react';

/**
 * State for a sheet that carries data (which account, which budget…).
 * The data outlives `close()` so the sheet can animate out with its content,
 * and `key` changes on every open so the sheet's form starts fresh.
 */
export function useSheet<T>() {
  const [state, setState] = useState<{ data: T | null; open: boolean; key: number }>({ data: null, open: false, key: 0 });
  const open = useCallback((data: T) => setState((s) => ({ data, open: true, key: s.key + 1 })), []);
  const close = useCallback(() => setState((s) => ({ ...s, open: false })), []);
  return { data: state.data, isOpen: state.open, key: state.key, open, close };
}
