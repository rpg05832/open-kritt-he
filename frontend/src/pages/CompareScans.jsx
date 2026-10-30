import { useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { api } from '../api/client.js';
import { useFetch } from '../lib/useFetch.js';
import { compareFindings } from '../lib/compareFindings.js';
import { usePageChrome } from '../context/ui.jsx';
import HelpTip from '../components/HelpTip.jsx';

export default function CompareScans() {
  usePageChrome([{ label: 'השוואת בדיקות', active: true }], null, []);
  const [params] = useSearchParams();
  const [left, setLeft] = useState(params.get('left') || '');
  const [right, setRight] = useState('');
  const { data: scans, error: listError } = useFetch(() => api.scans(), []);
  const first = scans?.find((s) => String(s.id) === left);
  const second = scans?.find((s) => String(s.id) === right);
  const compatible = first && second && first.repoFull === second.repoFull && first.repoKind === second.repoKind;
  const { data, loading, error } = useFetch(async () => {
    if (!compatible || left === right) return null;
    const [before, after] = await Promise.all([api.scanVulnerabilities(left), api.scanVulnerabilities(right)]);
    return compareFindings(before, after);
  }, [left, right, Boolean(compatible)]);
  function list(title, items, scanId) {
    return (
      <section>
        <h2>
          {title}: {items.length}
        </h2>
        <ul>
          {items.map((f) => (
            <li key={f.id}>
              <Link to={`/scans/${scanId}/vulnerabilities/${f.id}`}>
                {f.summary || 'ממצא'} —{' '}
                <bdi>
                  {f.file_path}:{f.line}
                </bdi>
              </Link>
            </li>
          ))}
        </ul>
      </section>
    );
  }
  return (
    <main className="user-guide">
      <h1>
        מה השתנה בין הבדיקות?{' '}
        <HelpTip
          term="השוואת דוחות"
          description="ההשוואה מתאימה ממצאים לפי קובץ, סוג ותיאור. שינוי בניסוח יכול להיראות כממצא חדש. ממצא שלא זוהה שוב אינו בהכרח מתוקן, במיוחד בבדיקה חלקית או ממוקדת בשינויים."
        />
      </h1>
      <p>בחרו שתי בדיקות של אותו פרויקט. ממצא שלא הופיע בבדיקה השנייה מסומן כ״לא זוהה שוב״, ולא כתיקון מאומת.</p>
      {[
        [left, setLeft, 'הבדיקה הקודמת'],
        [right, setRight, 'הבדיקה להשוואה'],
      ].map(([value, change, label]) => (
        <label key={label} style={{ display: 'block', marginBlock: 16 }}>
          {label}
          <select value={value} onChange={(e) => change(e.target.value)}>
            <option value="">בחרו בדיקה</option>
            {scans?.map((s) => (
              <option key={s.id} value={s.id}>
                #{s.id} — {s.repoDisplay || s.repoFull} — {s.status}
              </option>
            ))}
          </select>
        </label>
      ))}
      {listError && <p role="alert">לא ניתן לטעון את רשימת הבדיקות.</p>}
      {left && right && !compatible && <p role="alert">יש לבחור בדיקות של אותו פרויקט.</p>}
      {left && left === right && <p>בחרו שתי בדיקות שונות.</p>}
      {compatible && (first.status !== 'completed' || second.status !== 'completed') && (
        <p>אחת הבדיקות טרם הושלמה. ההשוואה זמנית וחלקית.</p>
      )}
      {loading && compatible && <p>משווה תוצאות…</p>}
      {error && <p role="alert">לא ניתן להשוות כרגע.</p>}
      {data && (
        <>
          {list('ממצאים חדשים בדוח השני', data.added, right)}
          {list(
            'ממצאים שזוהו בשתי הבדיקות',
            data.persistent.map((pair) => pair.after),
            right
          )}
          {list('ממצאים מהדוח הראשון שלא זוהו שוב', data.notDetected, left)}
        </>
      )}
    </main>
  );
}
