import { useLocation, useNavigate } from 'react-router';

/** Returns to the previous screen, or to [fallback] after a deep link or a fresh launch. */
export function useGoBack(fallback: string) {
  const navigate = useNavigate();
  const location = useLocation();
  return () => {
    if (location.key !== 'default') void navigate(-1);
    else void navigate(fallback, { replace: true });
  };
}
