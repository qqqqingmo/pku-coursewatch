const empty = (loginRequired, warning = '', scanComplete = false) => JSON.stringify({
  loginRequired, scanComplete, entries: [], warnings: warning ? [warning] : []
});
if (location.hostname !== 'class.pku.edu.cn') return empty(true);
const token = localStorage.getItem('token');
if (!token) return empty(true);
const get = async path => {
  const response = await fetch('/api' + path, {
    headers: { Authorization: 'Bearer ' + token, Accept: 'application/json' },
    cache: 'no-store'
  });
  if (response.status === 401) return { unauthorized: true };
  if (!response.ok) throw new Error('北大问学返回 ' + response.status);
  return response.json();
};
const list = value => Array.isArray(value) ? value :
  Array.isArray(value?.data) ? value.data :
  Array.isArray(value?.items) ? value.items :
  Array.isArray(value?.courses) ? value.courses :
  Array.isArray(value?.homeworks) ? value.homeworks : null;
const date = value => {
  if (!value) return null;
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString() : String(value);
};
const clean = value => String(value || '').replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
const normalized = value => String(value || '').normalize('NFKC').toLowerCase()
  .replace(/[^\p{L}\p{N}]+/gu, '');
const now = new Date();
const isFall = now.getMonth() >= 7 || now.getMonth() === 0;
const academicYear = now.getMonth() >= 7 ? now.getFullYear() : now.getFullYear() - 1;
const currentTerm = course => {
  const semester = String(course.semester || '');
  if (!semester) return true;
  if (!semester.includes(String(academicYear))) return false;
  if (semester.includes('秋') || semester.includes('春')) {
    return semester.includes(isFall ? '秋' : '春');
  }
  const term = semester.match(/(?:^|[-_/])([12])$/);
  return !term || Number(term[1]) === (isFall ? 1 : 2);
};
try {
  const courseResponse = await get('/courses/my?role=student');
  if (courseResponse.unauthorized) return empty(true);
  const courses = list(courseResponse);
  if (!courses) return empty(false, '北大问学课程列表格式已变化，请检查同步。');
  const selected = Array.isArray(targets) ? targets.filter(t => t?.id && normalized(t.name).length >= 4) : [];
  const entries = [];
  for (const course of courses.filter(currentTerm)) {
    const name = normalized(course.name);
    if (name.length < 4) continue;
    const target = selected
      .filter(t => {
        const wanted = normalized(t.name);
        return name === wanted || name.startsWith(wanted) || wanted.startsWith(name);
      })
      .sort((a, b) => normalized(b.name).length - normalized(a.name).length)[0];
    if (!target) continue;
    const result = await get('/courses/' + encodeURIComponent(course.id) + '/homeworks/detail');
    if (result.unauthorized) return empty(true);
    const homeworks = list(result);
    if (!homeworks) return empty(false, '北大问学作业列表格式已变化，请检查同步。');
    for (const homework of homeworks) {
      if (!homework.id || !homework.title || /^(draft|草稿)$/i.test(homework.status || '')) continue;
      entries.push({
        id: 'class|' + course.id + '|' + homework.id,
        courseID: target.id,
        courseName: target.name,
        kind: '作业',
        title: clean(homework.title),
        detail: clean(homework.description).slice(0, 500),
        url: 'https://class.pku.edu.cn/homework/' + homework.id,
        postedAt: date(homework.published_at || homework.created_at),
        dueAt: date(homework.deadline),
        completed: !!(homework.user_submission || homework.submission)
      });
    }
  }
  return JSON.stringify({ loginRequired: false, scanComplete: true, entries, warnings: [] });
} catch (error) {
  return empty(false, '北大问学同步失败：' + String(error.message || error));
}
