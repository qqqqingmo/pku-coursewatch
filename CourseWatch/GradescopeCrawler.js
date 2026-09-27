const empty = (loginRequired, warning = '', scanComplete = false) => JSON.stringify({
  loginRequired, scanComplete, entries: [], warnings: warning ? [warning] : []
});
if (location.hostname !== 'www.gradescope.com') return empty(true);
if (!/^\d+$/.test(gradescopeCourseID)) return empty(false, 'Gradescope 课程编号无效。');
const courseURL = 'https://www.gradescope.com/courses/' + gradescopeCourseID;
const normalizeDate = raw => {
  if (!raw) return null;
  const iso = new Date(raw.replace(' ', 'T').replace(/ ([+-]\d{2})(\d{2})$/, '$1:$2'));
  return Number.isFinite(iso.getTime()) ? iso.toISOString() : raw;
};
try {
  const response = await fetch(courseURL, { credentials: 'same-origin', cache: 'no-store' });
  if (response.status === 401 || response.status === 403 || /\/login(?:\?|$)/.test(response.url || '')) return empty(true);
  if (!response.ok) return empty(false, 'Gradescope 返回 ' + response.status + '。');
  const doc = new DOMParser().parseFromString(await response.text(), 'text/html');
  if (doc.querySelector('#session_email, form[action="/login"]') ||
      /Log In \| Gradescope|Log in with your Gradescope account/i.test(doc.title || '')) return empty(true);
  const table = doc.querySelector('#assignments-student-table');
  if (!table) return empty(false, 'Gradescope 作业表格暂未出现，请检查“' + courseName + '”课程。');
  const entries = [];
  for (const row of table.querySelectorAll('tbody tr')) {
    const anchor = row.querySelector('a[href*="/assignments/"]');
    const button = row.querySelector('button[data-assignment-id]');
    const title = (button?.getAttribute('data-assignment-title') ||
      row.querySelector('th')?.textContent || anchor?.textContent || '').replace(/\s+/g, ' ').trim();
    const assignmentID = button?.getAttribute('data-assignment-id') ||
      anchor?.getAttribute('href')?.match(/\/assignments\/(\d+)/)?.[1];
    if (!assignmentID) continue;
    const assignmentURL = new URL('/courses/' + gradescopeCourseID + '/assignments/' + assignmentID, courseURL);
    if (assignmentURL.origin !== location.origin || !title) continue;
    const times = [...row.querySelectorAll('time[datetime]')].map(node => node.getAttribute('datetime'));
    const due = row.querySelector('time.submissionTimeChart--dueDate')?.getAttribute('datetime') ||
      (times.length > 1 ? times[1] : times[0]);
    const release = row.querySelector('time.submissionTimeChart--releaseDate')?.getAttribute('datetime') ||
      (times.length > 1 ? times[0] : null);
    const detail = row.textContent.replace(/\s+/g, ' ').trim().slice(0, 500);
    const submissionStatus = row.querySelector('.submissionStatus--text')?.textContent || '';
    entries.push({
      id: 'gradescope|' + gradescopeCourseID + '|' + assignmentID,
      courseID: courseId,
      courseName,
      kind: '作业',
      title,
      detail,
      url: assignmentURL.href,
      postedAt: normalizeDate(release),
      dueAt: normalizeDate(due),
      completed: /\bSubmitted\b|\bGraded\b/i.test(submissionStatus) &&
        !/\bNot Submitted\b|\bNo Submission\b/i.test(submissionStatus)
    });
  }
  if (table.querySelectorAll('tbody tr').length && !entries.length) {
    return empty(false, 'Gradescope 作业列表格式已变化，请检查同步。');
  }
  return JSON.stringify({ loginRequired: false, scanComplete: true, entries, warnings: [] });
} catch (error) {
  return empty(false, 'Gradescope 同步失败：' + String(error.message || error));
}
