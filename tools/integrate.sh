#!/bin/bash
# Rebuild the dev branch from the topic branches.
#
# dev is GENERATED. Never commit to it directly: anything committed here is
# lost the next time this runs. Feature work goes on a topic branch; things
# that must never reach a PR (this script, CLAUDE.md, the README's fork
# sections, design sketches, tooling) are the FORK_ONLY list below.
#
# git rerere is enabled in this repo, so the integration conflicts you resolve
# once are replayed automatically on every later run.
set -e
cd "$(dirname "$0")/.."

TOPICS="upstream-fixes canada-cfs ble-traffic glasses-hud"   # glasses-hud carries precision-approach
FORK_ONLY="f71139e 16116bf 9d8574d 8855b26 809f195 e57edc0 f1cc281 79f365d e0d147b d7ee1bf"

git fetch upstream
git checkout -B dev upstream/master

for t in $TOPICS; do
  echo "== merging $t"
  git merge --no-edit "$t" || { echo "resolve, 'git add -A && git commit --no-edit', then re-run"; exit 1; }
done

for c in $FORK_ONLY; do
  echo "== fork-only $c"
  git cherry-pick -x "$c" || { echo "resolve, 'git cherry-pick --continue', then re-run"; exit 1; }
done

flutter pub get
echo
echo "dev rebuilt. Verify with: flutter analyze && flutter test"
