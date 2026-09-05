// Publication can create a public release and then fail while uploading assets.
// Query by tag whenever publication was attempted; action success is not proof
// of whether its external side effects happened.
export async function draftAttemptedRelease({ github, owner, repo, tag }) {
  let release;
  try {
    ({ data: release } = await github.rest.repos.getReleaseByTag({ owner, repo, tag }));
  } catch (error) {
    if (error.status === 404) return 'absent';
    throw new Error(`Cannot determine whether ${tag} is public; inspect the release immediately`, { cause: error });
  }
  if (release.draft) return 'already-draft';
  try {
    await github.rest.repos.updateRelease({ owner, repo, release_id: release.id, draft: true });
  } catch (error) {
    throw new Error(`Could not draft ${tag}; pull the public release immediately`, { cause: error });
  }
  return 'drafted';
}
