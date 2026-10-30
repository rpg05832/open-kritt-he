// Test-only: make "default locale" formatting deterministic (en-US) regardless
// of the language of the computer running the tests. The application itself
// keeps using the viewer's locale.
const DEFAULT_LOCALE = 'en-US';
const pick = (locales) =>
  locales === undefined || (Array.isArray(locales) && locales.length === 0) ? DEFAULT_LOCALE : locales;

for (const name of ['DateTimeFormat', 'NumberFormat', 'RelativeTimeFormat', 'PluralRules', 'ListFormat']) {
  const Original = Intl[name];
  if (!Original) continue;
  const Fixed = function (locales, options) {
    return new Original(pick(locales), options);
  };
  Fixed.prototype = Original.prototype;
  Fixed.supportedLocalesOf = Original.supportedLocalesOf;
  Intl[name] = Fixed;
}

for (const [owner, method] of [
  [Date.prototype, 'toLocaleString'],
  [Date.prototype, 'toLocaleDateString'],
  [Date.prototype, 'toLocaleTimeString'],
  [Number.prototype, 'toLocaleString'],
]) {
  const original = owner[method];
  owner[method] = function (locales, options) {
    return original.call(this, pick(locales), options);
  };
}
