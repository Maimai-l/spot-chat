// Turns a reply's Markdown into HTML. Pure, so it runs the same in the app and in tests.

import MarkdownIt from 'markdown-it'
import markdownItKatex from '@vscode/markdown-it-katex'
import markdownItCjkFriendly from 'markdown-it-cjk-friendly'
import katex from 'katex'
import hljs from 'highlight.js/lib/common'

import { prepare } from './preprocess.js'

export const labels = {
  copy: 'Copy',
  copied: 'Copied',
  copyCode: 'Copy code',
}

const escapeHtml = (text) =>
  text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

// A streaming reply is rendered again for every frame, so finished formulas and code are kept.
function memoize(compute, limit = 400) {
  const cache = new Map()
  return (key, ...args) => {
    if (cache.has(key)) return cache.get(key)
    const value = compute(...args)
    if (cache.size >= limit) cache.delete(cache.keys().next().value)
    cache.set(key, value)
    return value
  }
}

const renderMath = memoize((latex, displayMode) => {
  try {
    return katex.renderToString(latex, { displayMode, throwOnError: true })
  } catch {
    // A formula KaTeX can't parse yet, often because it is still streaming, is shown as its source.
    return `<code class="math-source">${escapeHtml(latex)}</code>`
  }
})

const forgivingKatex = {
  renderToString(latex, options) {
    const displayMode = Boolean(options?.displayMode)
    return renderMath(`${displayMode ? 'D' : 'I'}${latex}`, latex, displayMode)
  },
}

const COPY_ICON =
  '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5.25" y="5.25" width="8" height="8" rx="1.75"/>' +
  '<path d="M10.75 3.5V3.25a1.5 1.5 0 0 0-1.5-1.5h-5a1.5 1.5 0 0 0-1.5 1.5v5a1.5 1.5 0 0 0 1.5 1.5h.25"/></svg>'

const highlight = memoize((code, language) => highlightNow(code, language))

function highlightNow(code, language) {
  if (language && hljs.getLanguage(language)) {
    try {
      return hljs.highlight(code, { language, ignoreIllegals: true }).value
    } catch {
      // Falls through to plain text.
    }
  }
  return escapeHtml(code)
}

export function createRenderer() {
  const md = new MarkdownIt({
    html: false,
    linkify: true,
    // Models break lines with a single newline; keep those breaks.
    breaks: true,
    typographer: false,
  })
    .use(markdownItCjkFriendly)
    .use(markdownItKatex.default ?? markdownItKatex, { katex: forgivingKatex })

  md.renderer.rules.fence = (tokens, index) => {
    const token = tokens[index]
    const language = token.info.trim().split(/\s+/)[0] ?? ''
    const code = token.content.replace(/\n$/, '')
    // A Mermaid diagram starts as its source; the page draws it once the reply is complete.
    const diagram = language.toLowerCase() === 'mermaid'
    return (
      (diagram ? `<div class="code-block mermaid-block" data-source="${escapeHtml(code)}">` : '<div class="code-block">') +
      '<div class="code-header">' +
      `<span class="code-language">${escapeHtml(language)}</span>` +
      `<button class="copy-code" type="button" aria-label="${escapeHtml(labels.copyCode)}">` +
      `${COPY_ICON}<span class="copy-label">${escapeHtml(labels.copy)}</span></button>` +
      '</div>' +
      `<pre><code class="hljs${language ? ` language-${escapeHtml(language)}` : ''}">${highlight(`${language}\n${code}`, code, language)}</code></pre>` +
      '</div>\n'
    )
  }

  // Display math gets its own scrolling box. One written inside a paragraph stays a span, since a
  // paragraph can't hold another paragraph.
  const displayMath = (tokens, index) => {
    // A formula written inside a line has no source lines of its own.
    const tag = tokens[index].map ? 'div' : 'span'
    return `<${tag} class="katex-block">${forgivingKatex.renderToString(tokens[index].content, { displayMode: true })}</${tag}>\n`
  }
  md.renderer.rules.math_block = displayMath
  md.renderer.rules.math_inline_block = displayMath
  md.renderer.rules.math_inline_bare_block = displayMath

  // Wide tables scroll inside their own box instead of stretching the reply.
  md.renderer.rules.table_open = () => '<div class="table-scroll"><table>\n'
  md.renderer.rules.table_close = () => '</table></div>\n'

  return {
    render(markdown, { streaming = false } = {}) {
      return md.render(prepare(markdown, { streaming }))
    },
  }
}
