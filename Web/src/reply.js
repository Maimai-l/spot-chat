// Runs inside the reply's WKWebView. Swift calls `SpotReply.render`; the page reports its height
// and asks Swift to copy code and open links.

import morphdom from 'morphdom'

import { createRenderer, labels } from './render.js'

const renderer = createRenderer()
const content = document.getElementById('content')

function post(name, body) {
  window.webkit?.messageHandlers?.[name]?.postMessage(body)
}

// The app's log gets the page's errors and the text it finally shows, to compare with the text it was sent.
function log(level, message, details = {}) {
  post('log', { level, message, ...details })
}
window.addEventListener('error', (event) => {
  log('error', 'Page error', { error: String(event.message), at: `${event.filename}:${event.lineno}:${event.colno}` })
})
window.addEventListener('unhandledrejection', (event) => {
  log('error', 'Unhandled rejection', { error: String(event.reason) })
})
let lastShownText = null

let lastHeight = -1
function reportHeight() {
  const height = Math.ceil(content.getBoundingClientRect().height)
  if (height !== lastHeight) {
    lastHeight = height
    post('height', height)
  }
}
new ResizeObserver(reportHeight).observe(content)

function show(markdown, streaming) {
  const next = content.cloneNode(false)
  next.innerHTML = renderer.render(markdown, { streaming })
  // Patching instead of replacing keeps finished formulas, code and the reader's selection in place.
  morphdom(content, next, {
    childrenOnly: true,
    onBeforeElUpdated: (from, to) => {
      // A drawn diagram stays drawn while its source is unchanged.
      if (from.classList?.contains('rendered') && from.dataset.source === to.dataset?.source) return false
      return !from.isEqualNode(to)
    },
    // While a reply streams, each new paragraph, list item, row or code block fades in.
    onNodeAdded: (node) => {
      if (streaming && node.nodeType === Node.ELEMENT_NODE) node.classList.add('appear')
      return node
    },
  })
  reportHeight()
  if (!streaming) {
    drawDiagrams()
    const shown = content.innerText
    if (shown !== lastShownText) {
      lastShownText = shown
      log('debug', 'Shown text', { text: shown, markdownLength: String(markdown.length) })
    }
  }
}

// Mermaid is large, so it loads only for a reply that has a diagram.
let mermaidLoad = null
function loadMermaid() {
  mermaidLoad ??= new Promise((resolve, reject) => {
    const script = document.createElement('script')
    script.src = 'mermaid.min.js'
    script.onload = () => {
      const dark = window.matchMedia('(prefers-color-scheme: dark)').matches
      window.mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: dark ? 'dark' : 'default',
        fontFamily: '-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif',
      })
      resolve(window.mermaid)
    }
    script.onerror = reject
    document.head.appendChild(script)
  })
  return mermaidLoad
}

const diagrams = new Map()
let diagramCount = 0
async function drawDiagrams() {
  const blocks = [...content.querySelectorAll('.mermaid-block:not(.rendered)')]
  if (blocks.length === 0) return
  let mermaid
  try {
    mermaid = await loadMermaid()
  } catch {
    return
  }
  for (const block of blocks) {
    const source = block.dataset.source
    let svg = diagrams.get(source)
    if (svg === undefined) {
      const id = `diagram-${++diagramCount}`
      try {
        svg = (await mermaid.render(id, source)).svg
      } catch {
        // A diagram Mermaid can't read stays as its source.
        svg = null
      }
      document.getElementById(`d${id}`)?.remove()
      diagrams.set(source, svg)
    }
    if (!block.isConnected || block.dataset.source !== source) continue
    block.classList.add('rendered')
    if (svg === null) continue
    const drawing = document.createElement('div')
    drawing.className = 'mermaid-diagram'
    drawing.innerHTML = svg
    block.querySelector('pre')?.replaceWith(drawing)
  }
  reportHeight()
}

// Streamed text arrives in bursts. It is revealed at an even pace instead, quick enough to stay a
// fraction of a second behind what has arrived, and quicker still once the reply is complete.
const pacer = createPacer()

function createPacer() {
  let target = ''
  let shown = 0
  let streaming = false
  let started = false
  let frame = null
  let last = 0
  let carry = 0

  function tick(now) {
    const elapsed = Math.min(now - last, 50) / 1000
    last = now
    const backlog = target.length - shown
    if (backlog <= 0) {
      frame = null
      show(target, streaming)
      return
    }
    // Catch up within 0.35 s while streaming and 0.15 s after, never slower than a calm typing pace.
    const rate = Math.max(backlog / (streaming ? 0.35 : 0.15), streaming ? 45 : 400)
    carry += rate * elapsed
    const step = Math.floor(carry)
    if (step > 0) {
      carry -= step
      shown = Math.min(target.length, shown + step)
      // Never split a character made of two code units.
      const code = target.charCodeAt(shown - 1)
      if (code >= 0xd800 && code <= 0xdbff && shown < target.length) shown += 1
      show(target.slice(0, shown), true)
    }
    frame = requestAnimationFrame(tick)
  }

  return {
    update(markdown, isStreaming) {
      // A reply already under way when the page loads (scrolled back into view, or in another window)
      // shows at once rather than replaying.
      if (!started) {
        started = true
        target = markdown
        shown = markdown.length
        streaming = isStreaming
        show(markdown, isStreaming)
        return
      }
      if (!markdown.startsWith(target.slice(0, shown))) shown = 0
      target = markdown
      streaming = isStreaming
      if (frame === null) {
        last = performance.now()
        frame = requestAnimationFrame(tick)
      }
    },
  }
}

window.SpotReply = {
  configure(strings) {
    Object.assign(labels, strings)
  },
  render(markdown, streaming) {
    pacer.update(markdown, streaming)
  },
}

document.addEventListener('click', (event) => {
  const button = event.target.closest('.copy-code')
  if (button) {
    event.preventDefault()
    const block = button.closest('.code-block')
    const code = block?.dataset.source ?? block?.querySelector('pre code')?.textContent ?? ''
    post('copyCode', code)
    const label = button.querySelector('.copy-label')
    button.classList.add('copied')
    if (label) label.textContent = labels.copied
    clearTimeout(button._reset)
    button._reset = setTimeout(() => {
      button.classList.remove('copied')
      if (label) label.textContent = labels.copy
    }, 1500)
    return
  }
  const link = event.target.closest('a[href]')
  if (link) {
    event.preventDefault()
    post('openLink', link.href)
  }
})

post('ready', true)
