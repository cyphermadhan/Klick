#!/bin/sh
# Xcode Cloud runs this after cloning the repo and before building.
# Klick uses xcodegen to manage the .xcodeproj — committing the project
# is fine for normal flow, but if a contributor adds files via xcodegen
# and forgets to regenerate, CI would silently miss them. Regenerating
# here means the build always reflects project.yml.

set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen
fi

cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
