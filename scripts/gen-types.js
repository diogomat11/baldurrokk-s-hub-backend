#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

(async () => {
  try {
    const root = path.resolve(__dirname, '..');
    const projectRefPath = path.join(root, 'supabase', '.temp', 'project-ref');
    if (!fs.existsSync(projectRefPath)) {
      console.error('[gen-types] project-ref not found at', projectRefPath);
      process.exit(1);
    }
    const projectRef = fs.readFileSync(projectRefPath, 'utf8').trim();
    if (!projectRef) {
      console.error('[gen-types] project-ref is empty');
      process.exit(1);
    }

    const outDir = path.join(root, 'backend', 'src', 'types');
    const outFile = path.join(outDir, 'supabase.d.ts');
    fs.mkdirSync(outDir, { recursive: true });

    const cmdStr = `npx -y @supabase/cli gen types typescript --project-id ${projectRef} --schema public`;
    console.log('[gen-types] Running:', cmdStr);
    const proc = spawn(cmdStr, { cwd: root, shell: true, stdio: ['ignore', 'pipe', 'inherit'] });

    let output = '';
    proc.stdout.on('data', (chunk) => { output += chunk.toString(); });
    proc.on('error', (err) => {
      console.error('[gen-types] spawn error:', err);
      process.exit(1);
    });
    proc.on('close', (code) => {
      if (code !== 0) {
        console.error('[gen-types] command exited with code', code);
        process.exit(code);
      }
      if (!output.trim().length) {
        console.error('[gen-types] empty output');
        process.exit(1);
      }
      fs.writeFileSync(outFile, output, 'utf8');
      console.log('[gen-types] Types written to', outFile);
    });
  } catch (e) {
    console.error('[gen-types] fatal error:', e);
    process.exit(1);
  }
})();