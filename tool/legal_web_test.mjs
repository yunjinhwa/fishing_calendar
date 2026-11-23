import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { hasEffectiveDate, renderLegalPage } from './render_legal_web.mjs';

test('only an effective date in a finalized policy header enables publication', () => {
  assert.ok(hasEffectiveDate('이용약관\n시행일 2028-02-29\n\n제1조(목적)'));
  for (const source of [
    '개인정보 처리방침\n공개 전 검토본 · 시행일 미정',
    '이용약관\n초안\n시행일 2026-11-23',
    '이용약관\n시행일 2026-02-31',
    '개인정보 처리방침\n1. 처리 목적\n시행일 2026-11-23',
  ]) assert.equal(hasEffectiveDate(source), false);
});

test('formats legal titles and paragraphs while escaping the source HTML', () => {
  const page = renderLegalPage([
    '정책 <초안>',
    '',
    '1. 처리 목적',
    '본문 & "인용" <script>alert(0)</script>',
    "'다음 줄'",
    '',
    '제2조(변경)',
    '다른 문단',
  ].join('\r\n'));

  assert.match(page, /<html lang="ko">/);
  assert.match(page, /<h1>정책 &lt;초안&gt;<\/h1>/);
  assert.match(page, /<h2>1\. 처리 목적<\/h2>/);
  assert.ok(page.includes(
    '<p>본문 &amp; &quot;인용&quot; &lt;script&gt;alert(0)&lt;/script&gt;<br>\n'
    + '&#39;다음 줄&#39;</p>',
  ));
  assert.match(page, /<h2>제2조\(변경\)<\/h2>\s*<p>다른 문단<\/p>/);
  assert.doesNotMatch(page, /<(?:script|form)\b/i);
});

const decodedEntities = {
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
};

test('shows consecutive numbered clauses in separate paragraphs', () => {
  const page = renderLegalPage('약관\n제1조(목적)\n① 첫 항목\n보충 설명\n② 다음 항목');
  assert.match(page, /<p>① 첫 항목<br>\n보충 설명<\/p>\s*<p>② 다음 항목<\/p>/);
});

for (const document of ['privacy', 'terms']) {
  test(`preserves the app's ${document} source in the public body`, async () => {
    const source = await readFile(new URL(`../assets/legal/${document}.txt`, import.meta.url), 'utf8');
    const page = renderLegalPage(source);
    const body = page.match(/<article>([\s\S]*?)<\/article>/)[1];
    const visibleText = body
      .replace(/<\/?(?:h1|h2|p|br)>/g, '')
      .replace(/&(?:amp|lt|gt|quot|#39);/g, entity => decodedEntities[entity]);
    const nonEmptyLines = value => value.split(/\r?\n/).map(line => line.trim()).filter(Boolean);

    assert.deepEqual(nonEmptyLines(visibleText), nonEmptyLines(source));
    assert.match(page, /<h2>/);
    assert.match(page, /href="\/legal\.css"/);
    assert.match(page, /href="\/account-deletion\/"/);
  });
}
