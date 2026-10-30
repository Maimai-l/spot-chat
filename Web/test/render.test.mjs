import { test } from 'node:test'
import assert from 'node:assert/strict'

import { createRenderer } from '../src/render.js'
import { closingMarkers, convertLatexDelimiters, prepare, segments } from '../src/preprocess.js'

const renderer = createRenderer()
const render = (markdown, options) => renderer.render(markdown, options)
const hasMath = (html) => html.includes('class="katex"')

test('a single line break stays a line break', () => {
  assert.match(render('one\ntwo'), /one<br>\ntwo/)
})

test('bold next to Chinese punctuation is bold', () => {
  assert.match(render('**注意：**这里'), /<strong>注意：<\/strong>这里/)
  assert.match(render('文字**「引用」**后面'), /<strong>「引用」<\/strong>/)
})

test('both LaTeX delimiter styles render as math', () => {
  assert.ok(hasMath(render('Area \\(A = \\pi r^2\\) here')))
  assert.ok(hasMath(render('$e^{i\\pi} + 1 = 0$')))
  assert.match(render('\\[\n\\int_0^1 x^2 \\, dx\n\\]'), /katex-display/)
  assert.match(render('$$\\sum_{k=1}^{n} k$$'), /katex-display/)
})

test('math keeps underscores, stars and braces', () => {
  const html = render('$a_1 * b_2 + \\{x\\}$')
  assert.ok(hasMath(html))
  assert.doesNotMatch(html, /<em>|<strong>/)
})

test('prices are not math', () => {
  for (const text of ['It costs $5 and $10.', 'Pay $5 for $x$', '价格$5和$10']) {
    const html = render(text)
    assert.match(html, /\$5/, text)
  }
  assert.ok(hasMath(render('Pay $5 for $x$')), 'the formula next to a price still renders')
})

test('inline math directly after a word still renders', () => {
  assert.ok(hasMath(render('value\\(x\\)here')))
})

test('LaTeX line breaks inside dollar math are not taken for delimiters', () => {
  const source = '$$\\begin{aligned} a &= 1 \\\\[2pt] b &= 2 \\end{aligned}$$'
  assert.equal(convertLatexDelimiters(source), source)
  assert.match(render(source), /katex-display/)
})

test('an invalid formula shows its source instead of an error', () => {
  const html = render('$\\frac{1}{$')
  assert.doesNotMatch(html, /ParseError/)
})

test('code is left alone', () => {
  const source = 'Use `\\(x\\)` here\n\n```\n\\(not math\\) $5 $6\n```'
  assert.equal(prepare(source), source)
  assert.doesNotMatch(render(source), /katex/)
})

test('segments restore the original text', () => {
  const source = 'a\n```js\nlet x\n```\nb\n~~~~\nc\n~~~~'
  assert.equal(segments(source).map((part) => part.text).join('\n'), source)
  assert.deepEqual(segments(source).map((part) => part.code), [false, true, false, true])
})

test('code blocks get a language label and a copy button', () => {
  const html = render('```sql\nSELECT 1;\n```')
  assert.match(html, /class="code-language">sql</)
  assert.match(html, /class="copy-code"[^>]*aria-label="Copy code"/)
  assert.match(html, /hljs-keyword/)
})

test('raw HTML from the model is shown as text', () => {
  assert.doesNotMatch(render('<script>alert(1)</script>'), /<script>/)
})

test('streaming closes an open bold or code span for now', () => {
  assert.equal(closingMarkers('Some **bold te'), '**')
  assert.equal(closingMarkers('Run `swift te'), '`')
  assert.equal(closingMarkers('Done **bold**'), '')
  assert.equal(closingMarkers('Ends with **'), '')
  assert.match(render('Some **bold te', { streaming: true }), /<strong>bold te<\/strong>/)
  assert.doesNotMatch(render('Some **bold te', { streaming: false }), /<strong>/)
})

test('streaming leaves an open code fence alone', () => {
  assert.equal(prepare('```swift\nlet **a', { streaming: true }), '```swift\nlet **a')
})

test('tables scroll in their own box', () => {
  assert.match(render('| a | b |\n| --- | --- |\n| 1 | 2 |'), /<div class="table-scroll"><table>/)
})

test('display math inside a paragraph does not nest paragraphs', () => {
  const html = render('With dollars: $$\\sum_{k=1}^{n} k$$')
  assert.match(html, /<p>With dollars: <span class="katex-block">/)
  assert.doesNotMatch(html, /<p class="katex-block">/)
  assert.match(render('$$x^2$$'), /^<div class="katex-block">/)
})

test('a mermaid block keeps its source for drawing', () => {
  const html = render('```mermaid\ngraph TD\n  A --> B\n```')
  assert.match(html, /class="code-block mermaid-block" data-source="graph TD\n  A --&gt; B"/)
  assert.match(html, /class="code-language">mermaid</)
})
