import { useFetch } from '../lib/useFetch.js';
import { Link } from 'react-router-dom';
export default function SecurityCoverage({ scanId, status }) {
  const live = status && !['completed', 'failed', 'stopped'].includes(status);
  const { data, error, loading, reload } = useFetch(
    async () => {
      const r = await fetch(`/api/scans/${scanId}/security-coverage`);
      if (!r.ok) throw new Error('לא ניתן לטעון כיסוי');
      return r.json();
    },
    [scanId],
    { pollMs: live ? 5000 : 0 }
  );
  return (
    <section className="scan-journey">
      <h2>מה נבדק בפועל?</h2>
      <button type="button" onClick={reload} disabled={loading}>
        רענון נתוני כלי הבדיקה
      </button>
      {loading ? (
        <p>טוען דוח כיסוי…</p>
      ) : error ? (
        <p>דוח כלי הבדיקה אינו זמין כרגע. אין להסיק מכך שהכלים בוצעו.</p>
      ) : data?.available === false ? (
        <p>{data.reason} דוח זה נוצר רק בבדיקות חדשות בגרסה 2.</p>
      ) : (
        data && (
          <>
            <p>
              הכלי המקומי בדק {data.files_checked} קובצי טקסט; נראו {data.files_seen} קבצים ודולגו {data.files_skipped}.
              נמצאו {data.candidates?.length || 0} תבניות חשודות — אלה אינן חולשות מאומתות.
            </p>
            {data.generated_at && (
              <p>
                עודכן: {new Date(data.generated_at * 1000).toLocaleString('he-IL')} · משך הרצת הכלים:{' '}
                {data.duration_seconds ?? 'לא נמדד'} שניות.
              </p>
            )}
            {data.incremental && (
              <div>
                <h3>היקף ניתוח ה־AI</h3>
                <p>
                  {data.incremental.effective_mode === 'changes' ? 'בדיקה ממוקדת בשינויים ובהקשר שלהם' : 'בדיקה מלאה'}.
                  {data.incremental.baseline_scan_id && (
                    <>
                      {' '}
                      בסיס להשוואה:{' '}
                      <Link to={`/scans/${data.incremental.baseline_scan_id}`}>
                        בדיקה {data.incremental.baseline_scan_id}
                      </Link>
                      .
                    </>
                  )}{' '}
                  {data.incremental.reason}
                </p>
                {data.incremental.effective_mode === 'changes' && (
                  <details>
                    <summary>
                      נוספו {data.incremental.added.length}, שונו {data.incremental.modified.length}, נמחקו{' '}
                      {data.incremental.deleted.length} קבצים
                    </summary>
                    <ul>
                      {['added', 'modified', 'deleted'].flatMap((kind) =>
                        data.incremental[kind].map((file) => (
                          <li key={`${kind}:${file}`}>
                            <bdi>{file}</bdi> — {{ added: 'נוסף', modified: 'שונה', deleted: 'נמחק' }[kind]}
                          </li>
                        ))
                      )}
                    </ul>
                  </details>
                )}
              </div>
            )}
            {data.dependency_audit && (
              <div>
                <h3>חולשות מוכרות בספריות — OSV</h3>
                <p>
                  מצב:{' '}
                  {{
                    completed: 'הבדיקה הסתיימה',
                    partial: 'בדיקה חלקית — חלק מהתלויות או מהתוצאות לא נבדקו',
                    unavailable: 'החיבור נכשל או נחסם',
                    disabled: 'החיבור כבוי',
                    no_supported_packages: 'לא נמצאו ספריות עם גרסאות מדויקות בפורמט הנתמך',
                  }[data.dependency_audit.status] || 'לא ידוע'}
                  .
                </p>
                <p>
                  נבדקו {data.dependency_audit.checked_packages || 0} גרסאות ספריות. נמצאו התאמות למאגר ב־
                  {data.dependency_audit.findings?.length || 0} ספריות.
                  {data.dependency_audit.reused &&
                    ' נעשה שימוש בתוצאה מאותה סריקה, בת פחות משעה, עבור רשימת ספריות שלא השתנתה.'}
                </p>
                <p>
                  התאמה למאגר היא סיבה לבדיקה ולעדכון; היא אינה מוכיחה שניתן לנצל את החולשה בפרויקט הזה. לא נשלח קוד
                  למאגר.
                </p>
                {data.dependency_audit.findings?.length > 0 && (
                  <details>
                    <summary>ספריות הדורשות בדיקה</summary>
                    <ul>
                      {data.dependency_audit.findings.map((f, index) => (
                        <li key={index}>
                          <bdi>
                            {f.name}@{f.version}
                          </bdi>{' '}
                          — <bdi>{f.file}</bdi>
                          <ul>
                            {f.ids.map((id) => (
                              <li key={id}>
                                <a
                                  href={`https://osv.dev/vulnerability/${encodeURIComponent(id)}`}
                                  target="_blank"
                                  rel="noreferrer"
                                >
                                  {id}
                                </a>
                              </li>
                            ))}
                          </ul>
                        </li>
                      ))}
                    </ul>
                  </details>
                )}
                <ul>
                  {data.dependency_audit.limitations?.map((text) => (
                    <li key={text}>{text}</li>
                  ))}
                </ul>
              </div>
            )}
            <ul>
              {data.checks?.map((c) => (
                <li key={c}>{c}</li>
              ))}
            </ul>
            <h3>לא בוצע בכלי המקומי</h3>
            <ul>
              {data.not_run?.map((c) => (
                <li key={c}>{c}</li>
              ))}
            </ul>
            <h3>מגבלות הכיסוי</h3>
            {data.semgrep && (
              <div>
                <h3>Semgrep — ניתוח מבנה הקוד</h3>
                <p>
                  מצב:{' '}
                  {{
                    completed: 'הסתיים',
                    partial: 'הסתיים עם מגבלות',
                    unavailable: 'אינו מותקן',
                    failed: 'נכשל',
                    timeout: 'הגיע למגבלת הזמן',
                  }[data.semgrep.status] || 'לא ידוע'}
                  .{data.semgrep.reused && ' נעשה שימוש בתוצאה קודמת מאותה סריקה עבור קוד שלא השתנה.'}{' '}
                  {data.semgrep.files_checked ?? 0} קבצים נבדקו, {data.semgrep.candidates?.length || 0} חשדות נמצאו. אלו
                  אינם ממצאים מאומתים.
                </p>
                <p>
                  {data.semgrep.rule_count ?? 4} כללים מקומיים בשפות Python, JavaScript/TypeScript, PHP, Java, Go, C#
                  ו־Ruby. זו אינה חבילת כללי Semgrep מלאה.
                </p>
              </div>
            )}
            {[
              [
                'secrets',
                'Gitleaks — סודות בקוד ובהיסטוריה',
                'מפתחות, סיסמאות ואסימונים. הערך עצמו לעולם אינו נשמר בדוח.',
              ],
              [
                'configuration',
                'Trivy — קובצי הגדרות',
                'Dockerfile, Kubernetes, Terraform ותהליכי CI. הבדיקה רצה בלי אינטרנט.',
              ],
              [
                'dependency_scanner',
                'OSV-Scanner — ספריות בכל מנהלי החבילות',
                'רץ רק כשבדיקת הספריות המקוונת מופעלת, ושולח למאגר OSV שמות וגרסאות של ספריות בלבד.',
              ],
            ].map(([key, title, note]) =>
              data[key] ? (
                <div key={key}>
                  <h3>{title}</h3>
                  <p>
                    מצב:{' '}
                    {{
                      completed: 'הסתיים',
                      disabled: 'כבוי בבדיקה הזאת',
                      unavailable: 'אינו מותקן',
                      failed: 'נכשל',
                      timeout: 'הגיע למגבלת הזמן',
                    }[data[key].status] || 'לא ידוע'}
                    .{data[key].reused && ' נעשה שימוש בתוצאה קודמת עבור קוד שלא השתנה.'}{' '}
                    {(data[key].candidates || data[key].findings)?.length || 0} חשדות נמצאו. אלו אינם ממצאים מאומתים.
                  </p>
                  <p>{note}</p>
                </div>
              ) : null
            )}
            {data.quality && <QualityCoverage quality={data.quality} />}
            <ul>
              {data.limitations?.map((c) => (
                <li key={c}>{c}</li>
              ))}
            </ul>
            <p>
              זהו דוח הכלי המקומי בלבד. ניתוח ה־AI ואימות הממצאים מוצגים בנפרד; מספר קבצים אינו הוכחה שכל מסלול קוד
              נבדק.
            </p>
          </>
        )
      )}
    </section>
  );
}

