import { useState } from 'react';
import { Link } from 'react-router-dom';
import { prioritizeFindings } from '../lib/remediation.js';
import HelpTip from './HelpTip.jsx';
import { findingSeverity } from '../lib/format.js';

export default function RemediationPlan({ scanId, findings }) {
  const key = `open-kritt-remediation-${scanId}`;
  const [states, setStates] = useState(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(key) || '{}');
      return saved && typeof saved === 'object' && !Array.isArray(saved) ? saved : {};
    } catch {
      return {};
    }
  });
  const [storageError, setStorageError] = useState(false);
  const ordered = prioritizeFindings(findings);
  const done = ordered.filter((f) => states[f.id] === 'fixed').length;
  if (!ordered.length) return null;
  function update(id, value) {
    const next = { ...states, [id]: value };
    setStates(next);
    try {
      localStorage.setItem(key, JSON.stringify(next));
      setStorageError(false);
    } catch {
      setStorageError(true);
    }
  }
  return (
    <section className="scan-journey">
      <h2>
        תוכנית תיקון{' '}
        <HelpTip description="רשימת עבודה לפי חומרה. סימון שתיקנת הוא תיעוד שלך בלבד ואינו הוכחה שהחולשה נפתרה. הנתונים נשמרים בדפדפן במחשב הזה." />
      </h2>
      <p>
        סומנו כתוקנו: {done} מתוך {ordered.length}. מומלץ להתחיל בחומרה הגבוהה, לקרוא את הראיות ולוודא שהתיקון אינו פוגע
        בפעולה הרגילה.
      </p>
      {storageError && <p role="alert">לא ניתן לשמור את הסימונים בדפדפן. הסימונים יישמרו רק עד סגירת המסך.</p>}
      <ol>
        {ordered.map((f) => (
          <li key={f.id} style={{ marginBlock: '1rem' }}>
            <Link to={`/scans/${scanId}/vulnerabilities/${f.id}`}>{f.summary || 'ממצא אבטחה'}</Link>
            <p>
              <bdi>
                {f.file_path}:{f.line}
              </bdi>{' '}
              · {findingSeverity(f) || 'ללא דירוג'} · {f.exploitable ? 'סומן כניתן לניצול; ראו ראיות' : 'ניצול לא אושר'}
            </p>
            <label>
              מצב הטיפול שלך:{' '}
              <select value={states[f.id] || 'todo'} onChange={(e) => update(f.id, e.target.value)}>
                <option value="todo">ממתין לבדיקה</option>
                <option value="working">בטיפול</option>
                <option value="fixed">תיקנתי — נדרש אימות מחדש</option>
                <option value="dismissed">לדעתי התראה שגויה — נדרש נימוק ובדיקה</option>
              </select>
            </label>
          </li>
        ))}
      </ol>
      <p>לאחר התיקון הפעילו בדיקה נוספת על הקוד המעודכן. הסימונים אינם משנים את ממצאי הדוח המקורי.</p>
    </section>
  );
}
