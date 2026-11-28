// Guards the auto-release job condition in .github/workflows/ci.yml.
//
// GitHub skips a job when ANY transitive dependency was skipped unless the
// job's `if` uses always(). auto-release depends on ci-gate, which depends on
// the path-filtered Playwright job; dropping always() silently stopped every
// release tag on 2026-09-05 while the whole run looked green.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
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

// Extracts the `run: |` script of the named step so the shell that decides
// routing and the gate verdict is executed here, not pattern-matched.
function stepScript(name) {
  const start = ci.indexOf(`- name: ${name}\n`);
  assert.ok(start >= 0, `step ${name} must exist in ci.yml`);
  const lines = ci.slice(start).split('\n');
  const runAt = lines.findIndex((line) => /^\s+run: \|$/.test(line));
  const indent = lines[runAt + 1].match(/^\s*/)[0];
  const body = [];
  for (const line of lines.slice(runAt + 1)) {
    if (line.trim() !== '' && !line.startsWith(indent)) break;
    body.push(line.slice(indent.length));
  }
  return body.join('\n');
}

function runStep(name, env) {
  const dir = mkdtempSync(join(tmpdir(), 'ci-gate-'));
  const files = { GITHUB_OUTPUT: join(dir, 'out'), GITHUB_STEP_SUMMARY: join(dir, 'summary') };
  const result = spawnSync('bash', ['-c', stepScript(name)], { env: { PATH: process.env.PATH, ...files, ...env }, encoding: 'utf8' });
  const output = existsSync(files.GITHUB_OUTPUT) ? readFileSync(files.GITHUB_OUTPUT, 'utf8') : '';
  rmSync(dir, { recursive: true, force: true });
  return { status: result.status, output };
}

test('heavy native suites always run outside pull requests and when routed on a pull request', () => {
  const full = (env) => runStep('Decide whether the heavy native suites run', env).output.trim();
  for (const EVENT of ['push', 'workflow_dispatch']) {
    assert.equal(full({ EVENT, HEAVY: 'false', FULL_LABEL: 'false' }), 'full=true');
  }
  assert.equal(full({ EVENT: 'pull_request', HEAVY: 'false', FULL_LABEL: 'false' }), 'full=false');
  assert.equal(full({ EVENT: 'pull_request', HEAVY: 'true', FULL_LABEL: 'false' }), 'full=true');
  assert.equal(full({ EVENT: 'pull_request', HEAVY: 'false', FULL_LABEL: 'true' }), 'full=true');
  assert.match(jobBlock('ios-e2e'), /if: needs\.landing-changes\.outputs\.full == 'true'/);
  const smoke = ci.slice(ci.indexOf('- name: Launch smoke test'));
  assert.match(smoke.split('\n')[1], /if: env\.FULL == 'true'/);
  assert.match(jobBlock('test'), /FULL: \$\{\{ needs\.landing-changes\.outputs\.full \}\}/);
});

test('ci-gate defers the iOS suite only on a pull request routed as fast', () => {
  const green = { TEST: 'success', IOS: 'success', APPCAST: 'success', LANDING_CHANGES: 'success',
    LANDING_TOUCHED: 'false', FULL: 'true', LANDING_E2E: 'skipped', EVENT: 'push' };
  const gate = (change) => runStep('Evaluate every gate', { ...green, ...change }).status;
  assert.equal(gate({}), 0);
  assert.equal(gate({ EVENT: 'pull_request', FULL: 'false', IOS: 'skipped' }), 0);
  for (const change of [
    { IOS: 'skipped' },
    { EVENT: 'workflow_dispatch', FULL: 'false', IOS: 'skipped', LANDING_E2E: 'success' },
    { EVENT: 'pull_request', FULL: 'true', IOS: 'skipped' },
    { EVENT: 'pull_request', FULL: 'false', IOS: 'skipped', LANDING_CHANGES: 'failure' },
    { EVENT: 'pull_request', FULL: 'false', IOS: 'failure' },
    { EVENT: 'pull_request', FULL: 'false', IOS: 'cancelled' },
    { TEST: 'skipped' }, { TEST: 'failure' }, { APPCAST: 'cancelled' },
    { LANDING_TOUCHED: 'true' }, { EVENT: 'workflow_dispatch' }, { LANDING_E2E: 'failure' },
  ]) {
    assert.equal(gate(change), 1, JSON.stringify(change));
  }
});

test('pull requests cancel superseded runs; main runs always finish', () => {
  assert.match(ci, /cancel-in-progress: \$\{\{ github\.event_name == 'pull_request' \}\}/);
});

test('required PR checks are exactly the ci.yml jobs that always report on PRs', () => {
  const owner = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), '../owner-require-status-checks.sh'), 'utf8');
  const required = [...owner.matchAll(/"context": "([^"]+)"/g)].map((match) => match[1]);
  assert.deepEqual(required.sort(), ['Appcast & Cloudflare config contract', 'Build & Test', 'CI gate']);
  for (const context of required) {
    const job = ci.split(/\n(?= {2}[a-z][\w-]*:\n)/).find((block) => block.includes(`\n    name: ${context}\n`));
    assert.ok(job, `${context} must be a ci.yml job name`);
    const condition = job.match(/\n {4}if: (.+)/)?.[1];
    // A job skipped by its `if:` reports success, so a routed job here would be a false assurance.
    assert.ok(!condition || /always\(\)/.test(condition), `${context} must not be skipped on PRs`);
  }
  // The routed native suite stays enforced through the gate, not as a direct check.
  assert.match(jobBlock('ios-e2e'), /if: needs\.landing-changes\.outputs\.full == 'true'/);
});