const TOOL_STATUS = {
  completed: 'הסתיים',
  unavailable: 'אינו מותקן',
  failed: 'נכשל',
  timeout: 'הגיע למגבלת הזמן',
};

// Local code-quality tool results (scan kinds "quality" and "both").
export function QualityCoverage({ quality }) {
  const tools = [
    ['lint_python', 'Ruff — באגים נפוצים ב־Python'],
    ['lint_javascript', 'Biome — באגים ובעיות ב־JavaScript/TypeScript'],
    ['complexity', 'Lizard — פונקציות מסובכות או ארוכות מדי'],
    ['duplication', 'jscpd — קוד כפול בין קבצים'],
  ];
  const tests = quality.tests;
  return (
    <div>
      <h3>תקינות קוד — כלים מקומיים</h3>
      <ul>
        {tools.map(([key, title]) =>
          quality[key] ? (
            <li key={key}>
              {title}: {TOOL_STATUS[quality[key].status] || 'לא ידוע'}, {quality[key].candidates?.length || 0} חשדות
              {key === 'duplication' && quality[key].duplication_percentage != null
                ? ` (${Math.round(quality[key].duplication_percentage)}% מהשורות כפולות)`
                : ''}
              .
            </li>
          ) : null
        )}
      </ul>
      {tests?.languages && (
        <p>
          קובצי בדיקות:{' '}
          {Object.entries(tests.languages)
            .map(([language, counts]) => `${language} ${counts.test_files} מול ${counts.source_files} קובצי קוד`)
            .join(' · ')}
          {tests.languages_without_tests?.length > 0 && (
            <strong> אין בדיקות כלל ל: {tests.languages_without_tests.join(', ')}.</strong>
          )}
        </p>
      )}
      <p>אלו רמזים לבדיקה ולא ממצאים מאומתים. ה־AI בודק כל אחד מהם בקוד לפני דיווח.</p>
    </div>
  );
}
