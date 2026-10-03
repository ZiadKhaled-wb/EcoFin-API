// Cloudflare Workers entry point.
//
// Uses the `cloudflare:node` compatibility layer to run the Express app
// on Workers. The `httpServerHandler` wraps the app and provides a fetch
// handler that the Workers runtime can invoke.
//
import { httpServerHandler } from 'cloudflare:node';
import { createApp } from './app.js';
import { getEnv } from './utils/env.js';

// Throws one clear error naming every bad or missing variable.
const env = getEnv();

const app = createApp({ env });

app.listen(env.PORT);

export default httpServerHandler({ port: env.PORT });
