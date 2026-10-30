// Runs inside the reply's WKWebView. Swift calls `SpotReply.render`; the page reports its height
// and asks Swift to copy code and open links.

import morphdom from 'morphdom'

import { createRenderer, labels } from './render.js'

const renderer = createRenderer()
const content = document.getElementById('content')

function post(name, body) {
  window.webkit?.messageHandlers?.[name]?.postMessage(body)
}

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
    onBeforeElUpdated: (from, to) => !from.isEqualNode(to),
    // While a reply streams, each new paragraph, list item, row or code block fades in.
    onNodeAdded: (node) => {
      if (streaming && node.nodeType === Node.ELEMENT_NODE) node.classList.add('appear')
      return node
    },
  })
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
    const code = button.closest('.code-block')?.querySelector('pre code')?.textContent ?? ''
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
