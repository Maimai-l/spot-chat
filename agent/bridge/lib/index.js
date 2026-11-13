// Spot Chat's bridge into your own DeepSeek Harness.
//
// Spot Chat can run its commands in a dsh it starts itself, or here, in the dsh you already run (desktop
// or `dsh web`), so the sessions show up in its interface and you can watch them. This plugin opens a
// Unix socket only your account can reach and speaks dsh's own ACP server on it, one per connection.
//
// A program that reaches the socket could drive the agent and answer its approval requests, which is how
// dsh's own control plane was escaped before (CVE-2026-82533, CVE-2026-82033), and sandboxed commands can
// open local sockets and read files. So a connection must first present Spot Chat's token. Spot Chat keeps
// the token in the Keychain and writes only its SHA-256 here, so reading the files gets nothing usable.

import { createHash, timingSafeEqual } from 'node:crypto'
import { chmodSync, mkdirSync, readFileSync, rmSync } from 'node:fs'
import { createRequire } from 'node:module'
import { createServer } from 'node:net'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { Writable } from 'node:stream'
import { StringDecoder } from 'node:string_decoder'
import { pathToFileURL } from 'node:url'

export const name = 'spot-chat-bridge'
/** The services dsh's ACP server needs; each connection mounts one. */
export const inject = ['agents', 'llm', 'sessionPersistence', 'sessions']

const defaultDirectory = join(homedir(), 'Library', 'Application Support', 'Spot Chat', 'dsh-bridge')
/** The first line a connection sends may not be longer than this. */
const handshakeLimit = 4096

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {{ directory?: string }} config
 */
export function apply(ctx, config = {}) {
  const directory = config.directory ?? process.env.SPOT_CHAT_BRIDGE_DIR ?? defaultDirectory
  const socketPath = join(directory, 'bridge.sock')
  const tokenPath = join(directory, 'token.sha256')
  const logger = ctx.logger
  let acpLoading

  // Nothing here may throw out of a callback: an uncaught error would take the whole dsh down with it.
  ctx.effect(() => {
    try {
      mkdirSync(directory, { recursive: true, mode: 0o700 })
      chmodSync(directory, 0o700)
      rmSync(socketPath, { force: true })
    } catch (error) {
      logger.error(`spot-chat-bridge: can't prepare ${directory}: ${String(error)}`)
      return () => {}
    }
    const connections = new Set()
    const server = createServer((socket) => {
      connections.add(socket)
      socket.once('close', () => connections.delete(socket))
      admit(socket).catch((error) => {
        logger.warn(`spot-chat-bridge: connection failed: ${String(error)}`)
        socket.destroy()
      })
    })
    server.on('error', (error) => logger.error(`spot-chat-bridge: socket failed: ${String(error)}`))
    server.listen(socketPath, () => {
      try {
        chmodSync(socketPath, 0o600)
        logger.info(`spot-chat-bridge: listening on ${socketPath}`)
      } catch (error) {
        logger.error(`spot-chat-bridge: closing, the socket can't be made private: ${String(error)}`)
        server.close()
      }
    })
    return () => {
      for (const socket of connections) socket.destroy()
      server.close()
      try {
        rmSync(socketPath, { force: true })
      } catch (error) {
        logger.warn(`spot-chat-bridge: can't remove ${socketPath}: ${String(error)}`)
      }
    }
  }, 'spot-chat-bridge.socket')

  /** Reads the token line, and hands the rest of the connection to an ACP server of its own. */
  async function admit(socket) {
    const { line, rest } = await firstLine(socket)
    if (!tokenMatches(line)) {
      logger.warn('spot-chat-bridge: refused a connection without the right token')
      socket.end(JSON.stringify({ ok: false }) + '\n')
      return
    }
    const { acp, ndJsonStream } = await (acpLoading ??= loadAcp())
    socket.write(JSON.stringify({ ok: true, version: acpVersion }) + '\n')
    if (rest.length > 0) socket.unshift(rest)
    const detaching = detacher()
    const tell = (message) => socket.write(JSON.stringify(message) + '\n')
    const answer = (request) => answerOwnRequest(request, ctx, tell, logger)
    const stream = ndJsonStream(Writable.toWeb(socket), readable(socket, detaching.start, answer))
    // A session needs a model to start from; Spot Chat then sets the one it uses.
    const selection = config.provider && config.model
      ? { provider: config.provider, model: config.model }
      : await startingModel(ctx.llm)
    const fiber = ctx.plugin({
      name: 'spot-chat-bridge-connection',
      inject: acp.inject,
      apply: (connection) => acp.apply(
        forSpotChat(connection, ctx.agents, detaching, tell, logger), { stream, sessionListPageSize: 100, ...selection }
      ),
    })
    logger.info('spot-chat-bridge: Spot Chat connected')
    socket.once('close', () => {
      logger.info('spot-chat-bridge: Spot Chat disconnected')
      try {
        fiber.dispose()
      } catch (error) {
        logger.warn(`spot-chat-bridge: closing the connection's sessions failed: ${String(error)}`)
      }
    })
    socket.on('error', (error) => logger.warn(`spot-chat-bridge: connection error: ${String(error)}`))
  }

  /** Whether the line carries the token whose SHA-256 Spot Chat wrote when it paired. */
  function tokenMatches(line) {
    let expected
    try {
      expected = Buffer.from(readFileSync(tokenPath, 'utf8').trim(), 'hex')
    } catch {
      logger.warn(`spot-chat-bridge: no paired token at ${tokenPath}`)
      return false
    }
    let token
    try {
      token = JSON.parse(line).token
    } catch {
      return false
    }
    if (typeof token !== 'string' || token.length === 0 || expected.length !== 32) return false
    const actual = createHash('sha256').update(token).digest()
    return timingSafeEqual(actual, expected)
  }
}

