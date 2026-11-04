// Drives `dsh --profile spot` over ACP stdio and logs every frame.
import { spawn } from 'node:child_process'
import { appendFileSync } from 'node:fs'
const [, , logFile, workdir, prompt, decision] = process.argv
const log = (dir, obj) => appendFileSync(logFile, `${dir} ${JSON.stringify(obj)}\n`)
// The app runs dsh from the session folder too.
let child, buffer = '', nextId = 1
const pending = new Map()
function send(msg) { log('>>', msg); child.stdin.write(JSON.stringify(msg) + '\n') }
function request(method, params) { const id = nextId++; send({ jsonrpc: '2.0', id, method, params }); return new Promise((res) => pending.set(id, res)) }
function start() {
  buffer = ''
  child = spawn(process.env.DSH_BIN, ['--profile', 'spot'], { cwd: process.env.DSH_CWD ?? workdir, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] })
  child.stderr.on('data', (d) => appendFileSync(logFile + '.stderr', d))
  child.stdout.on('data', onData)
}
async function resume(sessionId) {
  start()
  await request('initialize', { protocolVersion: 1, clientCapabilities: {} })
  log('==', await request('session/load', { sessionId, cwd: workdir, mcpServers: [] }))
  log('==', await request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'Once more' }] }))
}
function onData(chunk) {
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
}
start()
const timer = setTimeout(() => { log('!!', 'timeout'); child.kill(); process.exit(2) }, 90000)
const init = await request('initialize', { protocolVersion: 1, clientCapabilities: {} })
const session = await request('session/new', { cwd: workdir, mcpServers: [] })
if (!session.result) { log('!!', 'no session'); child.kill(); process.exit(1) }
const sessionId = session.result.sessionId
const result = await request('session/prompt', { sessionId, prompt: [{ type: 'text', text: prompt }] })
log('==', result)

// What the app also does in a conversation: change the effort, ask again, and stop a turn. Recorded loads
// then include the code these take.
const effort = (session.result.configOptions ?? []).find((o) => o.id === 'reasoning_effort')
const level = effort?.options?.flatMap((o) => o.options ?? [o]).map((o) => o.value).find((v) => v !== effort.currentValue)
if (level) log('==', await request('session/set_config_option', { sessionId, configId: 'reasoning_effort', value: level }))
const again = request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'And again' }] })
send({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId } })
log('==', await again)

// A later conversation resumes the session in a new dsh, as the app does after a relaunch.
if (init.result?.agentCapabilities?.loadSession) {
  child.stdin.end()
  await new Promise((done) => child.once('exit', done))
  log('==', 'resuming')
  await resume(sessionId)
}
clearTimeout(timer)
child.stdin.end()
setTimeout(() => process.exit(0), 3000)
