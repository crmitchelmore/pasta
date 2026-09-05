// Guards the auto-release job condition in .github/workflows/ci.yml.
//
// GitHub skips a job when ANY transitive dependency was skipped unless the
// job's `if` uses always(). auto-release depends on ci-gate, which depends on
// the path-filtered Playwright job; dropping always() silently stopped every
// release tag on 2026-09-05 while the whole run looked green.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const ci = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../../.github/workflows/ci.yml'), 'utf8');

function jobBlock(name) {
  const start = ci.indexOf(`\n  ${name}:\n`);
  assert.ok(start >= 0, `job ${name} must exist in ci.yml`);
  const rest = ci.slice(start + 1);
  const next = rest.slice(1).search(/\n {2}[a-z][\w-]*:\n/);
  return next >= 0 ? rest.slice(0, next + 1) : rest;
}

test('auto-release depends only on ci-gate, survives skipped upstream jobs, and stops on cancellation', () => {
  const block = jobBlock('auto-release');
  assert.match(block, /needs:\s*\[ci-gate\]/, 'auto-release must depend on the aggregate gate only');
  const iff = block.match(/^\s+if:\s*(.+)$/m)?.[1] ?? '';
  assert.match(iff, /always\(\)/, "auto-release `if` must use always() or a skipped landing-e2e skips the tag");
  assert.match(iff, /!cancelled\(\)/, "auto-release must stop when an operator cancels the workflow");
  assert.match(iff, /needs\.ci-gate\.result == 'success'/, 'auto-release must require ci-gate success explicitly');
  assert.match(iff, /github\.event_name == 'push'/);
  assert.match(iff, /refs\/heads\/main/);
});

test('ci-gate always runs and covers every surface', () => {
  const block = jobBlock('ci-gate');
  assert.match(block, /if:\s*\$\{\{\s*always\(\)\s*\}\}/, 'ci-gate must always run so it can be a required check');
  for (const dep of ['test', 'ios-e2e', 'appcast-contract', 'landing-changes', 'landing-e2e']) {
    assert.ok(block.includes(dep), `ci-gate must need ${dep}`);
  }
});
