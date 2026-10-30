import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useFetch } from '../lib/useFetch.js';
import { maintenance, maintenanceDownload } from '../lib/maintenance.js';
import { usePageChrome } from '../context/ui.jsx';
import HelpTip from '../components/HelpTip.jsx';
export default function Maintenance() {
  usePageChrome([{ label: 'מצב המערכת ותחזוקה', active: true }], null, []);
  const { data, error, reload } = useFetch(() => maintenance('/status'), [], { pollMs: 3000 });
  const [diagnostics, setDiagnostics] = useState(null);
  const [message, setMessage] = useState('');
  const [busy, setBusy] = useState(false);
  const [release, setRelease] = useState(null);
  const [confirmation, setConfirmation] = useState(null);
  const working = busy || data?.jobs?.some((job) => ['queued', 'running'].includes(job.status));
  async function perform(task) {
    setBusy(true);
    setMessage('');
    try {
      await task();
      reload();
    } catch (e) {
      setMessage(e.message);
    } finally {
      setBusy(false);
    }
  }
  async function action(operation, extra = {}) {
    await perform(() => maintenance('/action', { method: 'POST', body: JSON.stringify({ operation, ...extra }) }));
  }
  return (
    <main className="user-guide">
      <h1>מצב המערכת ותחזוקה</h1>
      <p>כלי ניהול מקומיים לתוכנה הזאת. אין צורך להכיר פקודות מחשב.</p>
      <section>
        <h2>הכנת המחשב ותיקון רכיבים חסרים</h2>
        <p>
          האשף בודק את Docker, את החיבור לאינטרנט ואת הסינון, ומסביר בדיוק מה חסר: תעודת רשת, כתובת חסומה, תקלת רשת או
          רכיב תוכנה. אפשר להתקין את Docker הרשמי, לאשר תעודת רשת ולבנות מחדש את רכיבי התוכנה. אם התוכנה עצמה לא נפתחת,
          אפשר להפעיל את האשף גם מהקיצור &quot;בדיקה ותיקון&quot; בשולחן העבודה או מהקובץ Prepare.cmd.
        </p>
        <button
          disabled={busy || !data}
          onClick={() =>
            perform(async () => {
              const result = await maintenance('/prepare', { method: 'POST' });
              setMessage(
                result.alreadyOpen
                  ? 'אשף הבדיקה והתיקון כבר פתוח בחלון נפרד.'
                  : 'אשף הבדיקה והתיקון נפתח בחלון נפרד במחשב. אם אינו מופיע, חפשו אותו בשורת המשימות.'
              );
            })
          }
        >
          פתיחת אשף הבדיקה והתיקון
        </button>
        <HelpTip
          term="הכנת המחשב"
          description="נפתח חלון Windows מקומי. תעודות מתווספות לקובצי הבנייה של התוכנה בלבד, לאחר הצגת הרשות וטביעת האצבע ואישורכם. רכיבים חיצוניים מורדים ממקורות רשמיים. תנאי ספק והרשאות מנהל נשארים לבחירתכם."
        />
      </section>
      {error && (
        <p role="alert">
          עוזר התחזוקה המקומי אינו זמין. הפעילו את התוכנה דרך מנהל ההפעלה שלה, או סגרו ופתחו את מנהל ההפעלה.{' '}
          <button onClick={reload}>ניסיון נוסף</button>
        </p>
      )}
      {message && <p role="alert">{message}</p>}
      {busy && <p role="status">מבצע את הבקשה, נא להמתין…</p>}
      <section>
        <h2>
          בדיקת תקינות{' '}
          <HelpTip
            term="אבחון"
            description="מציג את זמינות Docker, השרת והממשק ואת השימוש הנמדד במשאבים. הבדיקה אינה מפעילה סריקת AI ואינה משנה הגדרות."
          />
        </h2>
        <button
          disabled={busy || !data}
          onClick={() => perform(async () => setDiagnostics(await maintenance('/diagnostics')))}
        >
          בדיקת מצב עכשיו
        </button>
        {diagnostics && (
          <>
            <p>
              נמדד: {new Date(diagnostics.measuredAt).toLocaleString('he-IL')} · Docker:{' '}
              {diagnostics.dockerReady ? 'מגיב' : 'לא זמין — פתחו Docker Desktop והמתינו להפעלתו'}
            </p>
            <ul>
              {diagnostics.services.map((s) => (
                <li key={s.name}>
                  {{
                    'open-kritt-engine': 'מנוע הבדיקות',
                    'open-kritt-backend': 'שרת התוכנה',
                    'open-kritt-frontend': 'ממשק התוכנה',
                    'open-kritt-executor-view': 'שירות חיבור החשבונות',
                    'open-kritt-db': 'מסד הנתונים',
                  }[s.name] || s.name}
                  :{' '}
                  {s.status.startsWith('Up')
                    ? 'פועל'
                    : s.status.startsWith('Restarting')
                      ? 'מנסה לפעול מחדש'
                      : s.status.startsWith('Exited')
                        ? 'נעצר'
                        : 'מצב דורש בדיקה'}
                  {s.status.includes('(unhealthy)')
                    ? ' — בדיקת התקינות נכשלה'
                    : s.status.includes('(healthy)')
                      ? ' — בדיקת התקינות תקינה'
                      : ''}
                </li>
              ))}
            </ul>
            <ul>
              {diagnostics.checks.map((check) => (
                <li key={check.url}>
                  {check.url.includes('3002') ? 'שרת התוכנה' : 'ממשק התוכנה'}:{' '}
                  {check.ready ? 'מגיב' : 'לא מגיב — נסו להפעיל מחדש דרך מנהל ההפעלה'}
                </li>
              ))}
            </ul>
            <details>
              <summary>זיכרון ועומס מעבד שנמדדו</summary>
              <pre dir="ltr">{diagnostics.resources || 'אין נתוני משאבים זמינים'}</pre>
            </details>
          </>
        )}
        <p>
          לתקלות התחברות או מכסת מודל: <Link to="/accounts">חשבונות</Link>. להמתנה לזיכרון:{' '}
          <Link to="/settings">הגדרות משאבים</Link>. אין צורך להגדיל את מגבלת Docker כדי להשתמש במסך הזה.
        </p>
      </section>
      <section>
        <h2>
          גיבוי ושחזור{' '}
          <HelpTip
            term="גיבוי"
            description="הגיבוי כולל את מסד הנתונים: סריקות, ממצאים, תהליכים, מיומנויות והגדרות שנשמרו בו. הוא אינו כולל את תיקיות הקוד, חיבורי החשבונות וקובצי ההגדרות המקומיים. שמרו גם עותק של תיקיית ההתקנה להעברה למחשב אחר."
          />
        </h2>
        <p>
          הגיבוי נשמר במחשב בתיקיית ‎.maintenance/backups שבתוך תיקיית ההתקנה. אפשר להוריד עותק נוסף. הוא עשוי לכלול
          מידע רגיש מהדוחות.
        </p>
        <button disabled={working || !data} onClick={() => action('Backup')}>
          יצירת גיבוי להיסטוריה ולהגדרות
        </button>
        <label style={{ display: 'block', marginBlock: 16 }}>
          ייבוא גיבוי ממחשב אחר:{' '}
          <input
            type="file"
            accept=".dump"
            disabled={working || !data}
            onChange={(e) => {
              const file = e.target.files[0];
              if (file)
                perform(() =>
                  maintenance('/backup-import', {
                    method: 'POST',
                    body: file,
                    headers: { 'Content-Type': 'application/octet-stream' },
                  })
                );
              e.target.value = '';
            }}
          />
        </label>
        <ul>
          {data?.backups?.map((backup) => (
            <li key={backup.id} style={{ marginBlock: 14 }}>
              {new Date(backup.createdAt).toLocaleString('he-IL')} · {(backup.bytes / 1024 / 1024).toFixed(2)} MB{' '}
              {backup.imported && '· יובא מקובץ'}{' '}
              <button
                disabled={busy}
                onClick={() =>
                  perform(() => maintenanceDownload(`/backup/${backup.id}`, `open-kritt-${backup.id}.dump`))
                }
              >
                הורדת עותק
              </button>{' '}
              <button
                disabled={working}
                onClick={() =>
                  setConfirmation({
                    operation: 'Restore',
                    backupId: backup.id,
                    text: 'השחזור יחליף את היסטוריית הבדיקות וההגדרות שבמסד הנתונים במצב שבגיבוי. קודם ייווצר גיבוי למצב הנוכחי. הפעולה מותרת רק כשאין בדיקות פעילות. שחזרו רק קובץ שאתם סומכים על מקורו.',
                  })
                }
              >
                שחזור הגיבוי הזה
              </button>
            </li>
          ))}
        </ul>
        <p>לפני שחזור או עדכון נוצר גיבוי נוסף. תיקיות הפרויקטים והחשבונות אינם נמחקים בפעולות האלה.</p>
      </section>
      <section>
        <h2>
          עדכוני תוכנה{' '}
          <HelpTip
            term="עדכון תוכנה"
            description="התוכנה בודקת אם יצאה גרסה חדשה. לפני ההתקנה העדכון מאומת, ונוצר גיבוי של הקוד ושל הנתונים."
          />
        </h2>
        <button
          disabled={working || !data}
          onClick={() => perform(async () => setRelease(await maintenance('/release')))}
        >
          בדיקת עדכון
        </button>
        {release && (
          <p>
            {release.status === 'not_configured' ? (
              release.message
            ) : release.status === 'current' ? (
              'חבילת הגרסה האחרונה כבר מותקנת.'
            ) : (
              <>
                זמינה חבילה: <bdi>{release.version}</bdi> ·{' '}
                <a href={release.releaseUrl} target="_blank" rel="noreferrer">
                  פרטי הגרסה
                </a>
              </>
            )}
          </p>
        )}
        {release?.status === 'available' && (
          <button
            disabled={working}
            onClick={() =>
              setConfirmation({
                operation: 'Install',
                text: 'העדכון יורד, מאומת ומגובה לפני ההתקנה. שירותי התוכנה ייעצרו זמנית לכמה דקות.',
              })
            }
          >
            התקנת העדכון
          </button>
        )}
        {data?.canRollback && (
          <button
            disabled={working}
            onClick={() =>
              setConfirmation({
                operation: 'Rollback',
                text: 'הפעולה תחזיר את הקוד ואת היסטוריית מסד הנתונים למצב שלפני העדכון האחרון. מידע שנוסף מאז לא יופיע לאחר החזרה, אך יישמר קודם בגיבוי חדש.',
              })
            }
          >
            חזרה לגרסה שלפני העדכון
          </button>
        )}
      </section>
      <section>
        <h2>התקדמות פעולות התחזוקה</h2>
        <ul>
          {data?.jobs?.map((job) => (
            <li key={job.id} style={{ marginBlock: 12 }}>
              {job.status === 'completed' ? '✓' : job.status === 'failed' ? '⚠' : '⏳'} {job.message}
              {job.result?.packageId && (
                <div>
                  <button
                    onClick={() =>
                      perform(() =>
                        maintenanceDownload(`/package/${job.result.packageId}/zip`, 'open-kritt-hebrew-update.zip')
                      )
                    }
                  >
                    הורדת ZIP
                  </button>{' '}
                  <button
                    onClick={() =>
                      perform(() =>
                        maintenanceDownload(`/package/${job.result.packageId}/json`, 'open-kritt-hebrew-update.json')
                      )
                    }
                  >
                    הורדת קובץ אימות
                  </button>
                </div>
              )}
            </li>
          ))}
        </ul>
      </section>
      {confirmation && (
        <section
          role="dialog"
          aria-modal="true"
          aria-label="אישור פעולת תחזוקה"
          className="scan-journey"
          style={{
            position: 'fixed',
            top: '50%',
            left: '50%',
            transform: 'translate(-50%, -50%)',
            zIndex: 1000,
            width: 'min(560px, 90vw)',
            maxHeight: '80vh',
            overflowY: 'auto',
            padding: 24,
            background: 'var(--surface)',
            border: '2px solid var(--accent)',
            boxShadow: '0 0 0 100vmax #0008',
          }}
        >
          <h2>אישור הפעולה</h2>
          <p>{confirmation.text}</p>
          <button
            disabled={working}
            onClick={() => {
              const next = confirmation;
              setConfirmation(null);
              action(next.operation, { ...next, confirm: 'APPLY' });
            }}
          >
            הבנתי, לבצע
          </button>{' '}
          <button onClick={() => setConfirmation(null)}>ביטול</button>
        </section>
      )}
    </main>
  );
}
