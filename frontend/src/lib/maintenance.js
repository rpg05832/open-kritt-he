const base = 'http://127.0.0.1:5180';
export async function maintenance(path, options = {}) {
  const response = await fetch(base + path, {
    ...options,
    headers: {
      'X-Kritt-Management': '1',
      ...(options.body && !(options.body instanceof File) ? { 'Content-Type': 'application/json' } : {}),
      ...options.headers,
    },
  });
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(data.error || 'עוזר התחזוקה לא הצליח להשלים את הפעולה.');
  }
  return response.json();
}
export async function maintenanceDownload(path, name) {
  const response = await fetch(base + path, { headers: { 'X-Kritt-Management': '1' } });
  if (!response.ok) throw new Error('ההורדה נכשלה.');
  const url = URL.createObjectURL(await response.blob());
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}
