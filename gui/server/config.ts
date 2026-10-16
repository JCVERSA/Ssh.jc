// Central server configuration for the SSH.JC Control Center.
//
// The console protects its OWN listening port: a tunnel must never be pointed
// at the port this web UI runs on, or the operator would expose (or break)
// the management interface itself.

export const GUI_PORT: number = (() => {
  const raw = process.env.GUI_PORT || process.env.PORT;
  const parsed = raw ? Number(raw) : NaN;
  return Number.isInteger(parsed) && parsed >= 1 && parsed <= 65535 ? parsed : 3000;
})();

export const HOME_DIR: string = process.env.HOME || '/root';
