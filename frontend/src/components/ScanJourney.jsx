import { Link } from 'react-router-dom';
export default function ScanJourney({ scan }) {
  const s = scan.statusSummary || {};
  const done = scan.status === 'completed';
  const phases = [
    ['הכנת הקוד', !['pending', 'prewarming_cache'].includes(scan.status)],
    ['מיפוי וניתוח', done || ['post_processing'].includes(scan.status)],
    ['אימות וממצאים', done],
    ['דוח מסכם', done],
  ];
  return (
    <section className="scan-journey" aria-label="התקדמות הבדיקה">
      <div className="journey-heading">
        <h2>מסלול הבדיקה</h2>
        <Link className="report-link" to={`/scans/${scan.id}/report`}>
          פתיחת דוח מסכם בעברית
        </Link>
      </div>
      <ol className="journey-phases">
        {phases.map(([name, complete], i) => (
          <li key={name} data-complete={complete}>
            <span>{complete ? '✓' : i + 1}</span>
            {name}
          </li>
        ))}
      </ol>
      <div className="journey-counts">
        <div>
          <strong>
            {s.completedStepLineages ?? s.stepCompletedAttempts ?? 0} / {s.expectedStepLineages ?? 'טרם ידוע'}
          </strong>
          <span>משימות ניתוח שהושלמו מתוך המשימות הידועות</span>
        </div>
        <div>
          <strong>{s.postCompletedAttempts ?? 0}</strong>
          <span>הרצות אימות שהושלמו</span>
        </div>
        <div>
          <strong>{s.activeJobCount ?? 0}</strong>
          <span>משימות פעילות כרגע</span>
        </div>
        <div>
          <strong>{scan.findings ?? 0}</strong>
          <span>ממצאים ברשימה</span>
        </div>
      </div>
      <p>
        מספר המשימות עשוי לגדול כשהסוכן מזהה תחומים חדשים. המונים מתארים ביצוע משימות, ולא אחוז מהקוד שנבדק. ניסיונות
        חוזרים ופעולות אימות יכולים להגדיל את מספר ההרצות.
      </p>
      {done && s.expectedStepLineages > s.completedStepLineages && (
        <p className="journey-warning">
          סטטוס הבדיקה הוא „הושלמה”, אך מונה תחומי הניתוח מצביע על פער. אין לפרש זאת ככיסוי מלא; יש לעיין בשגיאות
          ובתוצאות השלבים.
        </p>
      )}
    </section>
  );
}
