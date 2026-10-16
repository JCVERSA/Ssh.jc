import { SystemStatusResponse, LogEntry, JobState, JobType } from './types';

async function parseJsonResponse<T>(res: Response, fallbackError: string): Promise<T> {
  const text = await res.text();
  let json: any;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`${fallbackError} (HTTP ${res.status}: server returned non-JSON response)`);
  }

  if (!res.ok || json.success === false) {
    throw new Error(json.error || fallbackError);
  }

  return json.data;
}

export async function fetchSystemStatus(): Promise<SystemStatusResponse> {
  const res = await fetch('/api/system/status');
  return parseJsonResponse<SystemStatusResponse>(res, 'Failed to fetch system status');
}

export async function fetchLogs(limit = 100): Promise<LogEntry[]> {
  const res = await fetch(`/api/system/logs?limit=${limit}`);
  try {
    const data = await parseJsonResponse<LogEntry[]>(res, 'Failed to fetch logs');
    return data || [];
  } catch {
    return [];
  }
}

export async function executeJob(
  type: JobType,
  parameters: Record<string, any> = {}
): Promise<JobState> {
  const res = await fetch('/api/jobs/execute', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ type, parameters })
  });

  return parseJsonResponse<JobState>(res, 'Job execution request failed');
}

export async function fetchJob(jobId: string): Promise<JobState> {
  const res = await fetch(`/api/jobs/${jobId}`);
  return parseJsonResponse<JobState>(res, `Failed to poll status for job ${jobId}`);
}

export async function cancelJob(jobId: string): Promise<void> {
  const res = await fetch(`/api/jobs/${jobId}/cancel`, { method: 'POST' });
  await parseJsonResponse<any>(res, 'Failed to cancel job');
}

export async function fetchSshConfig(): Promise<{ exists: boolean; content: string; backups: string[] }> {
  const res = await fetch('/api/ssh/config');
  return parseJsonResponse<{ exists: boolean; content: string; backups: string[] }>(
    res,
    'Failed to fetch sshd configuration'
  );
}

export async function stopTunnel(tunnelName: string): Promise<JobState> {
  const res = await fetch('/api/tunnels/stop', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ tunnelName })
  });
  return parseJsonResponse<JobState>(res, `Failed to stop tunnel ${tunnelName}`);
}

export async function fetchSession(): Promise<boolean> {
  try {
    const res = await fetch('/api/auth/session');
    const data = await parseJsonResponse<{ authenticated: boolean }>(res, 'Failed to check session');
    return Boolean(data?.authenticated);
  } catch {
    return false;
  }
}

export async function login(password: string): Promise<void> {
  const res = await fetch('/api/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password })
  });
  await parseJsonResponse<any>(res, 'Login failed');
}

export async function logout(): Promise<void> {
  try {
    await fetch('/api/auth/logout', { method: 'POST' });
  } catch {
    // Session cookie is cleared server-side on success; ignore transport errors.
  }
}
