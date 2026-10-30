// Prepares a model's Markdown before markdown-it parses it.
//
// - `\(…\)` and `\[…\]` become `$…$` and `$$…$$`, the delimiters the KaTeX plugin reads.
//   Models use either form.
// - While a reply streams, a `**` or code span still waiting for its closing half is closed for now,
//   so the text doesn't flicker between raw markers and formatting.
//
// Fenced code and inline code are left untouched.

const FENCE = /^ {0,3}(`{3,}|~{3,})/
const CLOSING_FENCE = /^ {0,3}(`{3,}|~{3,})\s*$/

/** Splits the text into prose and fenced code. Joining the parts with "\n" restores it. */
export function segments(markdown) {
  const parts = []
  let fence = null
  for (const line of markdown.split('\n')) {
    const match = FENCE.exec(line)
    if (fence) {
      parts[parts.length - 1].lines.push(line)
      const closes = CLOSING_FENCE.exec(line)
      if (closes && closes[1][0] === fence[0] && closes[1].length >= fence.length) {
        fence = null
      }
    } else if (match) {
      parts.push({ code: true, lines: [line] })
      fence = match[1]
    } else if (parts.length && !parts[parts.length - 1].code) {
      parts[parts.length - 1].lines.push(line)
    } else {
      parts.push({ code: false, lines: [line] })
    }
  }
  return parts.map((part) => ({ code: part.code, text: part.lines.join('\n') }))
}

const isWordChar = (c) => c !== undefined && /[\w]/.test(c)

/** Rewrites `\(…\)` and `\[…\]` in prose, skipping code spans and math that already uses dollars. */
export function convertLatexDelimiters(text) {
  if (!text.includes('\\(') && !text.includes('\\[')) return text
  let out = ''
  let i = 0
  while (i < text.length) {
    const c = text[i]
    if (c === '`') {
      const run = /^`+/.exec(text.slice(i))[0]
      const close = text.indexOf(run, i + run.length)
      const end = close === -1 ? i + run.length : close + run.length
      out += text.slice(i, end)
      i = end
      continue
    }
    if (c === '$') {
      // Math already in dollars is copied as is, so `\\[2pt]` inside it is not taken for a delimiter.
      const double = text[i + 1] === '$'
      const open = double ? '$$' : '$'
      const close = text.indexOf(open, i + open.length)
      if (close !== -1 && (double || !text.slice(i + 1, close).includes('\n'))) {
        out += text.slice(i, close + open.length)
        i = close + open.length
        continue
      }
      out += c
      i += 1
      continue
    }
    if (c === '\\') {
      const next = text[i + 1]
      if (next === '(' || next === '[') {
        const closer = next === '(' ? '\\)' : '\\]'
        const end = findClose(text, i + 2, closer)
        if (end !== -1) {
          const latex = text.slice(i + 2, end)
          if (next === '(') {
            // The KaTeX plugin only opens and closes `$` next to non-word characters.
            const before = isWordChar(out[out.length - 1]) ? ' ' : ''
            const after = isWordChar(text[end + 2]) ? ' ' : ''
            out += `${before}$${latex.trim()}$${after}`
          } else {
            out += `$$${latex}$$`
          }
          i = end + 2
          continue
        }
      }
      // Any other escape, including `\\`, is copied as a pair.
      out += text.slice(i, i + 2)
      i += 2
      continue
    }
    out += c
    i += 1
  }
  return out
}

function findClose(text, from, closer) {
  let i = from
  while (i < text.length - 1) {
    if (text[i] === '\\') {
      if (text.slice(i, i + 2) === closer) return i
      i += 2
    } else {
      i += 1
    }
  }
  return -1
}

/** Markers that close a `**` or a code span left open in the reply's last paragraph. */
export function closingMarkers(text) {
  const paragraph = text.split('\n\n').at(-1) ?? text
  let strong = false
  let code = false
  let i = 0
  while (i < paragraph.length) {
    const c = paragraph[i]
    if (c === '\\') {
      i += 2
      continue
    }
    if (c === '`') {
      const run = /^`+/.exec(paragraph.slice(i))[0].length
      if (run === 1) code = !code
      i += run
      continue
    }
    if (!code && c === '*') {
      const run = /^\*+/.exec(paragraph.slice(i))[0].length
      if (run === 2) strong = !strong
      i += run
      continue
    }
    i += 1
  }
  let closing = ''
  if (code) closing += '`'
  // A lone "**" at the very end has no text to make bold yet.
  if (strong && !paragraph.endsWith('**')) closing += '**'
  return closing
}

export function prepare(markdown, { streaming = false } = {}) {
  const parts = segments(markdown)
  const text = parts.map((part) => (part.code ? part.text : convertLatexDelimiters(part.text))).join('\n')
  const last = parts.at(-1)
  return streaming && last && !last.code ? text + closingMarkers(last.text) : text
}
