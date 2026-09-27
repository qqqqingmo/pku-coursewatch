const origin = 'https://course.pku.edu.cn';
const warnings = [];
const courses = new Map();
const entries = new Map();
const selected = new Set(selectedIds);
const seenPages = new Set();
const queuedPages = new Set();
const skipPath = /logout|signout|delete|remove|submit|download|file\?|edit|modify|gradeCenter|authValidate/i;

function absolute(raw, base) {
  try {
    const url = new URL(raw.replace(/&amp;/g, '&'), base);
    if (url.origin !== origin || skipPath.test(url.href)) return null;
    if (!/^https?:$/.test(url.protocol)) return null;
    return url.href;
  } catch { return null; }
}
function courseId(raw) {
  const decoded = String(raw).replace(/%5F/ig, '_').replace(/&amp;/g, '&');
  return decoded.match(/(?:course_id|courseId|course)\s*[=:]\s*['"]?(_\d+_\d+)/i)?.[1]
    || decoded.match(/(_\d+_1)/)?.[1] || null;
}
function clean(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }
function visibleText(node) {
  if (!node) return '';
  const copy = node.cloneNode(true);
  copy.querySelectorAll('script,style,noscript,template,svg,[hidden],[aria-hidden="true"]').forEach(child => child.remove());
  return clean(copy.textContent);
}
function links(doc, base) {
  return [...doc.querySelectorAll('a[href],a[onclick]')].map(a => {
    const raw = a.getAttribute('href') || '';
    const onclick = a.getAttribute('onclick') || '';
    let url = absolute(raw, base);
    if (!url) {
      const match = onclick.match(/['"](\/webapps\/[^'"]+)['"]/);
      if (match) url = absolute(match[1], base);
    }
    return { url, raw: raw + ' ' + onclick, text: clean(a.textContent || a.title), element: a };
  }).filter(x => x.url && x.text);
}
function discover(doc, base) {
  for (const a of links(doc, base)) {
    const id = courseId(a.raw + ' ' + a.url);
    if (!id || a.text.length > 130 || a.text.length < 2) continue;
    if (/content_id|announcement|uploadAssignment|gradebook/i.test(a.url)) continue;
    if (/^(公告|作业|成绩|课程内容|课程实录|Announcements|Assignments|Grades)$/i.test(a.text)) continue;
    const previous = courses.get(id);
    const portlet = a.element.closest('.portlet');
    const current = /当前学期课程/.test(portlet?.querySelector('.moduleTitle')?.textContent || '');
    const fullName = a.text.includes(':') ? clean(a.text.slice(a.text.indexOf(':') + 1)) : a.text;
    const name = fullName.replace(/\s*[（(]\d{2}-\d{2}学年第\d学期[）)]\s*$/, '').trim();
    if (!previous || current || name.length > previous.name.length)
      courses.set(id, { id, name, url: a.url, current: current || (previous?.current || false) });
  }
}
async function getDoc(url) {
  if (!url || seenPages.has(url) || seenPages.size >= 300) return null;
  seenPages.add(url);
  try {
    const response = await fetch(url, { credentials: 'same-origin', redirect: 'follow', cache: 'no-store' });
    if (!response.ok) { warnings.push('部分页面无法读取（' + response.status + '）'); return null; }
    if (/\/webapps\/(login|bb-sso-BBLEARN\/login)/i.test(response.url)) return { login: true };
    const html = await response.text();
    return new DOMParser().parseFromString(html, 'text/html');
  } catch { warnings.push('部分课程页面读取失败'); return null; }
}
function sectionKind(text, url) {
  if (/公告|通知|announcement/i.test(text) || /\/execute\/announcement/i.test(url)) return '公告';
  if (/作业|提交|assignment|homework/i.test(text) || /uploadAssignment/i.test(url)) return '作业';
  if (/实录|回放|录像|录播|recording|replay/i.test(text) || /videoList\.action/i.test(url)) return '课程实录';
  if (/成绩|评分|grade|score/i.test(text) || /myGrades/i.test(url)) return '成绩';
  if (/大纲|syllabus/i.test(text)) return '课程大纲';
  if (/内容|资料|课件|讲义|文件|课程文档|教材|content|material|resource/i.test(text) || /listContent\.jsp/i.test(url)) return '教学内容';
  return null;
}
function dateFrom(text, due) {
  const marker = due ? /(?:截止|提交期限|到期|due\s*date|deadline)[^\d]{0,15}/i
                     : /(?:发布|创建|日期|posted|created|modified)[^\d]{0,15}/i;
  const m = text.match(marker);
  const source = m ? text.slice(m.index + m[0].length) : (due ? '' : text);
  const dated = source.match(/(20\d{2})[-/.年](\d{1,2})[-/.月](\d{1,2})/);
  const shortDate = due && !dated ? source.match(/(\d{1,2})月(\d{1,2})日/) : null;
  if (!dated && !shortDate) return null;
  const pad = x => String(x).padStart(2, '0');
  const d = dated || shortDate;
  const year = dated ? Number(d[1]) : new Date().getFullYear();
  const month = dated ? d[2] : d[1];
  const day = dated ? d[3] : d[2];
  const rest = source.slice(d.index + d[0].length, d.index + d[0].length + 60);
  const clock = rest.match(/(\d{1,2})[:：](\d{2})/);
  const chinese = rest.match(/(上午|下午|中午|凌晨|晚上)[^\d]{0,8}(\d{1,2})(?:时(\d{1,2})分|[:：](\d{2}))/);
  let hour = due ? 23 : 0, minute = due ? 59 : 0;
  if (chinese) {
    hour = Number(chinese[2]); minute = Number(chinese[3] || chinese[4]);
    if (/(下午|中午|晚上)/.test(chinese[1]) && hour < 12) hour += 12;
    if (/(上午|凌晨)/.test(chinese[1]) && hour === 12) hour = 0;
  } else if (clock) { hour = Number(clock[1]); minute = Number(clock[2]); }
  return `${year}-${pad(month)}-${pad(day)} ${pad(hour)}:${pad(minute)}`;
}
function addItem(course, node, base, context) {
  const text = visibleText(node);
  if (text.length < 3 || text.length > 2500) return;
  const heading = node.querySelector('h3,h4,h2,strong,th');
  const headingAnchor = heading?.querySelector('a[href]');
  const anchor = headingAnchor || node.querySelector('.item a,td a,a[href]');
  const title = clean(headingAnchor?.textContent || heading?.textContent || anchor?.textContent || text.split(/\n/)[0]);
  if (title.length < 3 || title.length > 180 || /^(查看|编辑|下载|详情|返回|课程主页|目录)$/i.test(title)) return;
  const raw = headingAnchor?.getAttribute('href') || '';
  let url = absolute(raw, base) || base;
  if (url === base && raw) {
    try {
      const external = new URL(raw, base);
      if (external.hostname === 'courseweb.pku.edu.cn' && external.protocol === 'https:') url = external.href;
    } catch { }
  }
  const pageKind = sectionKind(context, base);
  const titleKind = sectionKind(title, '');
  const kind = pageKind === '公告' ? '公告'
    : (titleKind === '课程大纲' || pageKind === '课程大纲' ? '课程大纲'
      : (/\/bbcswebdav\/|\/listContent\.jsp/i.test(url) ? '教学内容' : (titleKind || pageKind || '教学内容')));
  const idPart = node.id || node.getAttribute('data-content-id') || url + '|' + title;
  const id = course.id + '|' + kind + '|' + idPart;
  const detail = text.slice(0, 500);
  entries.set(id, { id, courseID: course.id, courseName: course.name, kind,
                    title, detail, url, sourcePageURL: base,
                    postedAt: dateFrom(text, false), dueAt: dateFrom(text, true) });
}
function scanItems(doc, course, base, context) {
  const pageKind = sectionKind(context, base);
  if (pageKind === '课程实录') {
    for (const row of doc.querySelectorAll('#listContainer_datatable tbody tr')) {
      const title = clean(row.querySelector('th[scope=row]')?.textContent);
      const detail = visibleText(row);
      if (!title) continue;
      const postedAt = dateFrom(detail, false);
      const id = course.id + '|课程实录|' + title + '|' + (postedAt || '');
      entries.set(id, { id, courseID: course.id, courseName: course.name, kind: '课程实录',
                        title, detail, url: base, postedAt, dueAt: null });
    }
    return;
  }
  if (pageKind === '成绩') {
    for (const row of doc.querySelectorAll('#grades_wrapper > [role=row]')) {
      const title = clean(row.querySelector('.cell.gradable span[id]')?.textContent);
      const score = clean(row.querySelector('.cell.grade .grade')?.textContent || row.querySelector('.cell.grade')?.textContent);
      if (!title || !score || score === '-' || /未评分|尚无|无成绩|not graded/i.test(score)) continue;
      const id = course.id + '|成绩|' + row.id;
      entries.set(id, { id, courseID: course.id, courseName: course.name, kind: '成绩',
                        title, detail: '成绩：' + score, url: base, postedAt: null, dueAt: null });
    }
    return;
  }
  if (pageKind === '作业' && /uploadAssignment/i.test(base)) {
    const text = visibleText(doc.body);
    const instructions = doc.querySelector('#assignmentInfo .vtbegenerated, .assignmentInfo .vtbegenerated, #instructions .vtbegenerated, .assignmentInstructions .vtbegenerated, .vtbegenerated, #instructions, .assignmentInstructions');
    const description = visibleText(instructions);
    const contentId = new URL(base).searchParams.get('content_id');
    const dueAt = dateFrom(text, true);
    if (contentId) {
      for (const item of entries.values()) {
        if (item.kind === '作业' && item.url.includes(contentId)) {
          if (dueAt) item.dueAt = dueAt;
          if (description && !/打开快速链接|全局菜单/.test(description)) item.detail = description.slice(0, 500);
        }
      }
    }
    return;
  }
  const selectors = ["li[id^='contentListItem']", "div[id^='contentListItem']",
    '.announcement', 'li.announcement', '.contentList > li', '#content_listContainer > li',
    '.courseListing > li'];
  let nodes = [...doc.querySelectorAll(selectors.join(','))];
  if (pageKind === '公告' && nodes.length === 0) nodes.push(...doc.querySelectorAll('#announcementList > li'));
  const unique = new Set(nodes);
  for (const node of unique) addItem(course, node, base, context);
}

const portalURL = location.href;
if (location.origin !== origin || /\/webapps\/(login|bb-sso-BBLEARN\/login)/i.test(portalURL) ||
    (document.querySelector('input[type=password]') && !document.querySelector('a[href*="course_id"]'))) {
  return JSON.stringify({ loginRequired: true, courses: [], entries: [], warnings: [] });
}
discover(document, portalURL);
for (const frame of [...document.querySelectorAll('iframe[src]')].slice(0, 12)) {
  const url = absolute(frame.getAttribute('src'), portalURL);
  const doc = await getDoc(url);
  if (doc?.login) return JSON.stringify({ loginRequired: true, courses: [], entries: [], warnings: [] });
  if (doc) discover(doc, url);
}
if (courses.size === 0) warnings.push('暂未从教学网首页识别出课程，请确认已登录并在首页显示“我的课程”。');

for (const course of courses.values()) {
  if (!selected.has(course.id)) continue;
  const queue = [{ url: course.url, context: '', depth: 0 }];
  queuedPages.add(course.url);
  while (queue.length && seenPages.size < 300) {
    const page = queue.shift();
    const doc = await getDoc(page.url);
    if (doc?.login) return JSON.stringify({ loginRequired: true, courses: [...courses.values()], entries: [], warnings });
    if (!doc) continue;
    scanItems(doc, course, page.url, page.context);
    if (page.depth >= 4) continue;
    for (const a of links(doc, page.url)) {
      const id = courseId(a.raw + ' ' + a.url);
      if (id && id !== course.id) continue;
      const kind = sectionKind(a.text, a.url);
      const isFolder = /listContent|content_id|folder/i.test(a.url) && page.depth < 4;
      if (!kind && !isFolder) continue;
      if (!/(course_id|content_id|announcement|grade|assignment)/i.test(a.url)) continue;
      if (!seenPages.has(a.url) && !queuedPages.has(a.url)) {
        queue.push({ url: a.url, context: kind || page.context, depth: page.depth + 1 });
        queuedPages.add(a.url);
      }
    }
  }
}
return JSON.stringify({ loginRequired: false, courses: [...courses.values()], entries: [...entries.values()], warnings: [...new Set(warnings)] });
