import { httpServerHandler } from 'cloudflare:node';
import { createApp } from './app.js';
import { env } from './utils/env.js';
import { logger } from './utils/logger.js';

const app = createApp();

app.listen(env.PORT, () => {
    logger.info({ port: env.PORT, env: env.NODE_ENV }, 'API listening');
});

export default httpServerHandler({ port: env.PORT });