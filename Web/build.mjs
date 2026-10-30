// Builds the reply page into App/Reply, which the app bundles as a folder.
// `node build.mjs --check` fails when the committed files are out of date.

import { build } from 'esbuild'
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync, existsSync, mkdtempSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const target = join(here, '..', 'App', 'Reply')
const check = process.argv.includes('--check')
const out = check ? mkdtempSync(join(tmpdir(), 'reply-')) : target

function write(path, contents) {
  mkdirSync(dirname(join(out, path)), { recursive: true })
  writeFileSync(join(out, path), contents)
}

if (!check) rmSync(target, { recursive: true, force: true })

const bundle = await build({
  entryPoints: [join(here, 'src', 'reply.js')],
  bundle: true,
  minify: true,
  format: 'iife',
  target: 'safari17',
  legalComments: 'none',
  write: false,
})
write('reply.js', bundle.outputFiles[0].text)
write('reply.html', readFileSync(join(here, 'src', 'reply.html')))
write('reply.css', readFileSync(join(here, 'src', 'reply.css')))

// highlight.js: GitHub colors, with the dark theme applied in dark mode.
const styles = join(here, 'node_modules', 'highlight.js', 'styles')
const light = readFileSync(join(styles, 'github.min.css'), 'utf8')
const dark = readFileSync(join(styles, 'github-dark.min.css'), 'utf8')
write('highlight.css', `${light}\n@media (prefers-color-scheme: dark){${dark}}\n`)

// Mermaid as published, loaded by the page only when a reply has a diagram.
write('mermaid.min.js', readFileSync(join(here, 'node_modules', 'mermaid', 'dist', 'mermaid.min.js')))

// KaTeX: the stylesheet and its woff2 fonts only; WebKit never needs the older formats.
const katexDist = join(here, 'node_modules', 'katex', 'dist')
const katexCSS = readFileSync(join(katexDist, 'katex.min.css'), 'utf8')
  .replace(/,url\(fonts\/[^)]+\.woff\) format\("woff"\)/g, '')
  .replace(/,url\(fonts\/[^)]+\.ttf\) format\("truetype"\)/g, '')
write('katex/katex.min.css', katexCSS)
for (const font of readdirSync(join(katexDist, 'fonts')).filter((name) => name.endsWith('.woff2'))) {
  write(`katex/fonts/${font}`, readFileSync(join(katexDist, 'fonts', font)))
}

if (check) {
  const stale = []
  const compare = (relative) => {
    for (const name of readdirSync(join(out, relative), { withFileTypes: true })) {
      const path = join(relative, name.name)
      if (name.isDirectory()) {
        compare(path)
      } else if (!existsSync(join(target, path)) ||
                 !readFileSync(join(out, path)).equals(readFileSync(join(target, path)))) {
        stale.push(path)
      }
    }
  }
  compare('.')
  rmSync(out, { recursive: true, force: true })
  if (stale.length) {
    console.error(`App/Reply is out of date. Run "npm run build" in Web/. Changed: ${stale.join(', ')}`)
    process.exit(1)
  }
  console.log('App/Reply is up to date.')
} else {
  console.log(`Built ${target}`)
}