/**
 * The connection's context, changed so its sessions are shared with this dsh rather than owned by the
 * connection:
 *
 * - Sessions are composed as this dsh composes its own. The desktop and web profiles keep an agent's tools
 *   in agent presets that each session mounts when it is made; dsh's ACP server doesn't mount one, so its
 *   sessions would have no tools at all. A new session gets the user's default preset, and a resumed one
 *   the preset it recorded, as dsh's session API does.
 * - Sessions belong to the plugin, not the connection, so they go on when Spot Chat disconnects or quits,
 *   and dsh's interface can go on with them. A session that is already running, in dsh's interface or from
 *   an earlier connection, is joined rather than refused; both sides then write to it, and dsh queues a
 *   message sent while a turn runs.
 * - Approval requests from these sessions go to Spot Chat.
 */
function forSpotChat(connection, hostAgents, detaching, tell, logger) {
  const presets = connection.get('agentPresets')
  const defaultPreset = async () => (await presets.resolve(undefined)).id
  const mounting = (setup, preset) => presets === undefined ? setup : async (agentCtx, agent) => {
    const commit = await setup?.(agentCtx, agent)
    await presets.mount(agentCtx, await preset(agent))
    return commit
  }
  // dsh's ACP server disposes its sessions when the connection closes; here that leaves them running.
  const open = new Set()
  const kept = (handle) => {
    detaching.watch(handle.agent)
    open.add(handle.agent.session.id)
    return new Proxy(handle, {
      get: (target, key) => (key === 'dispose' ? () => {} : Reflect.get(target, key)),
    })
  }
  const wrapped = new Proxy(hostAgents, {
    get(target, key) {
      if (key === 'create') {
        return async (options) => {
          const preset = presets === undefined ? undefined : await defaultPreset()
          return kept(await target.create({
            ...options,
            meta: preset === undefined ? options.meta : { ...options.meta, agentPreset: preset },
            setup: mounting(options.setup, async () => preset),
          }))
        }
      }
      if (key === 'resume') {
        return async (options) => {
          const live = target.get(options.resumeSessionId)
          if (live !== undefined) {
            logger.info(`spot-chat-bridge: joined the running session ${options.resumeSessionId}`)
            return kept({ agent: live, dispose() {} })
          }
          return kept(await target.resume({
            ...options,
            setup: mounting(options.setup, async (agent) => presets.presetForSession(agent.session) ?? await defaultPreset()),
          }))
        }
      }
      const value = Reflect.get(target, key, target)
      return typeof value === 'function' ? value.bind(target) : value
    },
  })
  // The ACP server refuses a session dsh already has open; it may join one here.
  const sessions = new Proxy(connection.sessions, {
    get(target, key) {
      if (key === 'get') return () => undefined
      const value = Reflect.get(target, key, target)
      return typeof value === 'function' ? value.bind(target) : value
    },
  })
  // dsh's ACP server reports what the model and tools do, not the questions; Spot Chat needs those from
  // dsh's side to tell them from its own and start a new message.
  connection.on('session/event', (session, event) => {
    if (!open.has(session.header.id)) return
    const update = questionUpdate(event)
    if (update === undefined) return
    try {
      tell({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: session.header.id, update } })
    } catch (error) {
      logger.warn(`spot-chat-bridge: couldn't pass on a question: ${String(error)}`)
    }
  })
  // dsh's own interface takes approval requests first and waits for someone to answer them there. The ACP
  // server's handler goes ahead of it, so Spot Chat asks; it passes on requests from other sessions.
  const on = (name, listener, options) =>
    connection.on(name, listener, name === 'approval/request' ? true : options)
  return new Proxy(connection, {
    get(target, key) {
      if (key === 'agents') return wrapped
      if (key === 'sessions') return sessions
      if (key === 'on') return on
      return Reflect.get(target, key)
    },
  })
}

