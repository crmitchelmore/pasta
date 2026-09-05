#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { verifyInstalledCatalogue } from './ios-release-notes-lib.mjs';

const [appPath, version, build, sha] = process.argv.slice(2);
if (!appPath || !version || !build || !sha) throw new Error('Usage: verify-ios-release-notes.mjs APP VERSION BUILD SHA');
const plist = JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', join(appPath, 'Info.plist')], { encoding: 'utf8' }));
if (plist.CFBundleShortVersionString !== version || plist.CFBundleVersion !== build) throw new Error('Installed app version/build mismatch');
async function findNotes(path) {
    const found = [];
    for (const entry of await readdir(path, { withFileTypes: true })) {
        if (entry.isDirectory()) found.push(...await findNotes(join(path, entry.name)));
        else if (entry.name === 'IOSReleaseNotes.json') found.push(join(path, entry.name));
    }
    return found;
}
const files = await findNotes(appPath);
if (files.length !== 1) throw new Error(`Expected one bundled iOS release catalogue, found ${files.length}`);
const shipped = JSON.parse(await readFile(files[0], 'utf8'));
verifyInstalledCatalogue({ catalogue: shipped, version, build, sha });
// Detect a stale resource copied from a build cache, including changed prose.
const prepared = JSON.parse(await readFile('Sources/PastaCore/Resources/IOSReleaseNotes.json', 'utf8'));
if (JSON.stringify(shipped) !== JSON.stringify(prepared)) throw new Error('Shipped release catalogue differs from prepared notes');
console.log(`Verified shipped iOS notes for ${version} (${build})`);
