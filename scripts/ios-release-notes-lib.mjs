import { execFileSync } from 'node:child_process';
import { parseCommits, generateReleaseNotes } from './release-notes-lib.mjs';

export const CATALOGUE_PATH = 'Sources/PastaCore/Resources/IOSReleaseNotes.json';
const paths = ['PastaIOS/PastaIOS', 'Sources/PastaCore', 'Sources/PastaSync', 'Sources/PastaDetectors'];
const git = (args, cwd) => execFileSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] }).trim();

export function validateCatalogue(catalogue) {
    if (!Array.isArray(catalogue.entries) || !catalogue.entries.length) throw new Error('Release catalogue is empty');
    const ids = new Set();
    for (const entry of catalogue.entries) {
        if (!/^\d+\.\d+\.\d+$/.test(entry.version)
            || (entry.build !== undefined && !/^[1-9]\d*$/.test(entry.build))
            || typeof entry.date !== 'string'
            || !entry.summary?.trim() || !entry.changes?.length
            || entry.changes.some(change => typeof change !== 'string' || !change.trim())
            || !/^https:\/\/github\.com\/crmitchelmore\/pasta\//.test(entry.source)) {
            throw new Error(`Invalid release entry: ${entry.version}`);
        }
        const id = `${entry.version}:${entry.build ?? 'version'}`;
        if (ids.has(id)) throw new Error(`Duplicate release entry: ${id}`);
        ids.add(id);
    }
    return catalogue;
}

export function collectIOSContext({ version, ref = 'HEAD', previousTag, cwd = process.cwd() }) {
    const sha = git(['rev-parse', '--verify', `${ref}^{commit}`], cwd);
    if (!previousTag) {
        try {
            previousTag = git(['describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*', '--exclude', `v${version}`, ref], cwd);
        } catch { throw new Error('No preceding release tag; fetch full history or specify --previous-tag'); }
    }
    git(['merge-base', '--is-ancestor', previousTag, sha], cwd);
    const range = `${previousTag}..${sha}`;
    const commits = parseCommits(git(['log', '--reverse', '--format=%H%x1f%s%x1f%b%x1e', range, '--', ...paths], cwd));
    const fragmentPaths = git(['diff', '--name-only', '--diff-filter=A', range, '--', 'release-notes/ios'], cwd).split('\n').filter(path => path.endsWith('.json'));
    const fragments = fragmentPaths.map(path => {
        const fragment = JSON.parse(git(['show', `${sha}:${path}`], cwd));
        if (!fragment.summary?.trim() || !fragment.changes?.length || fragment.changes.some(change => typeof change !== 'string' || !change.trim())) throw new Error(`Invalid iOS release fragment: ${path}`);
        return fragment;
    });
    return {
        reviewedContent: fragments.length ? { summary: fragments.map(fragment => fragment.summary).join(' '), changes: fragments.flatMap(fragment => fragment.changes) } : undefined,
        platform: 'ios', tag: `v${version}`, previousTag, commits, sha,
        changedPaths: git(['diff', '--name-only', range, '--', ...paths], cwd).split('\n').filter(Boolean),
        fileSummary: git(['diff', '--stat', range, '--', ...paths], cwd),
        compareURL: `https://github.com/crmitchelmore/pasta/compare/${previousTag}...${sha}`,
        date: git(['show', '-s', '--format=%cs', sha], cwd),
    };
}

// If model generation is unavailable, report only the areas proven by the
// changed paths. Never recycle another version's highlights or claim a fix
// that cannot be inferred from a filename.
export function fallbackContent(context) {
    const changes = [];
    // --stat may abbreviate long paths; use the full paths when available.
    const changedFiles = context.changedPaths?.join('\n') ?? context.fileSummary;
    const areas = [
        ['PastaIOS/', 'The iPhone app was updated.'],
        ['Sources/PastaCore/', 'Shared clipboard storage and app services were updated.'],
        ['Sources/PastaSync/', 'The shared iCloud sync implementation was updated.'],
        ['Sources/PastaDetectors/', 'Shared clipboard content detection was updated.'],
    ];
    for (const [path, change] of areas) if (changedFiles.includes(path)) changes.push(change);
    return {
        summary: changes.length ? 'Changes included in this iPhone build.' : 'No iPhone or shared-library changes in this release.',
        changes: changes.length ? [...changes, 'See the full changelog for the source changes.'] : ['This release contains changes to other parts of Pasta.'],
    };
}

export async function contentForContext(context, options = {}) {
    if (context.reviewedContent) return context.reviewedContent;
    if (!context.commits.length) return fallbackContent(context);
    const result = await generateReleaseNotes({ context, ...options });
    if (result.usedFallback) return fallbackContent(context);
    const lines = result.notes.split('\n').map(line => line.trim()).filter(line =>
        line && !line.startsWith('#') && !line.startsWith('<!--') && !line.startsWith('**Full changelog:'));
    const summary = lines.shift()?.replace(/^[-*+] /, '');
    const changes = lines.map(line => line.replace(/^[-*+] /, ''));
    return summary && changes.length ? { summary, changes } : fallbackContent(context);
}

export function stampCatalogue({ catalogue, context, version, build, content }) {
    const entry = { version, ...(build ? { build } : {}), date: context.date, ...content, source: context.compareURL, sourceCommit: context.sha };
    const entries = catalogue.entries.filter(old => !(old.version === version && old.build === build));
    return validateCatalogue({ entries: [entry, ...entries] });
}

export function verifyInstalledCatalogue({ catalogue, version, build, sha }) {
    validateCatalogue(catalogue);
    const entry = catalogue.entries.find(entry => entry.version === version && entry.build === build);
    if (!entry || entry.sourceCommit !== sha) throw new Error(`No release notes for installed ${version} (${build}) at ${sha}`);
    return entry;
}
