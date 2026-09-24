// Runs before the app bundle so the first paint already has the right theme.
// Mirrors ThemePreference in src/state/settings.tsx (key and values).
(function () {
  var mode = 'system';
  try {
    var saved = localStorage.getItem('et.theme');
    if (saved === 'light' || saved === 'dark' || saved === 'system') mode = saved;
  } catch (_) {
    // Storage can be unavailable (private mode); the system theme applies.
  }
  var dark =
    mode === 'dark' ||
    (mode === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  var root = document.documentElement;
  root.setAttribute('data-theme', dark ? 'dark' : 'light');
  root.style.colorScheme = dark ? 'dark' : 'light';

  // iOS reads the standalone status-bar style as the app launches: white
  // text over the page in dark mode, the standard dark-on-light otherwise,
  // so the clock and battery are always legible.
  var bar = document.querySelector('meta[name="apple-mobile-web-app-status-bar-style"]');
  if (bar) bar.setAttribute('content', dark ? 'black-translucent' : 'default');
})();
