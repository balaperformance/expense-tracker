import { useEffect, useLayoutEffect, useRef } from 'react';
import { NavigationType, NavLink, Outlet, useLocation, useNavigate, useNavigationType } from 'react-router';

import { Button } from '@/components/ui/Button';
import { Icon, type IconName } from '@/components/ui/Icon';
import { APP_NAME } from '@/domain/defaults';

import { BrandMark } from './Brand';
import styles from './Layout.module.css';
import { PullToRefresh } from './PullToRefresh';

type Destination = { to: string; label: string; icon: IconName; activeIcon: IconName };

const DESTINATIONS: Destination[] = [
  { to: '/', label: 'Home', icon: 'home', activeIcon: 'homeActive' },
  { to: '/expenses', label: 'Expenses', icon: 'expenses', activeIcon: 'expensesActive' },
  { to: '/income', label: 'Income', icon: 'income', activeIcon: 'incomeActive' },
  { to: '/reports', label: 'Reports', icon: 'reports', activeIcon: 'reports' },
  { to: '/settings', label: 'Settings', icon: 'settings', activeIcon: 'settingsActive' },
];

const TAB_PATHS = new Set(DESTINATIONS.map((d) => d.to));

/**
 * The signed-in frame. Phones get the floating glass pill (on the five tab
 * screens only, as the Flutter shell does); desktops get a side rail that
 * stays for every screen.
 */
export function AppShell() {
  const location = useLocation();
  const navigate = useNavigate();
  const isTab = TAB_PATHS.has(location.pathname);
  const activeIndex = DESTINATIONS.findIndex((d) => d.to === location.pathname);

  // Scroll memory, as the Flutter shell's IndexedStack gives for free: each
  // tab keeps its own position, Back returns to where the user was, and a
  // newly opened screen starts at the top.
  const navigationType = useNavigationType();
  const positions = useRef(new Map<string, number>());
  const scrollKey = isTab ? location.pathname : location.key;
  const currentKey = useRef(scrollKey);
  useEffect(() => {
    const onScroll = () => positions.current.set(currentKey.current, window.scrollY);
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);
  useLayoutEffect(() => {
    currentKey.current = scrollKey;
    const saved = positions.current.get(scrollKey);
    const restore = saved != null && (navigationType === NavigationType.Pop || isTab);
    window.scrollTo({ top: 0, behavior: 'instant' });
    if (!restore) return;
    // Wait for the (cached) content to lay out before restoring.
    let frame = requestAnimationFrame(() => {
      frame = requestAnimationFrame(() => window.scrollTo({ top: saved, behavior: 'instant' }));
    });
    return () => cancelAnimationFrame(frame);
  }, [scrollKey, navigationType, isTab]);

  return (
    <div className={[styles.shell, isTab && styles.shellWithNav].filter(Boolean).join(' ')}>
      <aside className={styles.rail} aria-label="Main">
        <div className={styles.railBrand}>
          <BrandMark size={38} />
          <span className="t-title-lg" style={{ fontSize: 18 }}>
            {APP_NAME}
          </span>
        </div>
        <nav className={styles.railNav}>
          {DESTINATIONS.map((d) => (
            <NavLink
              key={d.to}
              to={d.to}
              end={d.to === '/'}
              className={({ isActive }) => [styles.railItem, isActive && styles.railItemOn].filter(Boolean).join(' ')}
            >
              {({ isActive }) => (
                <>
                  <Icon name={isActive ? d.activeIcon : d.icon} size={21} />
                  {d.label}
                </>
              )}
            </NavLink>
          ))}
          <NavLink
            to="/accounts"
            className={({ isActive }) => [styles.railItem, isActive && styles.railItemOn].filter(Boolean).join(' ')}
          >
            <Icon name="bank" size={21} />
            Accounts
          </NavLink>
          <NavLink
            to="/cards"
            className={({ isActive }) => [styles.railItem, isActive && styles.railItemOn].filter(Boolean).join(' ')}
          >
            <Icon name="card" size={21} />
            Credit cards
          </NavLink>
          <NavLink
            to="/assistant"
            className={({ isActive }) => [styles.railItem, isActive && styles.railItemOn].filter(Boolean).join(' ')}
          >
            <Icon name="assistant" size={21} />
            Assistant
          </NavLink>
        </nav>
        <div className={styles.railSpacer} />
        <div className={styles.railFoot}>
          <Button label="Add expense" icon="add" block onClick={() => void navigate('/expenses/new')} />
          <Button label="Add income" icon="incomeAdd" variant="tonal" block onClick={() => void navigate('/income/new')} />
        </div>
      </aside>

      <div className={styles.main}>
        <PullToRefresh />
        <Outlet />
      </div>

      {isTab ? (
        <nav className={styles.nav} aria-label="Main">
          <span
            className={styles.navHighlight}
            style={{ transform: `translateX(${Math.max(activeIndex, 0) * 100}%)` }}
            aria-hidden
          />
          {DESTINATIONS.map((d, i) => (
            <NavLink
              key={d.to}
              to={d.to}
              end={d.to === '/'}
              replace
              aria-label={d.label}
              title={d.label}
              className={[styles.navItem, i === activeIndex && styles.navItemOn].filter(Boolean).join(' ')}
            >
              <Icon name={i === activeIndex ? d.activeIcon : d.icon} size={21} />
            </NavLink>
          ))}
        </nav>
      ) : null}
    </div>
  );
}
