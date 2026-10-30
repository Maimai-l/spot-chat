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

// Updates arrive for every streamed chunk; they are applied at most once per frame's worth of time.
let pending = null
let timer = null
function apply() {
  timer = null
  if (!pending) return
  const { markdown, streaming } = pending
  pending = null
  const next = content.cloneNode(false)
  next.innerHTML = renderer.render(markdown, { streaming })
  // Patching instead of replacing keeps finished formulas, code and the reader's selection in place.
  morphdom(content, next, {
    childrenOnly: true,
    onBeforeElUpdated: (from, to) => !from.isEqualNode(to),
  })
  reportHeight()
}

window.SpotReply = {
  configure(strings) {
    Object.assign(labels, strings)
  },
  render(markdown, streaming) {
    pending = { markdown, streaming }
    if (!timer) timer = setTimeout(apply, streaming ? 16 : 0)
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
