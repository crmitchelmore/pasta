import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { buildPrompt } from '../../scripts/release-notes-lib.mjs';
import { collectIOSContext, contentForContext, stampCatalogue, validateCatalogue, verifyInstalledCatalogue } from '../../scripts/ios-release-notes-lib.mjs';

const catalogue = JSON.parse(readFileSync(new URL('../../Sources/PastaCore/Resources/IOSReleaseNotes.json', import.meta.url)));
const context = { platform: 'ios', sha: 'abc123', date: '2026-09-05', compareURL: 'https://github.com/crmitchelmore/pasta/compare/v1.5.18...abc123', commits: [], fileSummary: '' };

test('bundled historical prose is valid and does not advertise unpublished 1.5.15', () => {
    validateCatalogue(catalogue);
    assert.deepEqual(catalogue.entries.map(entry => entry.version), ['1.5.18', '1.5.17', '1.5.16', '1.5.14']);
    assert.match(catalogue.entries[0].changes[0], /Mac app/);
});

test('stamp and verification require the exact version, build and source commit', () => {
    const result = stampCatalogue({ catalogue, context, version: '1.5.19', build: '140', content: { summary: 'Reliable history.', changes: ['Downloaded changes are saved before sync advances.'] } });
    verifyInstalledCatalogue({ catalogue: result, version: '1.5.19', build: '140', sha: 'abc123' });
    for (const mismatch of [{ build: '141' }, { version: '1.5.18' }, { sha: 'other' }]) {
        assert.throws(() => verifyInstalledCatalogue({ catalogue: result, version: '1.5.19', build: '140', sha: 'abc123', ...mismatch }));
    }
    assert.equal(result.entries.length, catalogue.entries.length + 1);
    assert.throws(() => validateCatalogue({ entries: [...result.entries, result.entries[0]] }), /Duplicate/);
    assert.throws(() => validateCatalogue({ entries: [] }), /empty/);
});

test('iOS generation excludes Mac-only features and fallback does not invent changes', async () => {
    assert.match(buildPrompt({ ...context, tag: 'v1.5.19' }), /do not advertise Mac-only/);
    assert.match((await contentForContext(context)).summary, /No iPhone or shared-library changes/);
    const content = await contentForContext({ ...context, commits: [{ sha: 'abcd', subject: 'fix: a technical implementation change' }], fileSummary: 'Sources/PastaSync/SyncManager.swift | 2 +' });
    assert.deepEqual(content.changes, ['The shared iCloud sync implementation was updated.', 'See the full changelog for the source changes.']);
    assert.doesNotMatch(JSON.stringify(content), /technical implementation/);
});

test('generator uses iOS source paths and supports untagged future releases without hardcoding a version', async () => {
    const cwd = mkdtempSync(join(tmpdir(), 'pasta-ios-notes-'));
    const git = (...args) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
    try {
        git('init'); git('config', 'user.name', 'Notes Test'); git('config', 'user.email', 'notes@example.invalid');
        mkdirSync(join(cwd, 'Sources/PastaSync'), { recursive: true });
        mkdirSync(join(cwd, 'Sources/PastaApp'), { recursive: true });
        writeFileSync(join(cwd, 'Sources/PastaSync/sync.swift'), 'baseline');
        git('add', '.'); git('commit', '-m', 'Initial'); git('tag', 'v1.5.18');
        writeFileSync(join(cwd, 'Sources/PastaApp/mac.swift'), 'Mac-only hotkey');
        git('add', '.'); git('commit', '-m', 'feat(mac): add a new hotkey');
        writeFileSync(join(cwd, 'Sources/PastaSync/sync.swift'), 'saved changes');
        git('add', '.'); git('commit', '-m', 'fix(sync): save downloaded changes');
        const collected = collectIOSContext({ version: '1.5.19', cwd });
        assert.equal(collected.previousTag, 'v1.5.18');
        assert.equal(collected.commits.length, 1);
        assert.doesNotMatch(JSON.stringify(collected), /hotkey/);
        const target = join(cwd, 'notes.json');
        writeFileSync(target, JSON.stringify(catalogue));
        execFileSync(process.execPath, [resolve('scripts/prepare-ios-release-notes.mjs'), '--version', '1.5.19', '--build', '140', '--catalogue', target], { cwd, env: { ...process.env, OPENAI_API_KEY: '' }, stdio: ['ignore', 'pipe', 'pipe'] });
        verifyInstalledCatalogue({ catalogue: JSON.parse(readFileSync(target)), version: '1.5.19', build: '140', sha: git('rev-parse', 'HEAD') });
        git('tag', 'v1.5.19');
        assert.equal(collectIOSContext({ version: '1.5.19', cwd }).previousTag, 'v1.5.18');
        mkdirSync(join(cwd, 'release-notes/ios'), { recursive: true });
        writeFileSync(join(cwd, 'release-notes/ios/readable.json'), JSON.stringify({ summary: 'Saved history is ready immediately.', changes: ['Use local history while iCloud reconnects.'] }));
        git('add', '.'); git('commit', '-m', 'fix(ios): offline recovery');
        const withFragment = collectIOSContext({ version: '1.5.20', cwd });
        assert.deepEqual(await contentForContext(withFragment), { summary: 'Saved history is ready immediately.', changes: ['Use local history while iCloud reconnects.'] });
        git('tag', 'v1.5.20');
        assert.equal(collectIOSContext({ version: '1.5.21', cwd }).reviewedContent, undefined, 'Old highlights must not leak into the next release');
    } finally { rmSync(cwd, { recursive: true, force: true }); }
});

test('release archives prepare and verify the actual resource before upload', () => {
    const workflow = readFileSync(new URL('../../.github/workflows/release-ios.yml', import.meta.url), 'utf8');
    assert.ok(workflow.indexOf('prepare-ios-release-notes.mjs') < workflow.indexOf('- name: Archive PastaIOS'));
    assert.ok(workflow.indexOf('verify-ios-release-notes.mjs') < workflow.indexOf('- name: Export IPA and upload'));
    assert.match(workflow, /--published-history/);
});
