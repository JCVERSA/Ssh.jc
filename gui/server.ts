import express from 'express';
import path from 'path';
import { fileURLToPath } from 'url';
import { createServer as createViteServer } from 'vite';
import { apiRouter } from './server/routes.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

process.on('uncaughtException', (err) => {
  console.error('[SSH.JC] Caught uncaughtException:', err.message);
});

process.on('unhandledRejection', (reason) => {
  console.error('[SSH.JC] Caught unhandledRejection:', reason);
});

import http from 'http';

async function startServer() {
  const app = express();
  const PORT = Number(process.env.PORT) || 3000;
  const httpServer = http.createServer(app);

  app.use(express.json());
  app.use(express.urlencoded({ extended: true }));

  // API router
  app.use('/api', apiRouter);

  // Health endpoint
  app.get('/api/health', (req, res) => {
    res.json({
      status: 'ok',
      service: 'ssh.jc-control-center',
      uptime: process.uptime(),
      timestamp: new Date().toISOString()
    });
  });

  // Global API error handler ensuring JSON responses
  app.use('/api', (err: any, req: express.Request, res: express.Response, next: express.NextFunction) => {
    console.error('[SSH.JC] API error:', err);
    res.status(500).json({
      success: false,
      error: err.message || 'Internal server error'
    });
  });

  const isProd = process.env.NODE_ENV === 'production';

  if (isProd) {
    const distPath = path.resolve(__dirname, 'dist');
    app.use(express.static(distPath));
    app.get('*', (req, res) => {
      res.sendFile(path.join(distPath, 'index.html'));
    });
  } else {
    // Mount Vite in middleware mode and attach HMR to httpServer
    const vite = await createViteServer({
      server: {
        middlewareMode: true,
        hmr: {
          server: httpServer,
        },
      },
      appType: 'spa',
    });
    app.use(vite.middlewares);
  }

  httpServer.listen(PORT, '0.0.0.0', () => {
    console.log(`[SSH.JC] Control Center operational on port ${PORT}`);
  });
}

startServer().catch(err => {
  console.error('[SSH.JC] Failed to initialize server:', err);
  process.exit(1);
});
