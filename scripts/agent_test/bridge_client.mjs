// Connects to Spot Chat's dsh bridge as Spot Chat does: a token line, then ACP over the socket. Asks one
// question in `folder`, allows whatever dsh asks to run, and prints one JSON line with what happened.
import { connect } from 'node:net'

const [, , socketPath, token, folder, question, label] = process.argv
const socket = connect(socketPath)
let buffer = ''
let admitted = null
let nextId = 0
const pending = new Map()
const result = { label, admitted: false, stop: null, error: null, text: '', tools: [], approvals: 0 }
const send = (message) => socket.write(JSON.stringify(message) + '\n')
const request = (method, params) => new Promise((done) => {
  const id = ++nextId
  pending.set(id, done)
  send({ jsonrpc: '2.0', id, method, params })
})
const finish = (code) => {
  console.log(JSON.stringify(result))
  socket.destroy()
  process.exit(code)
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
      admitted = message
      continue
    }
    if (message.id !== undefined && message.method === undefined) {
      pending.get(message.id)?.(message)
      pending.delete(message.id)
    } else if (message.method === 'session/update') {
      const update = message.params.update
      if (update.sessionUpdate === 'agent_message_chunk') result.text += update.content.text
      if (update.sessionUpdate === 'tool_call') result.tools.push(`${update.title}:${update.rawInput?.command ?? ''}`)
    } else if (message.method === 'session/request_permission') {
      result.approvals += 1
      const options = message.params.options ?? []
      const allow = options.find((option) => option.kind?.startsWith('allow')) ?? options[0]
      send({ jsonrpc: '2.0', id: message.id, result: { outcome: { outcome: 'selected', optionId: allow.optionId } } })
    }
  }
})
socket.on('close', () => {
  if (admitted?.ok !== true) finish(0)
})
socket.on('connect', async () => {
  send({ token })
  while (admitted === null) await new Promise((resolve) => setTimeout(resolve, 20))
  if (admitted.ok !== true) return
  result.admitted = true
  await request('initialize', { protocolVersion: 1, clientCapabilities: {} })
  const session = await request('session/new', { cwd: folder, mcpServers: [] })
  if (!session.result) {
    result.error = session.error?.message ?? 'no session'
    finish(1)
    return
  }
  const sessionId = session.result.sessionId
  // As Spot Chat does before a turn: the model, here DeepSeek's flash model when listed.
  const model = (session.result.configOptions ?? []).find((option) => option.id === 'model')
  const values = (model?.options ?? []).flatMap((option) => option.options ?? [option]).map((option) => option.value)
  const pick = values.find((value) => String(value).includes('flash')) ?? values[0]
  if (pick) await request('session/set_config_option', { sessionId, configId: 'model', value: pick })
  const reply = await request('session/prompt', { sessionId, prompt: [{ type: 'text', text: question }] })
  result.stop = reply.result?.stopReason ?? null
  result.error = reply.error?.message ?? null
  finish(0)
})
setTimeout(() => {
  result.error = 'timeout'
  finish(2)
}, 120000)
