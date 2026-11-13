// Checks that a session through Spot Chat's dsh bridge is shared with the dsh it runs in, as dsh's own
// interface shares it: a second connection stands in for that interface. Prints one JSON line of checks.
// Usage: node bridge_sharing.mjs socket token folder
import { connect } from 'node:net'

const [, , socketPath, token, folder] = process.argv

/** One bridge connection speaking ACP, which records what each session reports. */
class Client {
  constructor(name) {
    this.name = name
    this.updates = []
    this.pending = new Map()
    this.nextId = 0
    this.buffer = ''
    this.admitted = null
  }

  open() {
    return new Promise((ready, fail) => {
      this.socket = connect(socketPath)
      this.socket.on('error', fail)
      this.socket.on('connect', () => this.socket.write(JSON.stringify({ token }) + '\n'))
      this.socket.on('data', (chunk) => {
        this.buffer += chunk
        let end
        while ((end = this.buffer.indexOf('\n')) >= 0) {
          const line = this.buffer.slice(0, end)
          this.buffer = this.buffer.slice(end + 1)
          if (!line.trim()) continue
          const message = JSON.parse(line)
          if (this.admitted === null) {
            this.admitted = message
            ready()
          } else if (message.id !== undefined && message.method === undefined) {
            this.pending.get(message.id)?.(message)
            this.pending.delete(message.id)
          } else if (message.method === 'session/update') {
            this.updates.push(message.params.update)
          } else if (message.method === 'session/request_permission') {
            const allow = message.params.options.find((option) => option.kind?.startsWith('allow'))
            this.send({ jsonrpc: '2.0', id: message.id, result: { outcome: { outcome: 'selected', optionId: allow.optionId } } })
          }
        }
      })
    }).then(() => this.request('initialize', { protocolVersion: 1, clientCapabilities: {} }))
  }

  send(message) {
    this.socket.write(JSON.stringify(message) + '\n')
  }

  request(method, params) {
    return new Promise((done) => {
      const id = ++this.nextId
      this.pending.set(id, done)
      // Written as Swift's JSONEncoder writes it, with the slash escaped, as Spot Chat sends it.
      this.socket.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }).replaceAll('/', '\\/') + '\n')
    })
  }

  prompt(sessionId, text) {
    return this.request('session/prompt', { sessionId, prompt: [{ type: 'text', text }] })
  }

  text() {
    return this.updates.filter((u) => u.sessionUpdate === 'agent_message_chunk').map((u) => u.content.text).join('')
  }

  questions() {
    return this.updates.filter((u) => u.sessionUpdate === 'user_message_chunk').map((u) => u.content.text)
  }

  commands() {
    return this.updates.filter((u) => u.sessionUpdate === 'tool_call').map((u) => u.rawInput?.command ?? '')
  }

  /** Waits until `check` holds, for up to `seconds`. */
  async until(check, seconds = 30) {
    for (let waited = 0; waited < seconds * 10; waited += 1) {
      if (check()) return true
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    return false
  }

  close() {
    this.socket.destroy()
  }
}

const checks = {}
const timer = setTimeout(() => {
  console.log(JSON.stringify({ ...checks, error: 'timeout' }))
  process.exit(2)
}, 150000)

const spot = new Client('spot')
await spot.open()
const created = await spot.request('session/new', { cwd: folder, mcpServers: [] })
const sessionId = created.result.sessionId
await spot.prompt(sessionId, 'hello')

// The other side joins the session while Spot Chat holds it, and runs a command Spot Chat sees.
const other = new Client('other')
await other.open()
const joined = await other.request('session/resume', { sessionId, cwd: folder, mcpServers: [] })
checks.joinedWhileHeld = joined.result !== undefined
if (checks.joinedWhileHeld) {
  const listed = await other.prompt(sessionId, 'Please list the files')
  checks.otherSideRan = listed.result?.stopReason === 'end_turn' && other.commands().includes('ls -a')
  checks.spotSawIt = await spot.until(() => spot.commands().includes('ls -a') && spot.text().includes('Listed the folder.'), 5)
  // The question comes before what was done for it.
  const asked = spot.updates.findIndex((u) => u.sessionUpdate === 'user_message_chunk' && u.content.text === 'Please list the files')
  const ran = spot.updates.findIndex((u) => u.sessionUpdate === 'tool_call' && u.rawInput?.command === 'ls -a')
  checks.spotSawTheQuestion = asked >= 0 && asked < ran
}

// Spot Chat leaves while its command runs; the turn finishes, as the other side sees.
spot.prompt(sessionId, 'Run this in the background')
await spot.until(() => spot.commands().includes('sleep 8'), 20)
spot.close()
checks.turnWentOn = await other.until(() => other.text().includes('Finished in the background.'), 30)

// Spot Chat comes back to the session, which is still open in dsh, and goes on with it.
const back = new Client('back')
await back.open()
const resumed = await back.request('session/resume', { sessionId, cwd: folder, mcpServers: [] })
const again = resumed.result !== undefined ? await back.prompt(sessionId, 'hello') : undefined
checks.cameBack = again?.result?.stopReason === 'end_turn' && back.text().includes('Hello from dsh.')

// Stopping still stops.
const slow = back.prompt(sessionId, 'run something slow')
await back.until(() => back.commands().includes('sleep 60'), 20)
back.send({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId } })
checks.stopStops = (await slow).result?.stopReason === 'cancelled'

// The whole conversation, both sides' questions included, read back from dsh.
await back.prompt(sessionId, '你好，列出文件以外的事')
const history = await back.request('_spotchat/history', { sessionId })
const updates = history.result?.updates ?? []
const questions = updates.filter((u) => u.sessionUpdate === 'user_message_chunk').map((u) => u.content.text)
checks.historyHasEveryQuestion = JSON.stringify(questions) === JSON.stringify([
  'hello', 'Please list the files', 'Run this in the background', 'hello', 'run something slow', '你好，列出文件以外的事',
])
const listedUpdate = updates.find((u) => u.sessionUpdate === 'tool_call' && u.rawInput?.command === 'ls -a')
const listedResult = updates.find((u) => u.sessionUpdate === 'tool_call_update' && u.toolCallId === listedUpdate?.toolCallId)
checks.historyHasCommands = listedResult?.status === 'completed' && listedResult.content[0]?.content.text.includes('..')
  && listedResult._spotchat_seconds > 0
checks.historyHasEnds = updates.filter((u) => u.sessionUpdate === '_spotchat_turn_end').map((u) => u.stopReason).includes('cancelled')
if (!checks.historyHasEveryQuestion) checks.questions = questions

clearTimeout(timer)
other.close()
back.close()
console.log(JSON.stringify(checks))
process.exit(0)
