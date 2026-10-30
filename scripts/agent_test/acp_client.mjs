// Drives `dsh --profile spot` over ACP stdio and logs every frame.
import { spawn } from 'node:child_process'
import { appendFileSync } from 'node:fs'
const [, , logFile, workdir, prompt, decision] = process.argv
const log = (dir, obj) => appendFileSync(logFile, `${dir} ${JSON.stringify(obj)}\n`)
// The app runs dsh from the session folder too.
const child = spawn(process.env.DSH_BIN, ['--profile', 'spot'], { cwd: process.env.DSH_CWD ?? workdir, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] })
child.stderr.on('data', (d) => appendFileSync(logFile + '.stderr', d))
let buffer = '', nextId = 1
const pending = new Map()
function send(msg) { log('>>', msg); child.stdin.write(JSON.stringify(msg) + '\n') }
function request(method, params) { const id = nextId++; send({ jsonrpc: '2.0', id, method, params }); return new Promise((res) => pending.set(id, res)) }
child.stdout.on('data', (chunk) => {
  buffer += chunk
  let i
  while ((i = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, i); buffer = buffer.slice(i + 1)
    if (!line.trim()) continue
    const msg = JSON.parse(line); log('<<', msg)
    if (msg.id !== undefined && msg.method === undefined) { pending.get(msg.id)?.(msg); pending.delete(msg.id) }
    else if (msg.method === 'session/request_permission') {
      const options = msg.params.options ?? []
      const pick = options.find((o) => o.kind?.startsWith(decision === 'reject' ? 'reject' : 'allow')) ?? options[0]
      send({ jsonrpc: '2.0', id: msg.id, result: { outcome: { outcome: 'selected', optionId: pick.optionId } } })
    }
  }
})
const timer = setTimeout(() => { log('!!', 'timeout'); child.kill(); process.exit(2) }, 90000)
const init = await request('initialize', { protocolVersion: 1, clientCapabilities: {} })
const session = await request('session/new', { cwd: workdir, mcpServers: [] })
if (!session.result) { log('!!', 'no session'); child.kill(); process.exit(1) }
const result = await request('session/prompt', { sessionId: session.result.sessionId, prompt: [{ type: 'text', text: prompt }] })
log('==', result)
clearTimeout(timer)
child.stdin.end()
setTimeout(() => process.exit(0), 3000)
