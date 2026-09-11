
# Body of `git filter-repo --commit-callback`, appended to _prelude.py.
#
# Author and committer dates are deliberately NOT touched. Preserving them is a
# requirement, and it is also what makes the rewrite deterministic: identical input
# history always yields identical output SHAs, so the daily force-push is a no-op
# whenever nothing changed upstream.

commit.author_name, commit.author_email = map_identity(commit.author_name, commit.author_email)
commit.committer_name, commit.committer_email = map_identity(commit.committer_name, commit.committer_email)
commit.message = rewrite_message(commit.message)
