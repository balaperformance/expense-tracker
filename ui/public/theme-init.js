// Runs before the app bundle so the first paint already has the right theme.
// Mirrors ThemePreference and PalettePreference in src/state/settings.tsx (keys and values).
(function () {
  var mode = 'system';
  var palette = 'current';
  try {
    var saved = localStorage.getItem('et.theme');
    if (saved === 'light' || saved === 'dark' || saved === 'system') mode = saved;
    if (localStorage.getItem('et.palette') === 'matte') palette = 'matte';
  } catch (_) {
    // Storage can be unavailable (private mode); the system theme and current palette apply.
  }
  var dark =
    mode === 'dark' ||
    (mode === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  var root = document.documentElement;
  root.setAttribute('data-theme', dark ? 'dark' : 'light');
  root.setAttribute('data-palette', palette);
  root.style.colorScheme = dark ? 'dark' : 'light';

  // iOS reads the standalone status-bar style as the app launches: white
  // text over the page in dark mode, the standard dark-on-light otherwise,
  // so the clock and battery are always legible.
  var bar = document.querySelector('meta[name="apple-mobile-web-app-status-bar-style"]');
  if (bar) bar.setAttribute('content', dark ? 'black-translucent' : 'default');
})();
