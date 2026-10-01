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

test('successful main CI feeds Alpha without creating Stable tags', () => {
  assert.doesNotMatch(ci, /git tag -a/);
  const alpha=readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../../.github/workflows/alpha-release.yml'),'utf8');
  assert.match(alpha,/workflow_run/);
  assert.match(alpha,/conclusion == 'success'/);
  assert.match(alpha,/event == 'push'/);
  assert.match(alpha,/head_repository.full_name == github.repository/);
});

test('Alpha reconciliation dispatches with the workflow token', () => {
  const alpha=readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../../.github/workflows/alpha-release.yml'),'utf8');
  // A personal token without Actions write cannot create workflow dispatches
  // (HTTP 403 on every hourly pass); the workflow grants actions: write.
  assert.match(alpha,/actions: write/);
  assert.match(alpha,/GH_TOKEN: \$\{\{ github\.token \}\}/);
  assert.doesNotMatch(alpha,/AUTO_RELEASE_TOKEN/);
});

test('ci-gate always runs and covers every surface', () => {
  const block = jobBlock('ci-gate');
  assert.match(block, /if:\s*\$\{\{\s*always\(\)\s*\}\}/, 'ci-gate must always run so it can be a required check');
  for (const dep of ['test', 'ios-e2e', 'appcast-contract', 'landing-changes', 'landing-e2e']) {
    assert.ok(block.includes(dep), `ci-gate must need ${dep}`);
  }
});
