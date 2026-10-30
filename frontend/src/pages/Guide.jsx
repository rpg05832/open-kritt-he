import { Link } from 'react-router-dom';
import { usePageChrome } from '../context/ui.jsx';
import { guideSections } from '../lib/hebrewGuide.js';
export default function Guide() {
  usePageChrome([{ label: 'מדריך למשתמש', active: true }], null, []);
  return (
    <main className="user-guide" dir="rtl">
      <h1>מדריך Open-Kritt בעברית</h1>
      <p>כל שלבי העבודה בשפה פשוטה. בכל מסך אפשר לפתוח עזרה מותאמת, וכאן נמצאים כל הפרקים.</p>
      <nav className="guide-toc" aria-label="תוכן עניינים">
        {guideSections.map((s) => (
          <a key={s.id} href={'#' + s.id}>
            {s.title}
          </a>
        ))}
      </nav>
      {guideSections.map((s) => (
        <section id={s.id} key={s.id}>
          <h2>{s.title}</h2>
          <p>{s.text}</p>
          <ol>
            {s.steps.map((step) => (
              <li key={step}>{step}</li>
            ))}
          </ol>
          <Link to={s.to}>פתיחת המסך המתאים ←</Link>
        </section>
      ))}
    </main>
  );
}
