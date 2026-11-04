// Records every file a Node process resolves or loads, by import or require, into $SPOT_LOAD_LOG. The runtime
// build runs the smoke test with it to learn which packages of dsh load, and trims the rest.
import { registerHooks } from 'node:module'
import { appendFileSync } from 'node:fs'

const log = process.env.SPOT_LOAD_LOG
const record = (url) => {
  if (log && url?.startsWith('file:')) appendFileSync(log, url + '\n')
}
if (log) {
  registerHooks({
    resolve(specifier, context, next) {
      const result = next(specifier, context)
      record(result.url)
      return result
    },
    load(url, context, next) {
      record(url)
      return next(url, context)
    },
  })
}
