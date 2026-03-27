#!/bin/sh

# Protocol Specification Review Lifecycle — Agent Orchestrator
#
# Runs the 7-stage spec review process using Claude Code agents:
#   1. Issues     (serial)    — scan GitHub issues, update master backlog
#   2. Curate     (serial)    — filter backlog into version-specific scope
#   3. Proposals  (parallel)  — independent proposal authors
#   4. Merge      (serial)    — referee consolidates proposals
#   5. Review     (serial)    — external observer validates merge
#   6. Amends     (serial)    — referee records amendments from review
#   7. Editor     (serial)    — final editor produces publication-ready spec
#
# Directory layout:
#   protocol-spec/backlog/{issues,features}.md  — master backlog (persistent)
#   protocol-spec/version-N/spec.md             — baseline (current version)
#   protocol-spec/version-N/{features,issues}.md — curated scope for next cycle
#   protocol-spec/version-N+1/proposal-*.md     — agent outputs
#   protocol-spec/version-N+1/merge.md
#   protocol-spec/version-N+1/review.md
#   protocol-spec/version-N+1/merge.amends.md
#   protocol-spec/version-N+1/spec.md           — final publication
#
# Usage:
#   ./scripts/agents/spec-review.sh [step] [options]
#
# Steps:
#   issues      Run step 1 only
#   curate      Run step 2 only
#   proposals   Run step 3 only
#   merge       Run step 4 only
#   review      Run step 5 only
#   amends      Run step 6 only
#   editor      Run step 7 only
#   all         Run full lifecycle (default)
#
# Options:
#   --from <step>   Resume from a step through the end of the pipeline
#   --dry-run       Print what would be done without executing
#   --force         Overwrite existing output files without prompting
#   --no-commit     Skip auto-commits between steps
#
# Commit format:
#   spec(<step>): <description> [v<N>]

set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

. "$ROOT_DIR/scripts/agents/spec-review-config.sh"

# ── Defaults ──────────────────────────────────────────────────────────

DRY_RUN=0
FORCE=0
STEP="all"
FROM_STEP=""

# Parse args (handle --from which takes a value)
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run)   DRY_RUN=1 ;;
		--force)     FORCE=1 ;;
		--no-commit) COMMIT=0 ;;
		--from)      shift; FROM_STEP="$1"; STEP="all" ;;
		issues|curate|proposals|merge|review|amends|editor|all) STEP="$1" ;;
	esac
	shift
done

SPEC_BASELINE=$(resolve_baseline)
NEXT_VERSION=$(compute_next_version)
CURRENT_VERSION=$(resolve_latest_version)

# Derived paths
CURRENT_DIR="$SPEC_DIR/version-${CURRENT_VERSION}"
NEXT_DIR="$SPEC_DIR/version-${NEXT_VERSION}"
BACKLOG_DIR="$SPEC_DIR/backlog"
FEATURES_FILE="$CURRENT_DIR/features.md"
ISSUES_FILE="$CURRENT_DIR/issues.md"

# ── Helpers ───────────────────────────────────────────────────────────

info()  { printf '  [info]  %s\n' "$*"; }
error() { printf '  [error] %s\n' "$*" >&2; exit 1; }
step()  { printf '\n==> %s\n\n' "$*"; }

step_index() {
	_i=0
	for _s in $STEPS; do
		[ "$_s" = "$1" ] && echo "$_i" && return
		_i=$((_i + 1))
	done
	error "unknown step: $1"
}

preflight_common() {
	command -v claude >/dev/null 2>&1 \
		|| error "claude CLI not found in PATH"

	[ -n "$SPEC_BASELINE" ] && [ -f "$SPEC_BASELINE" ] \
		|| error "baseline spec not found: $SPEC_BASELINE"

	mkdir -p "$LOG_DIR"
}

preflight_spec() {
	[ -f "$FEATURES_FILE" ] \
		|| error "features file not found: $FEATURES_FILE (run 'curate' step first)"

	[ -f "$ISSUES_FILE" ] \
		|| error "issues file not found: $ISSUES_FILE (run 'curate' step first)"

	if ! grep -q '^### [FI]-' "$FEATURES_FILE" 2>/dev/null; then
		info "warning: $FEATURES_FILE has no entries (### F-N pattern not found)"
	fi

	if ! grep -q '^### [FI]-' "$ISSUES_FILE" 2>/dev/null; then
		info "warning: $ISSUES_FILE has no entries (### I-N pattern not found)"
	fi

	mkdir -p "$NEXT_DIR"
}

check_output() {
	_output_file="$1"
	_label="$2"

	if [ -f "$_output_file" ]; then
		if [ "$FORCE" = 1 ]; then
			info "overwriting existing $_label: $_output_file"
		else
			error "$_label already exists: $_output_file (use --force to overwrite)"
		fi
	fi
}

