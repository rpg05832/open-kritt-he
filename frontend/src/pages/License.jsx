import { useState } from 'react';
import { useFetch } from '../lib/useFetch.js';
import { usePageChrome } from '../context/ui.jsx';
import { HEBREW_IMPROVEMENTS } from '../lib/hebrewImprovements.js';

const profile = 'https://mitmachim.top/user/%D7%90%D7%A8%D7%99';
export default function License() {
  usePageChrome([{ label: 'רישיון וקרדיטים', active: true }], null, []);
  const [query, setQuery] = useState('');
  const { data } = useFetch(async () => {
    const response = await fetch('/legal/inventory.json');
    if (!response.ok) throw new Error('לא ניתן לטעון את מלאי הרישיונות');
    return response.json();
  }, []);
  const matches = (data?.packages || []).filter((p) =>
    [p.name, p.version, p.license, p.component].join(' ').toLowerCase().includes(query.toLowerCase())
  );
  return (
    <main className="user-guide">
      <h1>רישיון וקרדיטים</h1>
      <section>
        <h2>הגרסה שלנו</h2>
        <p>
          הגרסה העברית, התוספות והשיפורים בוצעו על ידי{' '}
          <a href={profile} target="_blank" rel="noreferrer">
            <bdi>@ארי</bdi> ממתמחים טופ
          </a>
          .
        </p>
        <p>
          יצירת קשר:{' '}
          <a href="mailto:rpg05832@gmail.com">
            <bdi>rpg05832@gmail.com</bdi>
          </a>
          .
        </p>
        <p>זו גרסה עצמאית מותאמת, ואינה גרסה רשמית של הפרויקט המקורי.</p>
        <details id="improvements" className="credit-improvements" open={window.location.hash === '#improvements'}>
          <summary>מה נוסף בגרסה העברית? (לחצו לפתיחה)</summary>
          <ul>
            {HEBREW_IMPROVEMENTS.map((item) => (
              <li key={item.title}>
                <strong>{item.title}:</strong> {item.text}
              </li>
            ))}
          </ul>
          <p>הפרויקט המקורי, הרעיון והמנוע שייכים ליוצרי open·kritt. הרשימה מתארת רק את התוספות של הגרסה הזאת.</p>
        </details>
      </section>
      <section>
        <h2>הפרויקט המקורי ורישיון הקוד</h2>
        <p>
          מבוסס על{' '}
          <a href="https://github.com/Kritt-ai/open-kritt" target="_blank" rel="noreferrer">
            open·kritt
          </a>{' '}
          של Harel Rom ו־Gabriel Balko, בכפוף לזכויות נוספות המפורטות במסמך הבעלות המקורי.
        </p>
        <p>
          קוד האפליקציה וההתאמות מופצים תחת <strong>GNU AGPL‑3.0-only</strong>. ההודעות והזכויות המקוריות נשמרות. לרכיבי
          צד שלישי ולכלים חיצוניים יש רישיונות נפרדים.
        </p>
        <p>
          מותר להשתמש בתוכנה, לשנות אותה ולשתף אותה לפי תנאי הרישיון. קוד המקור המלא נמצא בתיקיית ההתקנה, בתיקייה{' '}
          <bdi>app</bdi>.
        </p>
        <p>התוכנה ניתנת כמות שהיא, ללא אחריות במידה שהדין מאפשר. תוצאות הסריקה אינן התחייבות לאיתור כל חולשה.</p>
        <ul>
          <li>
            <a href="/legal/LICENSE" target="_blank" rel="noreferrer">
              הרישיון המלא — הנוסח המקורי באנגלית
            </a>
          </li>
          <li>
            <a href="/legal/NOTICE.md" target="_blank" rel="noreferrer">
              קרדיטים והודעת שינויים
            </a>
          </li>
          <li>
            <a href="/legal/OWNERSHIP.md" target="_blank" rel="noreferrer">
              מסמך הבעלות של הפרויקט המקורי
            </a>
          </li>
          <li>
            <a href="/legal/THIRD_PARTY_NOTICES.md" download>
              הורדת הודעות צד שלישי
            </a>
          </li>
          <li>
            <a href="/legal/inventory.json" download>
              הורדת מלאי הרכיבים והרישיונות
            </a>
          </li>
        </ul>
      </section>
      <section>
        <h2>רכיבי צד שלישי</h2>
        <label>
          חיפוש לפי שם, רישיון או רכיב מערכת
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="למשל Semgrep, React, Apache, LGPL"
          />
        </label>
        <p>מוצגות עד 100 רשומות מתוך {matches.length} תוצאות. חפשו כדי לצמצם את הרשימה, או הורידו את המלאי המלא.</p>
        {matches.slice(0, 100).map((p, index) => (
          <details key={`${p.component}:${p.name}:${index}`} style={{ marginBlock: 10 }}>
            <summary>
              <bdi>
                {p.name}@{p.version}
              </bdi>{' '}
              — {p.license}
            </summary>
            <p>
              סביבה: <bdi>{p.component}</bdi> · מקור מטא־נתונים: {p.ecosystem}
              {p.declaredOnly && ' — הצהרה בקובץ נעילה; החבילה לא זוהתה בהתקנות שנבדקו'}.
            </p>
            <p>
              {p.review === 'vendor-terms'
                ? 'כפוף לתנאי השימוש של הספק.'
                : p.review === 'conditions-required'
                  ? 'חלים תנאי הרישיון של הרכיב.'
                  : p.review === 'not-applicable'
                    ? 'חבילת תלות וירטואלית ריקה; רישיונות החבילות הממשיות מפורטים בנפרד.'
                    : 'הודעות הרישוי של הרכיב נשמרות בתוכנה.'}
            </p>
            <ul>
              {p.notices
                .filter((n) => /^[a-f0-9]{64}$/.test(n.hash))
                .map((n, i) => (
                  <li key={i}>
                    <a href={`/legal/texts/${n.hash}.txt`} target="_blank" rel="noreferrer">
                      {n.name} — נוסח שנאסף מהרכיב
                    </a>
                  </li>
                ))}
            </ul>
          </details>
        ))}
      </section>
      <section>
        <h2>מיומנויות ומקורות ידע</h2>
        <p>
          קישורי המקור והייחוסים נשמרים גם במסך המיומנויות. תיאורי גישור מקומיים אינם העתק מלא של חבילת המיומנויות
          המקורית.
        </p>
        <ul>
          {data?.skills.map((skill) => (
            <li key={skill.slug}>
              {skill.name} — {skill.licenseSpdx || 'לא צוין'}{' '}
              {skill.sourceUrl?.startsWith('https://') && (
                <a href={skill.sourceUrl} target="_blank" rel="noreferrer">
                  מקור וקרדיט
                </a>
              )}
            </li>
          ))}
        </ul>
      </section>
    </main>
  );
}
