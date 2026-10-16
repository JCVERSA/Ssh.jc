import { Router, Request, Response } from 'express';
import fs from 'fs';
import path from 'path';
import { getSystemInfo, getSshStatus, getTunnels, getRecentLogs, getProtectedInfra } from './systemService.js';
import { jobManager } from './jobManager.js';
import { JobType } from './types.js';

export const apiRouter = Router();

// 1. Full System and Service Status
apiRouter.get('/system/status', (req: Request, res: Response) => {
  try {
    const system = getSystemInfo();
    const ssh = getSshStatus();
    const tunnels = getTunnels();
    const protectedInfra = getProtectedInfra();
    const activeJob = jobManager.getActiveJob();

    res.json({
      success: true,
      data: {
        system,
        ssh,
        tunnels,
        protectedInfra,
        activeJob
      }
    });
  } catch (err) {
    res.status(500).json({
      success: false,
      error: (err as Error).message
    });
  }
});

// 2. Protected Infrastructure Safeguards Info
apiRouter.get('/system/safeguards', (req: Request, res: Response) => {
  res.json({
    success: true,
    data: getProtectedInfra()
  });
});

// 3. System & Install Logs
apiRouter.get('/system/logs', (req: Request, res: Response) => {
  const limit = Math.min(Number(req.query.limit) || 100, 500);
  const logs = getRecentLogs(limit);
  res.json({
    success: true,
    data: logs
  });
});

// 4. Execute Job
apiRouter.post('/jobs/execute', async (req: Request, res: Response) => {
  const { type, parameters = {} } = req.body;

  if (!type) {
    return res.status(400).json({
      success: false,
      error: 'Job type is required.'
    });
  }

  // Pre-validate port 3000 safeguard
  if (parameters.localPort === 3000 || parameters.localPort === '3000') {
    return res.status(403).json({
      success: false,
      error: 'SAFEGUARD DENIED: Port 3000 is reserved for AI Studio and the active Cloudflare ingress. You cannot configure or route a tunnel on port 3000.'
    });
  }

  try {
    const job = await jobManager.startJob(type as JobType, parameters);
    return res.status(202).json({
      success: true,
      message: `Job '${job.title}' scheduled.`,
      data: job
    });
  } catch (err: any) {
    const status = err.message.includes('currently active') ? 409 : 400;
    return res.status(status).json({
      success: false,
      error: err.message
    });
  }
});

// 5. Active Job
apiRouter.get('/jobs/active', (req: Request, res: Response) => {
  const activeJob = jobManager.getActiveJob();
  res.json({
    success: true,
    data: activeJob
  });
});

// 6. Job History
apiRouter.get('/jobs/history', (req: Request, res: Response) => {
  const history = jobManager.getHistory();
  res.json({
    success: true,
    data: history
  });
});

// 7. Job Details by ID
apiRouter.get('/jobs/:id', (req: Request, res: Response) => {
  const job = jobManager.getJob(req.params.id);
  if (!job) {
    return res.status(404).json({
      success: false,
      error: `Job with ID ${req.params.id} not found.`
    });
  }
  return res.json({
    success: true,
    data: job
  });
});

// 8. Cancel Job
apiRouter.post('/jobs/:id/cancel', (req: Request, res: Response) => {
  const job = jobManager.getJob(req.params.id);
  if (!job) {
    return res.status(404).json({
      success: false,
      error: 'Job not found.'
    });
  }

  const cancelled = jobManager.cancelActiveJob();
  if (cancelled) {
    return res.json({
      success: true,
      message: 'Job cancelled successfully.'
    });
  } else {
    return res.status(400).json({
      success: false,
      error: 'Job is not actively running or cannot be cancelled.'
    });
  }
});

// 9. Inspect SSH Config
apiRouter.get('/ssh/config', (req: Request, res: Response) => {
  const confPath = '/etc/ssh/sshd_config';
  if (!fs.existsSync(confPath)) {
    return res.json({
      success: true,
      data: {
        exists: false,
        content: '# /etc/ssh/sshd_config is not currently installed.',
        backups: []
      }
    });
  }

  try {
    const content = fs.readFileSync(confPath, 'utf8');
    const dir = '/etc/ssh';
    const backups = fs.existsSync(dir) 
      ? fs.readdirSync(dir).filter(f => f.startsWith('sshd_config.bak.'))
      : [];

    return res.json({
      success: true,
      data: {
        exists: true,
        content,
        backups
      }
    });
  } catch (err) {
    return res.status(500).json({
      success: false,
      error: (err as Error).message
    });
  }
});

// 10. Stop Tunnel Shortcut
apiRouter.post('/tunnels/stop', async (req: Request, res: Response) => {
  const { tunnelName } = req.body;
  if (!tunnelName) {
    return res.status(400).json({ success: false, error: 'Tunnel name is required.' });
  }

  try {
    const job = await jobManager.startJob('stop_tunnel', { tunnelName });
    return res.status(202).json({
      success: true,
      message: `Stopping tunnel '${tunnelName}'`,
      data: job
    });
  } catch (err: any) {
    return res.status(400).json({ success: false, error: err.message });
  }
});