require_input() {
	_input_file="$1"
	_label="$2"

	[ -f "$_input_file" ] \
		|| error "$_label not found: $_input_file (run prior step first)"
}

commit_step() {
	_step_name="$1"
	_message="$2"
	shift 2

	if [ "$COMMIT" = 0 ]; then
		return 0
	fi

	if [ "$DRY_RUN" = 1 ]; then
		info "[dry-run] would commit: spec($_step_name): $_message [v${NEXT_VERSION}]"
		return 0
	fi

	git -C "$ROOT_DIR" add "$@"
	if ! git -C "$ROOT_DIR" diff --cached --quiet; then
		git -C "$ROOT_DIR" commit -m "spec($_step_name): $_message [v${NEXT_VERSION}]"
	else
		info "no changes to commit for $_step_name"
	fi
}

# ── Step 1: Issues (serial) ──────────────────────────────────────────

run_issues() {
	step "Step 1: Issues (scan GitHub issues → master backlog)"

	log_file="$LOG_DIR/issues.log"

	require_input "$BACKLOG_DIR/issues.md" "backlog/issues.md"
	require_input "$BACKLOG_DIR/features.md" "backlog/features.md"

	if [ "$DRY_RUN" = 1 ]; then
		info "[dry-run] would run: claude --agent spec-issues -p → backlog/{issues,features}.md"
		commit_step "issues" "update master backlog from github issues" \
			"$BACKLOG_DIR/issues.md" "$BACKLOG_DIR/features.md"
		return 0
	fi

	info "running issues manager agent..."

	claude --agent spec-issues -p \
		--model "$MODEL" \
		--dangerously-skip-permissions \
		"Read the current specification baseline at $SPEC_BASELINE.
Read the existing master backlogs:
- $BACKLOG_DIR/issues.md
- $BACKLOG_DIR/features.md

Scan GitHub issues for this repository using: gh issue list --state open --limit 100
For each relevant issue, use: gh issue view <number>

Examine the codebase under lua/ for code-to-spec divergences.

Update the master backlog files:
- Write issues to $BACKLOG_DIR/issues.md
- Write features to $BACKLOG_DIR/features.md

Preserve existing entries. Add new ones, update statuses of changed ones." \
		2>&1 | tee "$log_file"

	info "issues scan complete: $BACKLOG_DIR/{issues,features}.md"

	commit_step "issues" "update master backlog from github issues" \
		"$BACKLOG_DIR/issues.md" "$BACKLOG_DIR/features.md"
}

# ── Step 2: Curate (serial) ──────────────────────────────────────────

run_curate() {
	step "Step 2: Curate (filter backlog → version-${CURRENT_VERSION} scope)"

	log_file="$LOG_DIR/curate.log"

	require_input "$BACKLOG_DIR/issues.md" "backlog/issues.md"
	require_input "$BACKLOG_DIR/features.md" "backlog/features.md"

	check_output "$FEATURES_FILE" "version-${CURRENT_VERSION}/features.md"
	check_output "$ISSUES_FILE" "version-${CURRENT_VERSION}/issues.md"

	if [ "$DRY_RUN" = 1 ]; then
		info "[dry-run] would run: claude --agent spec-curator -p → version-${CURRENT_VERSION}/{features,issues}.md"
		commit_step "curate" "scope features and issues for revision cycle" \
			"$FEATURES_FILE" "$ISSUES_FILE"
		return 0
	fi

	info "running curator agent..."

	claude --agent spec-curator -p \
		--model "$MODEL" \
		--dangerously-skip-permissions \
		"Read the master backlogs:
- $BACKLOG_DIR/issues.md
- $BACKLOG_DIR/features.md

Read the current specification baseline at $SPEC_BASELINE.

Select and prioritize items for the next revision cycle.
Write the curated scope to:
- $FEATURES_FILE
- $ISSUES_FILE

Follow the role instructions for selection criteria and format." \
		2>&1 | tee "$log_file"

	[ -f "$FEATURES_FILE" ] \
		|| error "curator agent completed but features file not found: $FEATURES_FILE"
	[ -f "$ISSUES_FILE" ] \
		|| error "curator agent completed but issues file not found: $ISSUES_FILE"

	info "curation complete: $CURRENT_DIR/{features,issues}.md"

	commit_step "curate" "scope features and issues for revision cycle" \
		"$FEATURES_FILE" "$ISSUES_FILE"
}

# ── Step 3: Proposals (parallel) ─────────────────────────────────────

