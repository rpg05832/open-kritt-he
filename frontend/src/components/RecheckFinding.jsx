import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { api } from '../api/client.js';
import HelpTip from './HelpTip.jsx';
export default function RecheckFinding({ scan, finding }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const navigate = useNavigate();
  async function run() {
    setBusy(true);
    setError('');
    try {
      const skillIds = scan.agentSkillIds?.length
        ? scan.agentSkillIds
        : (await api.agentSkills()).filter((s) => s.slug?.startsWith('he-')).map((s) => s.id);
      const result = await api.createScan({
        workflowId: scan.workflowId,
        postScriptId: scan.postScriptId,
        agentSkillIds: skillIds,
        repo_kind: scan.repoKind || 'remote',
        repo_full: scan.repoFull,
        commit_sha: scan.repoKind === 'local' ? undefined : 'HEAD',
        repo_scope: 'Focused recheck of the selected finding in current code',
        dependencies: (scan.dependencies || []).map((d) => ({
          kind: d.kind,
          repo_full: d.repoFull || d.repo_full,
          commit_sha: d.kind === 'local' ? null : 'HEAD',
        })),
        configuration: {
          ...scan.configuration,
          scan_mode: 'full',
          incremental_baseline_id: null,
          security_preflight: true,
          targeted_review: {
            source_scan_id: scan.id,
            finding_id: finding.id,
            file: finding.file_path,
            line: finding.line,
            summary: finding.summary,
            explanation: finding.explanation,
          },
        },
        model: scan.model,
        model_provider: scan.modelProvider,
        harness: scan.harness,
        thinking_effort: scan.thinkingEffort,
        extra: scan.extra || {},
        severity_ranker: scan.severityRanker || '',
        jobLimit: 12,
        launchPolicy: 'queue',
      });
      navigate(`/scans/${result.id}`);
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }
  return (
    <div style={{ marginBlock: 12 }}>
      <button type="button" disabled={busy} onClick={run}>
        {busy ? 'מכין בדיקה…' : 'בדיקת הממצא מחדש בקוד העדכני'}
      </button>
      <HelpTip
        term="בדיקה חוזרת לממצא"
        description="נוצרת בדיקה חדשה על התיקייה העדכנית או HEAD בגיטהאב, עם הנחיה להתמקד בממצא ובהגנות הקשורות אליו. הפעולה משתמשת במכסת המודל. הדוח המקורי נשמר, והיעדר ממצא אינו לבדו הוכחת תיקון."
      />
      {error && <p role="alert">לא ניתן להתחיל: {error}</p>}
    </div>
  );
}
