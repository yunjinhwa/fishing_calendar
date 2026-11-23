const htmlEntities = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, character => htmlEntities[character]);
}

export function hasEffectiveDate(source) {
  const header = source.split(/^(?:1\. |제1조\()/m)[0];
  if (/검토본|초안|시행일 미정/.test(header)) return false;
  const match = header.match(/^시행일\s+(\d{4}-\d{2}-\d{2})\s*$/m);
  if (!match) return false;
  const date = new Date(match[1] + 'T00:00:00Z');
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === match[1];
}

export function renderLegalPage(source) {
  const [title, ...lines] = source.trim().split(/\r?\n/);
  const heading = escapeHtml(title);
  const blocks = [];
  let paragraph = [];

  function finishParagraph() {
    if (paragraph.length === 0) return;
    blocks.push(`<p>${paragraph.join('<br>\n')}</p>`);
    paragraph = [];
  }

  for (const line of lines) {
    const text = line.trim();
    if (text === '') {
      finishParagraph();
    } else if (/^(?:\d+\.\s+\S|제\s*\d+\s*조(?:\s|\(|$))/.test(text)) {
      finishParagraph();
      blocks.push(`<h2>${escapeHtml(text)}</h2>`);
    } else {
      if (/^[①-⑳]\s/.test(text)) finishParagraph();
      paragraph.push(escapeHtml(text));
    }
  }
  finishParagraph();

  return `<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${heading} | 낚시 캘린더</title>
  <link rel="stylesheet" href="/legal.css">
</head>
<body>
  <main>
    <article>
      <h1>${heading}</h1>
      ${blocks.join('\n      ')}
    </article>
    <nav aria-label="관련 문서">
      <a href="/privacy/">개인정보 처리방침</a>
      <a href="/terms/">이용약관</a>
      <a href="/account-deletion/">계정 삭제 요청</a>
    </nav>
  </main>
</body>
</html>
`;
}
