import { useRef, useState } from 'react';
const ignored = new Set(['.git', 'node_modules', '.venv', 'venv', '__pycache__', 'dist', 'build', '.next']);
const binaryExtensions = new Set(
  'png jpg jpeg gif webp ico bmp svg mp3 wav ogg mp4 mov avi mkv woff woff2 ttf otf pdf doc docx xls xlsx ppt pptx zip rar 7z gz tar exe dll so dylib bin iso db sqlite sqlite3'.split(
    ' '
  )
);
function skip(parts, includeAssets = false) {
  return (
    parts.some((p) => ignored.has(p)) ||
    (!includeAssets && binaryExtensions.has(parts.at(-1).split('.').at(-1).toLowerCase())) ||
    (/^\.env(?:\..*)?$/.test(parts.at(-1)) && !/\.(example|sample|template)$/.test(parts.at(-1)))
  );
}
async function request(body) {
  const r = await fetch('/api/local-repos/import', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await r.json();
  if (!r.ok) throw new Error(data.error);
  return data;
}
export default function ImportProject({ onImported }) {
  const input = useRef();
  const [allFiles, setAllFiles] = useState([]);
  const [includeAssets, setIncludeAssets] = useState(false);
  const cancelled = useRef(false);
  const [largeApproved, setLargeApproved] = useState(false);
  const [percent, setPercent] = useState(0);
  const [files, setFiles] = useState([]);
  const [name, setName] = useState('');
  const [status, setStatus] = useState('');
  const [busy, setBusy] = useState(false);
  const [excluded, setExcluded] = useState(0);
  const totalBytes = files.reduce((n, f) => n + f.size, 0);
  const largestFile = files.reduce((n, f) => Math.max(n, f.size), 0);
  const large = files.length > 4000 || totalBytes > 100 * 1024 * 1024 || largestFile > 4 * 1024 * 1024;
  function choose(e) {
    setLargeApproved(false);
    setPercent(0);
    const all = [...e.target.files];
    setAllFiles(all);
    const selected = all.filter((f) => !skip(f.webkitRelativePath.split('/').slice(1), includeAssets));
    setFiles(selected);
    setExcluded(all.length - selected.length);
    setName(all[0]?.webkitRelativePath.split('/')[0] || '');
    setStatus('');
  }
  async function upload() {
    if (large && !largeApproved) {
      setStatus('יש לאשר את האזהרה לפני ההעתקה.');
      return;
    }
    cancelled.current = false;
    setPercent(0);
    setBusy(true);
    let id;
    try {
      ({ id } = await request({
        action: 'start',
        name,
        totalBytes,
        totalFiles: files.length,
        largestFile,
        largeApproved,
      }));
      let completed = 0;
      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        if (file.size <= 65536) {
          const batch = [];
          let batchBytes = 0;
          let j = i;
          for (
            ;
            j < files.length && batch.length < 32 && files[j].size <= 65536 && batchBytes + files[j].size <= 512 * 1024;
            j++
          ) {
            if (cancelled.current) throw new Error('ההעתקה בוטלה. המקור נשאר במקומו.');
            const small = files[j];
            const encoded = await new Promise((resolve, reject) => {
              const r = new FileReader();
              r.onload = () => resolve(String(r.result).split(',')[1] || '');
              r.onerror = () => reject(new Error('קריאת קובץ נכשלה'));
              r.readAsDataURL(small);
            });
            batch.push({
              relative: small.webkitRelativePath.split('/').slice(1).join('/'),
              size: small.size,
              base64: encoded,
            });
            batchBytes += small.size;
          }
          await request({ action: 'batch', id, files: batch });
          completed += batchBytes;
          setPercent(totalBytes ? Math.floor((completed / totalBytes) * 100) : Math.floor((j / files.length) * 100));
          setStatus('הועתקו ' + j + ' מתוך ' + files.length + ' קבצים');
          i = j - 1;
          continue;
        }

        for (let offset = 0; offset < file.size || offset === 0; offset += 1024 * 1024) {
          if (cancelled.current) throw new Error('ההעתקה בוטלה. המקור נשאר במקומו.');
          const blob = file.slice(offset, Math.min(offset + 1024 * 1024, file.size));
          const encoded = await new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result).split(',')[1] || '');
            reader.onerror = () => reject(new Error('קריאת הקובץ נכשלה'));
            reader.readAsDataURL(blob);
          });
          await request({
            action: 'chunk',
            id,
            relative: file.webkitRelativePath.split('/').slice(1).join('/'),
            offset,
            size: file.size,
            base64: encoded,
          });
          completed += blob.size;
          setPercent(
            totalBytes ? Math.floor((completed / totalBytes) * 100) : Math.floor(((i + 1) / files.length) * 100)
          );
          setStatus(
            'מעתיק קובץ ' +
              (i + 1) +
              ' מתוך ' +
              files.length +
              ' — ' +
              (completed / 1048576).toFixed(1) +
              ' מתוך ' +
              (totalBytes / 1048576).toFixed(1) +
              ' MB'
          );
          if (file.size === 0) break;
        }
      }
      if (cancelled.current) throw new Error('ההעתקה בוטלה. המקור נשאר במקומו.');
      const result = await request({ action: 'finish', id });
      id = null;
      setStatus(`הפרויקט הועתק בהצלחה: ${result.name}. המקור נשאר במקומו.`);
      setFiles([]);
      if (input.current) input.current.value = '';
      await onImported(result.name);
    } catch (e) {
      setStatus(e.message);
      if (id)
        try {
          await request({ action: 'cancel', id });
        } catch {
          /* hidden incomplete import stays unpublished */
        }
    } finally {
      setBusy(false);
    }
  }
  return (
    <section className="auto-plan">
      <h3>העתקת תיקיית פרויקט מהמחשב</h3>
      <p>
        בחרו תיקייה ואז אשרו העתקה. הקבצים יישמרו בתיקיית הפרויקטים של ההתקנה הזו; תיקיית המקור נשארת במקומה. בחירת
        תיקייה אינה מפעילה בדיקת AI.
      </p>
      <input
        ref={input}
        type="file"
        webkitdirectory=""
        multiple
        onChange={choose}
        disabled={busy}
        aria-label="בחירת תיקיית פרויקט להעתקה"
      />
      <p>
        תיקיות התקנה ותוצרים כגון node_modules וקובצי סודות בשם .env מדולגים. בדקו שאין סודות בקבצים אחרים. תיקיות ריקות
        אינן מועתקות.
      </p>
      <label>
        <input
          type="checkbox"
          checked={includeAssets}
          disabled={busy}
          onChange={(e) => {
            const enabled = e.target.checked;
            setIncludeAssets(enabled);
            const selected = allFiles.filter((f) => !skip(f.webkitRelativePath.split('/').slice(1), enabled));
            setFiles(selected);
            setExcluded(allFiles.length - selected.length);
            setLargeApproved(false);
          }}
        />{' '}
        לכלול גם תמונות, מדיה, ארכיונים וקבצים בינאריים
      </label>
      <p>
        ברירת המחדל כוללת קוד, הגדרות, רשימות תלויות ותיעוד הנחוצים לבדיקה. קובצי מדיה וקבצים בינאריים מוכרים מדולגים
        כדי לקצר את ההעתקה. אין זו הבטחה שכל קובץ שנכלל הוא קוד.
      </p>
      {files.length > 0 && (
        <>
          <p>
            {name}: {files.length} קבצים, {(files.reduce((n, f) => n + f.size, 0) / 1048576).toFixed(1)} MB; דולגו{' '}
            {excluded} קבצים. ייווצר שם חדש כדי לא לדרוס פרויקט קיים.
          </p>
          {large && (
            <div role="note">
              <p>
                זו תיקייה גדולה. ההעתקה עשויה לקחת זמן ולצרוך שטח דיסק. קבצים גדולים יועתקו בחלקים. השרת יבדוק שיש מספיק
                מקום פנוי. מגבלות הסריקה נפרדות: ייתכן שלא כל הקבצים ייכללו בבדיקה.
              </p>
              <label>
                <input
                  type="checkbox"
                  checked={largeApproved}
                  disabled={busy}
                  onChange={(e) => setLargeApproved(e.target.checked)}
                />{' '}
                בדקתי את הגודל ואני מאשר העתקת תיקייה גדולה
              </label>
            </div>
          )}
          <button type="button" disabled={busy || (large && !largeApproved)} onClick={upload}>
            אישור העתקה לתיקיית הפרויקטים
          </button>
        </>
      )}
      {busy && (
        <>
          <progress max="100" value={percent} aria-label="התקדמות העתקת התיקייה" />
          <span> {percent}% </span>
          <button
            type="button"
            onClick={() => {
              cancelled.current = true;
              setStatus('מבטל אחרי סיום החלק הנוכחי…');
            }}
          >
            ביטול העתקה
          </button>
        </>
      )}
      <p role="status" aria-live="polite">
        {status}
      </p>
    </section>
  );
}
