// Module Worker entry: the page spawns it through worker-client.ts.
import { createParserWorkerHost } from './worker-host'
import type { MessagePortLike } from './worker-protocol'

createParserWorkerHost(self as unknown as MessagePortLike)
