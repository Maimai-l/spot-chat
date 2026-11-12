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
import { Readable, Writable } from 'node:stream'
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

  ctx.effect(() => {
    mkdirSync(directory, { recursive: true, mode: 0o700 })
    chmodSync(directory, 0o700)
    rmSync(socketPath, { force: true })
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
      chmodSync(socketPath, 0o600)
      logger.info(`spot-chat-bridge: listening on ${socketPath}`)
    })
    return () => {
      for (const socket of connections) socket.destroy()
      server.close()
      rmSync(socketPath, { force: true })
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
    const stream = ndJsonStream(Writable.toWeb(socket), Readable.toWeb(socket))
    // A session needs a model to start from; Spot Chat then sets the one it uses.
    const selection = config.provider && config.model
      ? { provider: config.provider, model: config.model }
      : await startingModel(ctx.llm)
    const fiber = ctx.plugin({
      name: 'spot-chat-bridge-connection',
      inject: acp.inject,
      apply: (connection) => acp.apply(connection, { stream, sessionListPageSize: 100, ...selection }),
    })
    logger.info('spot-chat-bridge: Spot Chat connected')
    socket.once('close', () => {
      logger.info('spot-chat-bridge: Spot Chat disconnected')
      fiber.dispose()
    })
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