/**
 * Answers the plugin's own requests, which ACP lets a client add with names starting with an underscore.
 * `_spotchat/history` returns a session's conversation as the updates a client following it would have
 * seen, so Spot Chat can rebuild it with what was said in dsh's interface. Returns whether it answered.
 */
function answerOwnRequest(request, ctx, tell, logger) {
  if (request.method !== '_spotchat/history' || request.id === undefined) return false
  const sessionId = request.params?.sessionId
  ;(async () => {
    const query = ctx.get('sessionQuery')
    if (query === undefined) throw new Error('this dsh has no session query service')
    const { events } = await query.readSession(sessionId)
    return { updates: historyUpdates(events) }
  })().then(
    (result) => tell({ jsonrpc: '2.0', id: request.id, result }),
    (error) => {
      logger.warn(`spot-chat-bridge: couldn't read the history of ${sessionId}: ${String(error)}`)
      tell({ jsonrpc: '2.0', id: request.id, error: { code: -32603, message: String(error?.message ?? error) } })
    },
  )
  return true
}

/**
 * A session's events as ACP session updates, made as dsh's ACP server makes them live, with the questions
 * and the end of each turn added: `_spotchat_turn_end` carries its stop reason, `end_turn`, `cancelled` or
 * `error` with the error's message.
 */
function historyUpdates(events) {
  const updates = []
  for (const event of events) {
    const data = event.data ?? {}
    if (event.type === 'user/message') {
      const update = questionUpdate(event)
      if (update !== undefined) updates.push(update)
    } else if (event.type === 'assistant/message') {
      for (const block of data.message?.content ?? []) {
        if (block.type === 'reasoning' && block.text) {
          updates.push({ sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: block.text } })
        } else if (block.type === 'text' && block.text) {
          updates.push({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: block.text } })
        }
      }
    } else if (event.type === 'tool/call') {
      let input
      try {
        input = JSON.parse(data.arguments)
      } catch {
        input = data.arguments
      }
      updates.push({
        sessionUpdate: 'tool_call', toolCallId: data.callId, title: data.name, kind: 'other',
        status: 'in_progress', rawInput: input,
      })
    } else if (event.type === 'tool/result') {
      const message = data.message ?? {}
      updates.push({
        sessionUpdate: 'tool_call_update', toolCallId: message.toolCallId,
        status: message.isError === true ? 'failed' : 'completed',
        content: (message.content ?? []).filter((block) => block.type === 'text')
          .map((block) => ({ type: 'content', content: { type: 'text', text: block.text } })),
      })
    } else if (event.type === 'turn/end') {
      // In ACP's words where it has them: dsh's turn ends completed, aborted or with an error.
      const kind = data.reason?.kind
      updates.push({
        sessionUpdate: '_spotchat_turn_end',
        stopReason: kind === 'aborted' ? 'cancelled' : kind === 'error' ? 'error' : 'end_turn',
        ...(kind === 'error' ? { error: data.reason?.error?.message ?? '' } : {}),
      })
    }
  }
  return updates
}

/** A question someone asked, as an ACP update; dsh's runtime and time notes aren't questions. */
function questionUpdate(event) {
  if (event.type !== 'user/message' || event.data?.source?.kind !== 'user') return undefined
  // A question of files alone still comes through, with no text, so Spot Chat knows its own came back.
  const text = (event.data.content ?? []).filter((block) => block.type === 'text').map((block) => block.text).join('\n')
  return { sessionUpdate: 'user_message_chunk', messageId: event.data.id, content: { type: 'text', text } }
}

/**
 * What happens to a connection's sessions when Spot Chat goes. dsh's ACP server then cancels what each of
 * its sessions is doing before it lets go of them: once as the prompt's request is aborted, again as it
 * closes the session. Those cancels are passed over, so a turn under way, Spot Chat's or one started in
 * dsh's interface, finishes. They come at once; a cancel after that, as Spot Chat asks for, goes through.
 * The sessions themselves stay open in dsh, so Spot Chat joins them again when it comes back.
 */
function detacher() {
  const agents = new Set()
  return {
    watch: (agent) => agents.add(agent),
    start: () => {
      // Both come within a millisecond or two of the close.
      const until = Date.now() + 100
      for (const agent of agents) passOverCancels(agent, until)
    },
  }
}

