// Plays DeepSeek Harness's side of a conversation for the UI test of one shared between the two: once
// Spot Chat has asked "Ask from both sides" in a session and its turn has ended, joins that session and
// asks "Please list the files" there, as someone typing in dsh's window would. Then exits.
// The plugin refuses the token until Spot Chat pairs with it, so it tries again until then.
// Usage: node harness_other_side.mjs socket token
import { connect } from 'node:net'

const [, , socketPath, token] = process.argv
const log = (text) => console.log(`${new Date().toISOString().slice(11, 19)} ${text}`)
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** A connection the plugin admitted, or nil when it refused the token or isn't there. */
function open() {
  return new Promise((resolve) => {
    const socket = connect(socketPath)
    let buffer = ''
    let admitted = null
    let nextId = 0
    const pending = new Map()
    const send = (message) => socket.write(JSON.stringify(message) + '\n')
    const client = {
      request: (method, params) => new Promise((done) => {
        const id = ++nextId
        pending.set(id, done)
        send({ jsonrpc: '2.0', id, method, params })
      }),
      close: () => socket.destroy(),
    }
    socket.on('data', (chunk) => {
      buffer += chunk
      let end
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end)
        buffer = buffer.slice(end + 1)
        if (!line.trim()) continue
        const message = JSON.parse(line)
        if (admitted === null) {
          admitted = message.ok === true
          resolve(admitted ? client : null)
        } else if (message.id !== undefined && message.method === undefined) {
          pending.get(message.id)?.(message)
          pending.delete(message.id)
        }
      }
    })
    socket.on('connect', () => send({ token }))
    socket.on('error', () => resolve(null))
    socket.on('close', () => resolve(null))
  })
}

log('waiting for Spot Chat to ask')
const deadline = Date.now() + 30 * 60 * 1000
while (Date.now() < deadline) {
  const client = await open()
  if (client === null) {
    await pause(2000)
    continue
  }
  await client.request('initialize', { protocolVersion: 1, clientCapabilities: {} })
  const listed = await client.request('session/list', {})
  for (const session of listed.result?.sessions ?? []) {
    const history = await client.request('_spotchat/history', { sessionId: session.sessionId })
    const updates = history.result?.updates ?? []
    const asked = updates.findIndex((u) => u.sessionUpdate === 'user_message_chunk' && u.content?.text === 'Ask from both sides')
    const ended = updates.findIndex((u, index) => index > asked && u.sessionUpdate === '_spotchat_turn_end')
    if (asked < 0 || ended < 0) continue
    log(`joining ${session.sessionId}`)
    await client.request('session/resume', { sessionId: session.sessionId, cwd: session.cwd, mcpServers: [] })
    const reply = await client.request('session/prompt', {
      sessionId: session.sessionId, prompt: [{ type: 'text', text: 'Please list the files' }],
    })
    log(`asked; the turn ended: ${JSON.stringify(reply.result ?? reply.error)}`)
    client.close()
    process.exit(0)
  }
  client.close()
  await pause(1000)
}
log('Spot Chat never asked')
process.exit(1)