run_proposals() {
	preflight_spec

	step "Step 3: Proposals (parallel — $PROPOSAL_COUNT agents)"

	PIDS=""
	FAILED=0

	for id in $PROPOSAL_IDS; do
		output_file="$NEXT_DIR/proposal-${id}.md"
		log_file="$LOG_DIR/proposal-${id}.log"

		check_output "$output_file" "proposal-${id}"

		if [ "$DRY_RUN" = 1 ]; then
			info "[dry-run] would spawn: claude --agent spec-proposal -p → $output_file"
			continue
		fi

		info "spawning proposal-${id} agent..."

		claude --agent spec-proposal -p \
			--model "$MODEL" \
			--dangerously-skip-permissions \
			"Your proposal ID is: ${id}.
Read the baseline specification at $SPEC_BASELINE.
Read the feature backlog at $FEATURES_FILE.
Read the issues list at $ISSUES_FILE.
Examine the codebase under lua/ for implementation reality.
Write your complete proposal to $output_file following the role instructions exactly." \
			> "$log_file" 2>&1 &

		PIDS="$PIDS $!"
	done

	if [ "$DRY_RUN" = 1 ]; then
		# Build file list for dry-run commit
		_files=""
		for id in $PROPOSAL_IDS; do
			_files="$_files $NEXT_DIR/proposal-${id}.md"
		done
		commit_step "proposals" "proposals from $PROPOSAL_COUNT agents" $_files
		return 0
	fi

	for pid in $PIDS; do
		if ! wait "$pid"; then
			FAILED=$((FAILED + 1))
		fi
	done

	if [ "$FAILED" -gt 0 ]; then
		error "$FAILED proposal agent(s) failed — check logs in $LOG_DIR/"
	fi

	_files=""
	for id in $PROPOSAL_IDS; do
		output_file="$NEXT_DIR/proposal-${id}.md"
		if [ ! -f "$output_file" ]; then
			error "proposal-${id} agent completed but output not found: $output_file"
		fi
		info "proposal-${id} complete: $output_file"
		_files="$_files $output_file"
	done

	commit_step "proposals" "proposals from $PROPOSAL_COUNT agents" $_files
}

# ── Step 4: Merge (serial) ───────────────────────────────────────────

run_merge() {
	step "Step 4: Merge (referee consolidates proposals)"

	output_file="$NEXT_DIR/merge.md"
	log_file="$LOG_DIR/merge.log"

	check_output "$output_file" "merge"

	for id in $PROPOSAL_IDS; do
		require_input "$NEXT_DIR/proposal-${id}.md" "proposal-${id}"
	done

	proposal_refs=""
	for id in $PROPOSAL_IDS; do
		proposal_refs="$proposal_refs
- $NEXT_DIR/proposal-${id}.md"
	done

	if [ "$DRY_RUN" = 1 ]; then
		info "[dry-run] would run: claude --agent spec-referee -p → $output_file"
		info "[dry-run] inputs: baseline + $(echo "$PROPOSAL_IDS" | wc -w | tr -d ' ') proposals"
		commit_step "merge" "referee consolidation" "$output_file"
		return 0
	fi

	info "running referee agent..."

	claude --agent spec-referee -p \
		--model "$MODEL" \
		--dangerously-skip-permissions \
		"Read the baseline specification at $SPEC_BASELINE.
Read the following proposals:
$proposal_refs

Produce the consolidated merge document.
Write it to $output_file following the role instructions exactly." \
		2>&1 | tee "$log_file"

	[ -f "$output_file" ] \
		|| error "referee agent completed but output not found: $output_file"

	info "merge complete: $output_file"

	commit_step "merge" "referee consolidation" "$output_file"
}

# ── Step 5: Review (serial) ──────────────────────────────────────────

run_review() {
	step "Step 5: Review (external observer)"

	output_file="$NEXT_DIR/review.md"
	log_file="$LOG_DIR/review.log"

	check_output "$output_file" "review"
	require_input "$NEXT_DIR/merge.md" "merge"

	proposal_refs=""
	for id in $PROPOSAL_IDS; do
		require_input "$NEXT_DIR/proposal-${id}.md" "proposal-${id}"
		proposal_refs="$proposal_refs
- $NEXT_DIR/proposal-${id}.md"
	done

	if [ "$DRY_RUN" = 1 ]; then
		info "[dry-run] would run: claude --agent spec-observer -p → $output_file"
		commit_step "review" "external observer review" "$output_file"
		return 0
	fi

	info "running observer agent..."

	claude --agent spec-observer -p \
		--model "$MODEL" \
		--dangerously-skip-permissions \
		"Read the referee's consolidated output at $NEXT_DIR/merge.md.
Read the original proposals:
$proposal_refs

Write your observations to $output_file following the role instructions exactly." \
		2>&1 | tee "$log_file"

	[ -f "$output_file" ] \
		|| error "observer agent completed but output not found: $output_file"

	info "review complete: $output_file"

	commit_step "review" "external observer review" "$output_file"
}

