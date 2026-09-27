import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(new URL('../CourseWatch/ClassCrawler.js', import.meta.url), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const crawl = new AsyncFunction('targets', 'location', 'localStorage', 'fetch', source);

test('matches only the selected course in the current term', async () => {
  const now = new Date();
  const isFall = now.getMonth() >= 7 || now.getMonth() === 0;
  const year = now.getMonth() >= 7 ? now.getFullYear() : now.getFullYear() - 1;
  const semester = `${year}-${year + 1}-${isFall ? 1 : 2}`;
  const oldSemester = `${year - 2}-${year - 1}-${isFall ? 1 : 2}`;
  const courses = [
    { id: 'current', name: '线性代数 A（ I ）习题', semester },
    { id: 'old', name: '线性代数 A（ I ）习题', semester: oldSemester },
    { id: 'other', name: '大学英语', semester },
  ];
  const requests = [];
  const fetch = async path => {
    requests.push(path);
    const data = path.includes('courses/my') ? { courses } : {
      homeworks: [{ id: 'homework-1', title: '习题一', status: 'published', deadline: null }],
    };
    return { status: 200, ok: true, json: async () => data };
  };
  const result = JSON.parse(await crawl(
    [{ id: 'portal-linear', name: '线性代数A (I)' }],
    { hostname: 'class.pku.edu.cn' },
    { getItem: () => 'test-token' },
    fetch,
  ));

  assert.equal(result.scanComplete, true);
  assert.equal(result.loginRequired, false);
  assert.equal(result.entries.length, 1);
  assert.equal(result.entries[0].courseID, 'portal-linear');
  assert.equal(result.entries[0].id, 'class|current|homework-1');
  assert.deepEqual(requests, [
    '/api/courses/my?role=student',
    '/api/courses/current/homeworks/detail',
  ]);
});
