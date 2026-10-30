import { Link, useLocation } from 'react-router-dom';
import { guideSections } from '../lib/hebrewGuide.js';
export default function HebrewHelp() {
  const { pathname } = useLocation();
  if (import.meta.env.VITE_UI_LANGUAGE !== 'he' || pathname === '/guide') return null;
  const id = pathname.startsWith('/accounts')
    ? 'accounts'
    : pathname.startsWith('/settings')
      ? 'settings'
      : pathname.startsWith('/agent-skills')
        ? 'skills'
        : pathname.startsWith('/post-scripts')
          ? 'post'
          : pathname.startsWith('/severity-rankers')
            ? 'rankers'
            : pathname.startsWith('/workflows') || pathname.startsWith('/steps')
              ? 'workflows'
              : pathname === '/scans/new'
                ? 'scans'
                : pathname.startsWith('/scans')
                  ? 'results'
                  : 'start';
  const s = guideSections.find((s) => s.id === id);
  return (
    <details className="hebrew-help" key={pathname}>
      <summary title="פתיחת הוראות והסברים למסך הנוכחי">ⓘ עזרה למסך הזה — {s.title}</summary>
      <p>{s.text}</p>
      <ol>
        {s.steps.map((step) => (
          <li key={step}>{step}</li>
        ))}
      </ol>
      <Link to={'/guide#' + id}>לפרק המלא במדריך ←</Link>
      <p>
        <Link to="/guide#projects">איך מחברים תיקייה או פרויקט?</Link> · <Link to="/guide">המדריך המלא לכל המסכים</Link>
      </p>
    </details>
  );
}
