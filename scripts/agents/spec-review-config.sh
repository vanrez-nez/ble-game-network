#!/bin/sh

# Configuration for the protocol specification review lifecycle.
# Sourced by spec-review.sh — not executed directly.

# Directories (relative to ROOT_DIR, resolved by the orchestrator)
SPEC_DIR="$ROOT_DIR/protocol-spec"
ROLES_DIR="$SPEC_DIR/roles"
LOG_DIR="$ROOT_DIR/.build/spec-review"

# Pipeline steps (ordered)
STEPS="issues curate proposals merge review amends editor"

# Proposal configuration
PROPOSAL_COUNT="${PROPOSAL_COUNT:-2}"
PROPOSAL_IDS="${PROPOSAL_IDS:-a b}"

# Agent settings
MODEL="${MODEL:-opus}"
COMMIT="${COMMIT:-1}"

# Resolve the latest version number that has a published spec.md
resolve_latest_version() {
	for dir in $(ls -1d "$SPEC_DIR"/version-* 2>/dev/null | sort -t- -k2 -n -r); do
		if [ -f "$dir/spec.md" ]; then
			echo "$dir" | sed 's/.*version-//'
			return
		fi
	done
}

# Resolve the current baseline: protocol-spec/version-N/spec.md
resolve_baseline() {
	latest=$(resolve_latest_version)
	if [ -n "$latest" ]; then
		echo "$SPEC_DIR/version-${latest}/spec.md"
	else
		echo ""
	fi
}

# Compute the next version number
compute_next_version() {
	latest=$(resolve_latest_version)
	echo $(( ${latest:-0} + 1 ))
}
