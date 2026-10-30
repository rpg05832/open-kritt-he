import SecurityCoverage from '../components/SecurityCoverage.jsx';
import RemediationPlan from '../components/RemediationPlan.jsx';
import { findingSeverity } from '../lib/format.js';
import RecheckFinding from '../components/RecheckFinding.jsx';
import { Link, useParams } from 'react-router-dom';
import { api } from '../api/client.js';
import { useFetch } from '../lib/useFetch.js';
import { usePageChrome } from '../context/ui.jsx';
import Markdown from '../components/Markdown.jsx';
import { Spinner, ErrorState } from '../components/ui.jsx';
export default function ScanReport() {
  const { id } = useParams();
  usePageChrome(
    [
      { label: 'בדיקות', to: '/scans' },
      { label: 'דוח מסכם בעברית', active: true },
    ],
    null,
    []
  );
  const { data, loading, error, reload } = useFetch(async () => {
    const [scan, findings] = await Promise.all([api.scan(id), api.scanVulnerabilities(id)]);
    return { scan, findings };
  }, [id]);
  if (loading) return <Spinner />;
  if (error) return <ErrorState error={error} onRetry={reload} />;
  if (!data) return null;
  const { scan, findings } = data;
  return (
    <main className="user-guide security-report">
      <Link to={`/scans/${id}`}>חזרה לפרטי הבדיקה</Link>
      <h1>דוח אבטחה מסכם</h1>
      <Link to={`/compare?left=${id}`}>השוואה לבדיקה אחרת</Link>
      <p>
        פרויקט: <bdi>{scan.repoDisplay || scan.repoFull}</bdi>
      </p>
      <div className="report-summary">
        <strong>{findings.length} ממצאים</strong>
        <span>{scan.status === 'completed' ? 'הבדיקה הסתיימה' : 'דוח ביניים — הבדיקה טרם הסתיימה'}</span>
        <span>
          מודל: <bdi>{scan.model}</bdi>
        </span>
      </div>
      <p>
        זהו ריכוז התוצאות הקיימות, ללא הפעלת AI נוספת. תוכן הממצאים מוצג בשפה שבה נכתב; טקסט באנגלית אינו מתורגם
        אוטומטית. כל ממצא דורש בחינה אנושית, וממצא שלא אומת אינו בהכרח חולשה מוכחת.
      </p>
      {scan.statusSummary?.expectedStepLineages > scan.statusSummary?.completedStepLineages && (
        <p className="journey-warning">
          יש פער בין תחומי הניתוח שתוכננו לאלו שסומנו כהושלמו. הדוח אינו אישור לסריקה מלאה.
        </p>
      )}
      <button type="button" className="report-link" onClick={() => window.print()}>
        הדפסה / שמירה כ־PDF
      </button>
      {!findings.length && <p>אין ממצאים להצגה כרגע. אין בכך הוכחה שהקוד מאובטח.</p>}
      <SecurityCoverage scanId={id} status={scan.status} />
      <RemediationPlan key={id} scanId={id} findings={findings} />
      {findings.map((f, i) => {
        const answers = [f.postScriptAnswer, ...(f.enrichments || []).map((e) => e.result)].filter(Boolean);
        const reports = answers.flatMap((a) =>
          [a.review_report, a._reserved_report].filter((v) => typeof v === 'string' && v.trim())
        );
        return (
          <section key={f.id}>
            <h2>
              {i + 1}. {f.summary || 'ממצא אבטחה'}
            </h2>
            <p>
              <bdi>
                {f.file_path}:{f.line}
              </bdi>{' '}
              · חומרה: {findingSeverity(f) || 'לא דורגה'} ·{' '}
              {f.exploitable ? 'סומן כניתן לניצול — יש לאמת' : 'ניצול לא אושר'}
            </p>
            <Markdown source={f.explanation || 'לא נרשם הסבר'} />
            {reports.map((report, n) => (
              <div key={n}>
                <h3>בדיקת המשך והמלצות</h3>
                <Markdown source={report} />
              </div>
            ))}
            <Link to={`/scans/${id}/vulnerabilities/${f.id}`}>לראיות, דרך שחזור ופרטים מלאים</Link>
            <RecheckFinding scan={scan} finding={f} />
          </section>
        );
      })}
    </main>
  );
}
