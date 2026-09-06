#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { CATALOGUE_PATH, collectIOSContext, contentForContext, stampCatalogue, validateCatalogue, verifyInstalledCatalogue } from './ios-release-notes-lib.mjs';

const value = key => { const i = process.argv.indexOf(key); return i < 0 ? undefined : process.argv[i + 1]; };
const version = value('--version');
const build = value('--build');
const cataloguePath = value('--catalogue') ?? CATALOGUE_PATH;
if (!/^\d+\.\d+\.\d+$/.test(version ?? '') || !/^[1-9]\d*$/.test(build ?? '')) throw new Error('Pass --version x.y.z --build positive-integer');
let catalogue = validateCatalogue(JSON.parse(await readFile(cataloguePath, 'utf8')));
const options = {
    apiKey: process.env.OPENAI_API_KEY,
    onFallback: error => console.error(`::warning::iOS notes: ${error.message}; using source-verified change areas`),
};
let publishedPreviousTag;
if (process.argv.includes('--published-history')) {
    // Only actual published releases belong in history; a failed/unpublished
    // tag (for example v1.5.15) must not create an apparent shipped version.
    const releases = JSON.parse(execFileSync('gh', ['api', 'repos/crmitchelmore/pasta/releases?per_page=100'], { encoding: 'utf8' }))
        .filter(release => !release.draft && !release.prerelease && /^v\d+\.\d+\.\d+$/.test(release.tag_name))
        .filter(release => release.tag_name.slice(1).localeCompare(version, 'en', { numeric: true }) <= 0)
        .sort((a, b) => b.tag_name.localeCompare(a.tag_name, 'en', { numeric: true }));
    const isAncestor = (tag, ref) => {
        try { execFileSync('git', ['merge-base', '--is-ancestor', tag, ref], { stdio: 'ignore' }); return true; } catch { return false; }
    };
    publishedPreviousTag = releases.find(release => release.tag_name !== `v${version}` && isAncestor(release.tag_name, 'HEAD'))?.tag_name;
    if (!publishedPreviousTag) throw new Error('No preceding published release is reachable from this source');
    for (const release of releases.slice(0, 12).reverse()) {
        const historicalVersion = release.tag_name.slice(1);
        if (historicalVersion === version || catalogue.entries.some(entry => entry.version === historicalVersion && !entry.build)) continue;
        const previous = releases.find(other => other.tag_name.localeCompare(release.tag_name, 'en', { numeric: true }) < 0 && isAncestor(other.tag_name, release.tag_name));
        if (!previous) continue;
        const context = collectIOSContext({ version: historicalVersion, ref: release.tag_name, previousTag: previous.tag_name });
        catalogue = stampCatalogue({ catalogue, context, version: historicalVersion, content: await contentForContext(context, options) });
    }
}
const context = collectIOSContext({ version, previousTag: value('--previous-tag') ?? publishedPreviousTag });
// Keep carefully reviewed historical prose if the exact tag is being rebuilt.
const curated = catalogue.entries.find(entry => entry.version === version && !entry.build);
let isTaggedSource = false;
try { isTaggedSource = execFileSync('git', ['rev-parse', `v${version}^{commit}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() === context.sha; } catch {}
const content = curated && isTaggedSource ? { summary: curated.summary, changes: curated.changes } : await contentForContext(context, options);
catalogue = stampCatalogue({ catalogue, context, version, build, content });
verifyInstalledCatalogue({ catalogue, version, build, sha: context.sha });
await writeFile(cataloguePath, JSON.stringify(catalogue, null, 2) + '\n');
console.log(`Bundled iOS notes for ${version} (${build}) from ${context.sha}`);