const cancelsPassedOverUntil = new WeakMap()

function passOverCancels(agent, until) {
  if (!cancelsPassedOverUntil.has(agent)) {
    const cancel = agent.cancel
    agent.cancel = function (...args) {
      if (Date.now() < cancelsPassedOverUntil.get(agent)) return
      return cancel.apply(this, args)
    }
  }
  cancelsPassedOverUntil.set(agent, until)
}

/**
 * The socket as a web stream of lines, which tells `ending` before it ends so ending comes first. A request
 * `answer` takes, one of the plugin's own, doesn't go on to dsh's ACP server.
 */
function readable(socket, ending, answer) {
  return new ReadableStream({
    start(controller) {
      let ended = false
      let pending = ''
      // A character split between two reads is held until its other bytes come.
      const decoder = new StringDecoder('utf8')
      const end = () => {
        if (ended) return
        ended = true
        // Nothing may throw out of a socket's event: it would take dsh down.
        try {
          ending()
        } catch {}
        try {
          controller.close()
        } catch {}
      }
      socket.on('data', (chunk) => {
        if (ended) return
        pending += decoder.write(chunk)
        let end
        while ((end = pending.indexOf('\n')) >= 0) {
          const line = pending.slice(0, end + 1)
          pending = pending.slice(end + 1)
          if (!answered(line)) controller.enqueue(new TextEncoder().encode(line))
        }
      })
      const answered = (line) => {
        if (!line.includes('"_spotchat/')) return false
        try {
          return answer(JSON.parse(line))
        } catch {
          return false
        }
      }
      socket.once('end', end)
      socket.once('close', end)
      socket.resume()
    },
  })
}

/**
 * The model new sessions start with: DeepSeek's flash model when this dsh has it, else the first model of
 * the first provider that lists any.
 */
async function startingModel(llm) {
  const found = []
  for (const provider of llm.listProviders()) {
    let models = []
    try {
      models = await llm.listModels(provider.id)
    } catch {
      continue
    }
    for (const model of models) found.push({ provider: provider.id, model: model.id })
  }
  return found.find((s) => /deepseek/i.test(s.provider) && /flash/i.test(s.model)) ?? found[0] ?? {}
}

let acpVersion = ''

/**
 * dsh's ACP server and the ACP SDK, from the dsh running this plugin, so their versions always match it.
 * They are looked up from this package first, then from dsh's own installation.
 */
async function loadAcp() {
  const anchors = [import.meta.url, process.argv[1], ...process.execArgv].filter(Boolean)
  for (const anchor of anchors) {
    try {
      const require = createRequire(anchor.startsWith('file:') ? anchor : pathToFileURL(anchor).href)
      const acpPath = resolveAcp(require)
      const fromAcp = createRequire(pathToFileURL(acpPath).href)
      const acp = await import(pathToFileURL(acpPath).href)
      const sdk = await import(pathToFileURL(fromAcp.resolve('@agentclientprotocol/sdk')).href)
      acpVersion = JSON.parse(readFileSync(fromAcp.resolve('@deepseek-ai/dsh-acp/package.json'), 'utf8')).version
      return { acp, ndJsonStream: sdk.ndJsonStream }
    } catch {
      // Try the next place.
    }
  }
  throw new Error('dsh-acp is not in this dsh installation')
}

function resolveAcp(require) {
  try {
    return require.resolve('@deepseek-ai/dsh-acp')
  } catch {
    // Older layouts keep it under the ACP app.
    const app = require.resolve('@deepseek-ai/dsh-acp-app/package.json')
    return createRequire(pathToFileURL(app).href).resolve('@deepseek-ai/dsh-acp')
  }
}

/** The connection's first line, and whatever arrived after it. */
function firstLine(socket) {
  return new Promise((resolve, reject) => {
    let buffered = Buffer.alloc(0)
    const onData = (chunk) => {
      buffered = Buffer.concat([buffered, chunk])
      const end = buffered.indexOf(0x0a)
      if (end >= 0) {
        cleanup()
        socket.pause()
        resolve({ line: buffered.subarray(0, end).toString('utf8'), rest: buffered.subarray(end + 1) })
      } else if (buffered.length > handshakeLimit) {
        cleanup()
        reject(new Error('handshake too long'))
      }
    }
    const onEnd = () => {
      cleanup()
      reject(new Error('closed before the handshake'))
    }
    const cleanup = () => {
      socket.off('data', onData)
      socket.off('end', onEnd)
      socket.off('error', onEnd)
    }
    socket.on('data', onData)
    socket.once('end', onEnd)
    socket.once('error', onEnd)
  })
}