# ── Step 6: Amends (serial) ──────────────────────────────────────────

run_amends() {
	step "Step 6: Amends (referee responds to review)"

	output_file="$NEXT_DIR/merge.amends.md"
	log_file="$LOG_DIR/amends.log"

	check_output "$output_file" "amends"
	require_input "$NEXT_DIR/merge.md" "merge"
	require_input "$NEXT_DIR/review.md" "review"

	if [ "$DRY_RUN" = 1 ]; then
		info "[dry-run] would run: claude --agent spec-amends -p → $output_file"
		commit_step "amends" "post-merge amendments" "$output_file"
		return 0
	fi

	info "running amends agent..."

	claude --agent spec-amends -p \
		--model "$MODEL" \
		--dangerously-skip-permissions \
		"Read your consolidated specification at $NEXT_DIR/merge.md.
Read the external observer's review at $NEXT_DIR/review.md.

Write the amendment record to $output_file following the role instructions exactly." \
		2>&1 | tee "$log_file"

	[ -f "$output_file" ] \
		|| error "amends agent completed but output not found: $output_file"

	info "amends complete: $output_file"

	commit_step "amends" "post-merge amendments" "$output_file"
}

# ── Step 7: Editor (serial) ──────────────────────────────────────────

run_editor() {
	step "Step 7: Editor (final publication → version-${NEXT_VERSION})"

	output_file="$NEXT_DIR/spec.md"
	log_file="$LOG_DIR/editor.log"

	check_output "$output_file" "version-${NEXT_VERSION}/spec.md"
	require_input "$NEXT_DIR/merge.md" "merge"
	require_input "$NEXT_DIR/merge.amends.md" "amends"
	require_input "$NEXT_DIR/review.md" "review"

	proposal_refs=""
	for id in $PROPOSAL_IDS; do
		require_input "$NEXT_DIR/proposal-${id}.md" "proposal-${id}"
		proposal_refs="$proposal_refs
- $NEXT_DIR/proposal-${id}.md"
	done

	if [ "$DRY_RUN" = 1 ]; then
		info "[dry-run] would run: claude --agent spec-editor -p → $output_file"
		commit_step "editor" "publish specification" "$output_file"
		return 0
	fi

	info "running editor agent..."

	claude --agent spec-editor -p \
		--model "$MODEL" \
		--dangerously-skip-permissions \
		"You have the complete document lineage:

Proposals:
$proposal_refs

Merge: $NEXT_DIR/merge.md
Review: $NEXT_DIR/review.md
Amendments: $NEXT_DIR/merge.amends.md
Baseline: $SPEC_BASELINE

Read all documents in the lineage.
Produce the final publication-ready specification.
The version number for this cycle is ${NEXT_VERSION}.0.0.
Write it to $output_file following the role instructions exactly." \
		2>&1 | tee "$log_file"

	[ -f "$output_file" ] \
		|| error "editor agent completed but output not found: $output_file"

	info "editor complete: $output_file"

	commit_step "editor" "publish specification" "$output_file"
}

# ── Step dispatcher ───────────────────────────────────────────────────

run_step() {
	case "$1" in
		issues)    run_issues ;;
		curate)    run_curate ;;
		proposals) run_proposals ;;
		merge)     run_merge ;;
		review)    run_review ;;
		amends)    run_amends ;;
		editor)    run_editor ;;
	esac
}

# ── Main ──────────────────────────────────────────────────────────────

preflight_common

info "baseline:      $SPEC_BASELINE"
info "backlog:       $BACKLOG_DIR/"
info "scope:         $CURRENT_DIR/{features,issues}.md"
info "output dir:    $NEXT_DIR/"
info "next version:  ${NEXT_VERSION}"
info "proposals:     $PROPOSAL_COUNT ($PROPOSAL_IDS)"
info "model:         $MODEL"
[ "$COMMIT" = 1 ] && info "commits:       enabled" || info "commits:       disabled"

case "$STEP" in
	all)
		start=0
		if [ -n "$FROM_STEP" ]; then
			start=$(step_index "$FROM_STEP")
			info "resuming from:  $FROM_STEP (step $((start + 1)))"
		fi
		_i=0
		for _s in $STEPS; do
			if [ "$_i" -ge "$start" ]; then
				run_step "$_s"
			fi
			_i=$((_i + 1))
		done
		step "Complete — specification published at $NEXT_DIR/spec.md"
		;;
	*)
		run_step "$STEP"
		;;
esac
