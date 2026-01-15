#!/bin/bash
# Evidence Collector Component for Ralph
# Verifies completion artifacts before allowing EXIT_SIGNAL=true to trigger exit
# Based on lessons learned from Driftwarden project

# Source date utilities for cross-platform compatibility
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Evidence Collector Configuration
EVIDENCE_FILE=".ralph_evidence.json"
EVIDENCE_SCHEMA_VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Verification Gate Statuses
GATE_VERIFIED="VERIFIED"
GATE_FAILED="FAILED"
GATE_SKIPPED="SKIPPED"
GATE_PENDING="PENDING"

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize evidence file for a new session
# Usage: init_evidence_collector [session_id]
init_evidence_collector() {
    local session_id=${1:-""}

    # If no session ID provided, try to get from .ralph_session
    if [[ -z "$session_id" && -f ".ralph_session" ]]; then
        session_id=$(jq -r '.session_id // ""' ".ralph_session" 2>/dev/null)
    fi

    # Generate session ID if still empty
    if [[ -z "$session_id" ]]; then
        session_id="ralph-$(get_epoch_seconds)-$$"
    fi

    # Check if evidence file exists and is valid JSON
    if [[ -f "$EVIDENCE_FILE" ]]; then
        if ! jq '.' "$EVIDENCE_FILE" > /dev/null 2>&1; then
            # Corrupted, recreate
            rm -f "$EVIDENCE_FILE"
        fi
    fi

    if [[ ! -f "$EVIDENCE_FILE" ]]; then
        jq -n \
            --arg schema_version "$EVIDENCE_SCHEMA_VERSION" \
            --arg session_id "$session_id" \
            --arg created_at "$(get_iso_timestamp)" \
            --arg last_updated "$(get_iso_timestamp)" \
            --argjson loop_number 0 \
            '{
                schema_version: $schema_version,
                session_id: $session_id,
                created_at: $created_at,
                last_updated: $last_updated,
                loop_number: $loop_number,
                verification_gates: {
                    tests_passed: { status: "PENDING", verified_at: null, evidence: {} },
                    documentation_exists: { status: "PENDING", verified_at: null, evidence: {} },
                    cli_functional: { status: "PENDING", verified_at: null, evidence: {} },
                    files_modified: { status: "PENDING", verified_at: null, evidence: {} },
                    commits_made: { status: "PENDING", verified_at: null, evidence: {} },
                    fix_plan_complete: { status: "PENDING", verified_at: null, evidence: {} }
                },
                overall_status: {
                    all_gates_passed: false,
                    gates_verified: 0,
                    gates_failed: 0,
                    gates_skipped: 0,
                    exit_allowed: false
                },
                history: []
            }' > "$EVIDENCE_FILE"
    fi
}

# =============================================================================
# VERIFICATION GATES
# =============================================================================

# Verify test results - detects test command and captures results
# Usage: verify_tests [test_command]
# Returns: 0 if tests pass, 1 if fail or no test command found
verify_tests() {
    local test_command=${1:-""}
    local status="$GATE_FAILED"
    local exit_code=1
    local total_tests=0
    local passed=0
    local failed=0
    local output_summary=""
    local log_file=""

    init_evidence_collector

    # Auto-detect test command if not provided
    if [[ -z "$test_command" ]]; then
        if [[ -f "package.json" ]]; then
            # Check for both bun.lockb (legacy binary) and bun.lock (v1.1+ text format)
            if command -v bun &>/dev/null && [[ -f "bun.lockb" || -f "bun.lock" ]]; then
                test_command="bun test"
            elif command -v npm &>/dev/null; then
                test_command="npm test"
            fi
        elif [[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]]; then
            test_command="pytest"
        elif [[ -f "Cargo.toml" ]]; then
            test_command="cargo test"
        elif [[ -f "go.mod" ]]; then
            test_command="go test ./..."
        fi
    fi

    # If still no test command, mark as skipped
    if [[ -z "$test_command" ]]; then
        status="$GATE_SKIPPED"
        output_summary="No test framework detected"
    else
        # Create log file for test output
        local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
        log_file="logs/test_output_${timestamp}.log"
        mkdir -p logs

        # Run tests and capture output
        if $test_command > "$log_file" 2>&1; then
            exit_code=0
            status="$GATE_VERIFIED"
        else
            exit_code=$?
            status="$GATE_FAILED"
        fi

        # Parse test output for counts (best effort)
        if [[ -f "$log_file" ]]; then
            # Try to extract test counts from common formats
            # bats: "X tests, Y failures"
            # jest/npm: "X passed, Y failed"
            # pytest: "X passed, Y failed"
            local test_output=$(cat "$log_file")

            # Generic parsing - look for numbers near "pass" or "fail"
            passed=$(echo "$test_output" | grep -oE '[0-9]+ (pass|passing)' | grep -oE '[0-9]+' | head -1 || echo "0")
            failed=$(echo "$test_output" | grep -oE '[0-9]+ (fail|failing|failures?)' | grep -oE '[0-9]+' | head -1 || echo "0")

            passed=${passed:-0}
            failed=${failed:-0}
            total_tests=$((passed + failed))

            if [[ $total_tests -eq 0 && $exit_code -eq 0 ]]; then
                output_summary="Tests passed (no count extracted)"
            elif [[ $exit_code -eq 0 ]]; then
                output_summary="$passed passing (100% pass rate)"
            else
                output_summary="$passed passed, $failed failed"
            fi
        fi
    fi

    # Update evidence file
    local evidence=$(cat "$EVIDENCE_FILE")
    evidence=$(echo "$evidence" | jq \
        --arg status "$status" \
        --arg verified_at "$(get_iso_timestamp)" \
        --arg test_command "$test_command" \
        --argjson exit_code "$exit_code" \
        --argjson total_tests "$total_tests" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --arg output_summary "$output_summary" \
        --arg log_file "$log_file" \
        '.verification_gates.tests_passed = {
            status: $status,
            verified_at: $verified_at,
            evidence: {
                test_command: $test_command,
                exit_code: $exit_code,
                total_tests: $total_tests,
                passed: $passed,
                failed: $failed,
                output_summary: $output_summary,
                log_file: $log_file
            }
        } | .last_updated = $verified_at')

    echo "$evidence" > "$EVIDENCE_FILE"

    if [[ "$status" == "$GATE_VERIFIED" || "$status" == "$GATE_SKIPPED" ]]; then
        return 0
    else
        return 1
    fi
}

# Verify documentation exists
# Usage: verify_documentation [docs_dir]
# Returns: 0 if docs exist, 1 if missing
verify_documentation() {
    local docs_dir=${1:-"docs/generated"}
    local status="$GATE_FAILED"
    local docs_count=0
    local files=()
    local readme_updated=false
    local readme_mtime=""

    init_evidence_collector

    # Check docs directory
    if [[ -d "$docs_dir" ]]; then
        # Count files in docs directory
        while IFS= read -r -d '' file; do
            files+=("$file")
            docs_count=$((docs_count + 1))
        done < <(find "$docs_dir" -type f -name "*.md" -print0 2>/dev/null)
    fi

    # Check README.md
    if [[ -f "README.md" ]]; then
        readme_mtime=$(stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%S" "README.md" 2>/dev/null || \
                       stat -c "%y" "README.md" 2>/dev/null | cut -d'.' -f1 || \
                       echo "unknown")

        # Check if README was modified recently (within last 24 hours)
        local readme_epoch
        if [[ "$OSTYPE" == "darwin"* ]]; then
            readme_epoch=$(stat -f "%m" "README.md" 2>/dev/null)
        else
            readme_epoch=$(stat -c "%Y" "README.md" 2>/dev/null)
        fi

        if [[ -n "$readme_epoch" ]]; then
            local now=$(get_epoch_seconds)
            local age=$((now - readme_epoch))
            if [[ $age -lt 86400 ]]; then
                readme_updated=true
            fi
        fi
    fi

    # Determine status - docs dir OR readme updated counts as verified
    if [[ $docs_count -gt 0 ]] || [[ "$readme_updated" == "true" ]]; then
        status="$GATE_VERIFIED"
    fi

    # Convert files array to JSON array
    local files_json="[]"
    for file in "${files[@]}"; do
        files_json=$(echo "$files_json" | jq --arg f "$file" '. += [$f]')
    done

    # Update evidence file
    local evidence=$(cat "$EVIDENCE_FILE")
    evidence=$(echo "$evidence" | jq \
        --arg status "$status" \
        --arg verified_at "$(get_iso_timestamp)" \
        --argjson docs_count "$docs_count" \
        --argjson files "$files_json" \
        --argjson readme_updated "$readme_updated" \
        --arg readme_mtime "$readme_mtime" \
        '.verification_gates.documentation_exists = {
            status: $status,
            verified_at: $verified_at,
            evidence: {
                docs_generated_count: $docs_count,
                files: $files,
                readme_updated: $readme_updated,
                readme_mtime: $readme_mtime
            }
        } | .last_updated = $verified_at')

    echo "$evidence" > "$EVIDENCE_FILE"

    if [[ "$status" == "$GATE_VERIFIED" ]]; then
        return 0
    else
        return 1
    fi
}

# Verify CLI functionality
# Usage: verify_cli [cli_command]
# Returns: 0 if CLI works, 1 if broken
verify_cli() {
    local cli_command=${1:-""}
    local status="$GATE_SKIPPED"
    local help_exit_code=-1

    init_evidence_collector

    # Auto-detect CLI command if not provided
    if [[ -z "$cli_command" ]]; then
        if [[ -f "package.json" ]]; then
            # Check for bin entry in package.json
            local bin_name=$(jq -r '.bin | if type == "object" then keys[0] else empty end // .name // empty' package.json 2>/dev/null)
            if [[ -n "$bin_name" && -f "node_modules/.bin/$bin_name" ]]; then
                cli_command="node_modules/.bin/$bin_name"
            elif [[ -f "src/cli.js" ]]; then
                if command -v bun &>/dev/null; then
                    cli_command="bun src/cli.js"
                else
                    cli_command="node src/cli.js"
                fi
            fi
        fi
    fi

    # If still no CLI command, mark as skipped
    if [[ -z "$cli_command" ]]; then
        status="$GATE_SKIPPED"
    else
        # Try running --help
        if $cli_command --help > /dev/null 2>&1; then
            help_exit_code=0
            status="$GATE_VERIFIED"
        else
            help_exit_code=$?
            status="$GATE_FAILED"
        fi
    fi

    # Update evidence file
    local evidence=$(cat "$EVIDENCE_FILE")
    evidence=$(echo "$evidence" | jq \
        --arg status "$status" \
        --arg verified_at "$(get_iso_timestamp)" \
        --arg cli_command "$cli_command" \
        --argjson help_exit_code "$help_exit_code" \
        '.verification_gates.cli_functional = {
            status: $status,
            verified_at: $verified_at,
            evidence: {
                help_command: (if $cli_command != "" then ($cli_command + " --help") else null end),
                help_exit_code: $help_exit_code
            }
        } | .last_updated = $verified_at')

    echo "$evidence" > "$EVIDENCE_FILE"

    if [[ "$status" == "$GATE_VERIFIED" || "$status" == "$GATE_SKIPPED" ]]; then
        return 0
    else
        return 1
    fi
}

# Verify file modifications via git
# Usage: verify_file_changes
# Returns: 0 if changes made, 1 if no changes
verify_file_changes() {
    local status="$GATE_FAILED"
    local total_files=0
    local files=()
    local diff_stat=""

    init_evidence_collector

    # Check if we're in a git repo
    if ! command -v git &>/dev/null || ! git rev-parse --git-dir > /dev/null 2>&1; then
        status="$GATE_SKIPPED"
    else
        # Get changed files (both staged and unstaged)
        # Try HEAD first, then fall back to checking staged files directly
        local changed_files=""
        changed_files=$(git diff --name-only HEAD 2>/dev/null) || \
        changed_files=$(git diff --name-only 2>/dev/null) || \
        changed_files=$(git diff --cached --name-only 2>/dev/null)

        if [[ -n "$changed_files" ]]; then
            while IFS= read -r file; do
                if [[ -n "$file" ]]; then
                    files+=("$file")
                    total_files=$((total_files + 1))
                fi
            done <<< "$changed_files"
        fi

        # Get diff stat
        diff_stat=$(git diff --stat HEAD 2>/dev/null | tail -1 || git diff --cached --stat 2>/dev/null | tail -1 || echo "")

        if [[ $total_files -gt 0 ]]; then
            status="$GATE_VERIFIED"
        fi
    fi

    # Convert files array to JSON array
    local files_json="[]"
    for file in "${files[@]}"; do
        files_json=$(echo "$files_json" | jq --arg f "$file" '. += [$f]')
    done

    # Update evidence file
    local evidence=$(cat "$EVIDENCE_FILE")
    evidence=$(echo "$evidence" | jq \
        --arg status "$status" \
        --arg verified_at "$(get_iso_timestamp)" \
        --argjson total_files "$total_files" \
        --argjson files "$files_json" \
        --arg diff_stat "$diff_stat" \
        '.verification_gates.files_modified = {
            status: $status,
            verified_at: $verified_at,
            evidence: {
                total_files_changed: $total_files,
                session_files: $files,
                git_diff_stat: $diff_stat
            }
        } | .last_updated = $verified_at')

    echo "$evidence" > "$EVIDENCE_FILE"

    if [[ "$status" == "$GATE_VERIFIED" ]]; then
        return 0
    else
        return 1
    fi
}

# Verify commits were made
# Usage: verify_commits [since_timestamp]
# Returns: 0 if commits exist, 1 if none
verify_commits() {
    local since_timestamp=${1:-""}
    local status="$GATE_FAILED"
    local commit_count=0
    local commits=()
    local pushed_to_remote=false

    init_evidence_collector

    # Check if we're in a git repo
    if ! command -v git &>/dev/null || ! git rev-parse --git-dir > /dev/null 2>&1; then
        status="$GATE_SKIPPED"
    else
        # If no timestamp provided, use session start time from evidence file
        if [[ -z "$since_timestamp" && -f "$EVIDENCE_FILE" ]]; then
            since_timestamp=$(jq -r '.created_at // ""' "$EVIDENCE_FILE" 2>/dev/null)
        fi

        # Get recent commits
        local git_log_args="--oneline -10"
        if [[ -n "$since_timestamp" ]]; then
            git_log_args="--oneline --since=\"$since_timestamp\""
        fi

        local commit_log=$(git log $git_log_args 2>/dev/null || git log --oneline -10 2>/dev/null)

        if [[ -n "$commit_log" ]]; then
            while IFS= read -r line; do
                if [[ -n "$line" ]]; then
                    local hash=$(echo "$line" | cut -d' ' -f1)
                    local message=$(echo "$line" | cut -d' ' -f2-)
                    commits+=("{\"hash\": \"$hash\", \"message\": \"$message\"}")
                    commit_count=$((commit_count + 1))
                fi
            done <<< "$commit_log"
        fi

        # Check if pushed to remote
        local upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)
        if [[ -n "$upstream" ]]; then
            local local_hash=$(git rev-parse HEAD 2>/dev/null)
            local remote_hash=$(git rev-parse "$upstream" 2>/dev/null)
            if [[ "$local_hash" == "$remote_hash" ]]; then
                pushed_to_remote=true
            fi
        fi

        if [[ $commit_count -gt 0 ]]; then
            status="$GATE_VERIFIED"
        fi
    fi

    # Build commits JSON array
    local commits_json="[]"
    for commit in "${commits[@]}"; do
        commits_json=$(echo "$commits_json" | jq ". += [$commit]")
    done

    # Update evidence file
    local evidence=$(cat "$EVIDENCE_FILE")
    evidence=$(echo "$evidence" | jq \
        --arg status "$status" \
        --arg verified_at "$(get_iso_timestamp)" \
        --argjson commit_count "$commit_count" \
        --argjson commits "$commits_json" \
        --argjson pushed_to_remote "$pushed_to_remote" \
        '.verification_gates.commits_made = {
            status: $status,
            verified_at: $verified_at,
            evidence: {
                commit_count: $commit_count,
                commits: $commits,
                pushed_to_remote: $pushed_to_remote
            }
        } | .last_updated = $verified_at')

    echo "$evidence" > "$EVIDENCE_FILE"

    if [[ "$status" == "$GATE_VERIFIED" ]]; then
        return 0
    else
        return 1
    fi
}

# Verify @fix_plan.md completion
# Usage: verify_fix_plan [fix_plan_file]
# Returns: 0 if all complete, 1 if incomplete
verify_fix_plan() {
    local fix_plan_file=${1:-"@fix_plan.md"}
    local status="$GATE_FAILED"
    local total_items=0
    local completed_items=0
    local completion_percentage=0
    local uncompleted=()

    init_evidence_collector

    if [[ ! -f "$fix_plan_file" ]]; then
        status="$GATE_SKIPPED"
    else
        # Count checkbox items
        total_items=$(grep -c "^- \[" "$fix_plan_file" 2>/dev/null || echo "0")
        completed_items=$(grep -c "^- \[x\]" "$fix_plan_file" 2>/dev/null || echo "0")

        # Ensure integers
        total_items=$((total_items + 0))
        completed_items=$((completed_items + 0))

        # Calculate percentage
        if [[ $total_items -gt 0 ]]; then
            completion_percentage=$((completed_items * 100 / total_items))
        fi

        # Get uncompleted items
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                uncompleted+=("$line")
            fi
        done < <(grep "^- \[ \]" "$fix_plan_file" 2>/dev/null | sed 's/^- \[ \] //')

        # Determine status
        if [[ $total_items -gt 0 && $completed_items -eq $total_items ]]; then
            status="$GATE_VERIFIED"
        elif [[ $total_items -eq 0 ]]; then
            status="$GATE_SKIPPED"
        fi
    fi

    # Build uncompleted JSON array
    local uncompleted_json="[]"
    for item in "${uncompleted[@]}"; do
        uncompleted_json=$(echo "$uncompleted_json" | jq --arg i "$item" '. += [$i]')
    done

    # Update evidence file
    local evidence=$(cat "$EVIDENCE_FILE")
    evidence=$(echo "$evidence" | jq \
        --arg status "$status" \
        --arg verified_at "$(get_iso_timestamp)" \
        --argjson total_items "$total_items" \
        --argjson completed_items "$completed_items" \
        --argjson completion_percentage "$completion_percentage" \
        --argjson uncompleted "$uncompleted_json" \
        '.verification_gates.fix_plan_complete = {
            status: $status,
            verified_at: $verified_at,
            evidence: {
                total_items: $total_items,
                completed_items: $completed_items,
                completion_percentage: $completion_percentage,
                uncompleted_items: $uncompleted
            }
        } | .last_updated = $verified_at')

    echo "$evidence" > "$EVIDENCE_FILE"

    if [[ "$status" == "$GATE_VERIFIED" ]]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# COMPOSITE VERIFICATION
# =============================================================================

# Helper function to safely update overall status
# Ensures status.json is always updated, even on error
# Usage: _update_overall_status gates_verified gates_failed gates_skipped
_update_overall_status() {
    local gates_verified=${1:-0}
    local gates_failed=${2:-0}
    local gates_skipped=${3:-0}

    local all_gates_passed=false
    local exit_allowed=false

    # All gates pass if no failures (skipped gates are OK)
    if [[ $gates_failed -eq 0 ]]; then
        all_gates_passed=true
        exit_allowed=true
    fi

    # Ensure evidence file exists before updating
    if [[ ! -f "$EVIDENCE_FILE" ]]; then
        init_evidence_collector
    fi

    local evidence=$(cat "$EVIDENCE_FILE" 2>/dev/null || echo '{}')
    evidence=$(echo "$evidence" | jq \
        --argjson all_gates_passed "$all_gates_passed" \
        --argjson gates_verified "$gates_verified" \
        --argjson gates_failed "$gates_failed" \
        --argjson gates_skipped "$gates_skipped" \
        --argjson exit_allowed "$exit_allowed" \
        --arg last_updated "$(get_iso_timestamp)" \
        '.overall_status = {
            all_gates_passed: $all_gates_passed,
            gates_verified: $gates_verified,
            gates_failed: $gates_failed,
            gates_skipped: $gates_skipped,
            exit_allowed: $exit_allowed
        } | .last_updated = $last_updated' 2>/dev/null || echo "$evidence")

    echo "$evidence" > "$EVIDENCE_FILE" 2>/dev/null || true
}

# Helper to run a verification gate with error protection
# Usage: _run_gate_safely gate_name gate_function [skip_flag]
# Returns: 0 if verified/skipped, 1 if failed
_run_gate_safely() {
    local gate_name=$1
    local gate_function=$2
    local skip_flag=${3:-false}
    local status_field=$4

    if [[ "$skip_flag" == "true" ]]; then
        return 2  # Skipped
    fi

    # Run gate in subshell to protect against set -e side effects
    local gate_result=0
    (
        set +e  # Disable exit on error within subshell
        $gate_function
    ) && gate_result=0 || gate_result=$?

    # Check result and return appropriate code
    if [[ $gate_result -eq 0 ]]; then
        return 0  # Verified
    else
        # Check if gate marked itself as skipped
        local gate_status=$(jq -r ".verification_gates.$status_field.status // \"FAILED\"" "$EVIDENCE_FILE" 2>/dev/null)
        if [[ "$gate_status" == "$GATE_SKIPPED" ]]; then
            return 2  # Skipped
        fi
        return 1  # Failed
    fi
}

# Run all verification gates
# Usage: run_all_verifications [options]
# Returns: 0 if all required gates pass, 1 if any fail
run_all_verifications() {
    local skip_tests=${SKIP_TEST_VERIFICATION:-false}
    local skip_cli=${SKIP_CLI_VERIFICATION:-false}

    init_evidence_collector

    # Use safe arithmetic (avoid ((var++)) which returns 1 when incrementing from 0)
    local gates_verified=0
    local gates_failed=0
    local gates_skipped=0

    # Trap to ensure overall status is always updated, even on error
    trap '_update_overall_status "$gates_verified" "$gates_failed" "$gates_skipped"' EXIT

    echo -e "${BLUE}Running evidence verification gates...${NC}"

    # 1. Tests (can be skipped)
    echo -n "  Tests: "
    if [[ "$skip_tests" == "true" ]]; then
        echo -e "${YELLOW}SKIPPED${NC} (flag)"
        gates_skipped=$((gates_skipped + 1))
    else
        # Run in subshell for error protection
        local test_result=0
        (set +e; verify_tests) && test_result=0 || test_result=$?

        if [[ $test_result -eq 0 ]]; then
            echo -e "${GREEN}VERIFIED${NC}"
            gates_verified=$((gates_verified + 1))
        else
            local test_status=$(jq -r '.verification_gates.tests_passed.status // "FAILED"' "$EVIDENCE_FILE" 2>/dev/null)
            if [[ "$test_status" == "$GATE_SKIPPED" ]]; then
                echo -e "${YELLOW}SKIPPED${NC}"
                gates_skipped=$((gates_skipped + 1))
            else
                echo -e "${RED}FAILED${NC}"
                gates_failed=$((gates_failed + 1))
            fi
        fi
    fi

    # 2. Documentation
    echo -n "  Documentation: "
    local doc_result=0
    (set +e; verify_documentation) && doc_result=0 || doc_result=$?

    if [[ $doc_result -eq 0 ]]; then
        echo -e "${GREEN}VERIFIED${NC}"
        gates_verified=$((gates_verified + 1))
    else
        local doc_status=$(jq -r '.verification_gates.documentation_exists.status // "FAILED"' "$EVIDENCE_FILE" 2>/dev/null)
        if [[ "$doc_status" == "$GATE_SKIPPED" ]]; then
            echo -e "${YELLOW}SKIPPED${NC}"
            gates_skipped=$((gates_skipped + 1))
        else
            echo -e "${RED}FAILED${NC}"
            gates_failed=$((gates_failed + 1))
        fi
    fi

    # 3. CLI (can be skipped)
    echo -n "  CLI Functional: "
    if [[ "$skip_cli" == "true" ]]; then
        echo -e "${YELLOW}SKIPPED${NC} (flag)"
        gates_skipped=$((gates_skipped + 1))
    else
        local cli_result=0
        (set +e; verify_cli) && cli_result=0 || cli_result=$?

        if [[ $cli_result -eq 0 ]]; then
            echo -e "${GREEN}VERIFIED${NC}"
            gates_verified=$((gates_verified + 1))
        else
            local cli_status=$(jq -r '.verification_gates.cli_functional.status // "FAILED"' "$EVIDENCE_FILE" 2>/dev/null)
            if [[ "$cli_status" == "$GATE_SKIPPED" ]]; then
                echo -e "${YELLOW}SKIPPED${NC}"
                gates_skipped=$((gates_skipped + 1))
            else
                echo -e "${RED}FAILED${NC}"
                gates_failed=$((gates_failed + 1))
            fi
        fi
    fi

    # 4. File Changes
    echo -n "  Files Modified: "
    local files_result=0
    (set +e; verify_file_changes) && files_result=0 || files_result=$?

    if [[ $files_result -eq 0 ]]; then
        echo -e "${GREEN}VERIFIED${NC}"
        gates_verified=$((gates_verified + 1))
    else
        echo -e "${RED}FAILED${NC}"
        gates_failed=$((gates_failed + 1))
    fi

    # 5. Commits Made
    echo -n "  Commits Made: "
    local commits_result=0
    (set +e; verify_commits) && commits_result=0 || commits_result=$?

    if [[ $commits_result -eq 0 ]]; then
        echo -e "${GREEN}VERIFIED${NC}"
        gates_verified=$((gates_verified + 1))
    else
        echo -e "${RED}FAILED${NC}"
        gates_failed=$((gates_failed + 1))
    fi

    # 6. Fix Plan Complete
    echo -n "  Fix Plan: "
    local plan_result=0
    (set +e; verify_fix_plan) && plan_result=0 || plan_result=$?

    if [[ $plan_result -eq 0 ]]; then
        echo -e "${GREEN}VERIFIED${NC}"
        gates_verified=$((gates_verified + 1))
    else
        local plan_status=$(jq -r '.verification_gates.fix_plan_complete.status // "FAILED"' "$EVIDENCE_FILE" 2>/dev/null)
        if [[ "$plan_status" == "$GATE_SKIPPED" ]]; then
            echo -e "${YELLOW}SKIPPED${NC}"
            gates_skipped=$((gates_skipped + 1))
        else
            echo -e "${RED}FAILED${NC}"
            gates_failed=$((gates_failed + 1))
        fi
    fi

    # Update overall status (also called by trap on exit)
    _update_overall_status "$gates_verified" "$gates_failed" "$gates_skipped"

    # Clear trap since we updated manually
    trap - EXIT

    echo ""
    echo -e "${BLUE}Summary:${NC} $gates_verified verified, $gates_failed failed, $gates_skipped skipped"

    local exit_allowed=$(jq -r '.overall_status.exit_allowed // false' "$EVIDENCE_FILE" 2>/dev/null)
    if [[ "$exit_allowed" == "true" ]]; then
        echo -e "${GREEN}Exit allowed: YES${NC}"
        return 0
    else
        echo -e "${RED}Exit allowed: NO${NC}"
        return 1
    fi
}

# Check if exit is allowed based on evidence
# Usage: is_exit_allowed
# Returns: 0 if allowed, 1 if not
is_exit_allowed() {
    if [[ ! -f "$EVIDENCE_FILE" ]]; then
        return 1
    fi

    local exit_allowed=$(jq -r '.overall_status.exit_allowed // false' "$EVIDENCE_FILE" 2>/dev/null)

    if [[ "$exit_allowed" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# DISPLAY FUNCTIONS
# =============================================================================

# Get evidence summary for logging
# Usage: get_evidence_summary
# Returns: Human-readable summary string
get_evidence_summary() {
    if [[ ! -f "$EVIDENCE_FILE" ]]; then
        echo "No evidence file found"
        return 1
    fi

    local gates_verified=$(jq -r '.overall_status.gates_verified // 0' "$EVIDENCE_FILE" 2>/dev/null)
    local gates_failed=$(jq -r '.overall_status.gates_failed // 0' "$EVIDENCE_FILE" 2>/dev/null)
    local gates_skipped=$(jq -r '.overall_status.gates_skipped // 0' "$EVIDENCE_FILE" 2>/dev/null)
    local exit_allowed=$(jq -r '.overall_status.exit_allowed // false' "$EVIDENCE_FILE" 2>/dev/null)

    # Get individual gate summaries
    local tests_status=$(jq -r '.verification_gates.tests_passed.status // "PENDING"' "$EVIDENCE_FILE" 2>/dev/null)
    local tests_summary=$(jq -r '.verification_gates.tests_passed.evidence.output_summary // ""' "$EVIDENCE_FILE" 2>/dev/null)
    local docs_count=$(jq -r '.verification_gates.documentation_exists.evidence.docs_generated_count // 0' "$EVIDENCE_FILE" 2>/dev/null)
    local commits_count=$(jq -r '.verification_gates.commits_made.evidence.commit_count // 0' "$EVIDENCE_FILE" 2>/dev/null)
    local files_count=$(jq -r '.verification_gates.files_modified.evidence.total_files_changed // 0' "$EVIDENCE_FILE" 2>/dev/null)

    echo "Tests=$tests_summary, Docs=$docs_count, Commits=$commits_count, Files=$files_count"
}

# Display evidence status
# Usage: show_evidence_status
show_evidence_status() {
    if [[ ! -f "$EVIDENCE_FILE" ]]; then
        echo -e "${YELLOW}No evidence file found. Run --verify-evidence to create one.${NC}"
        return 1
    fi

    local session_id=$(jq -r '.session_id // "unknown"' "$EVIDENCE_FILE" 2>/dev/null)
    local created_at=$(jq -r '.created_at // "unknown"' "$EVIDENCE_FILE" 2>/dev/null)
    local last_updated=$(jq -r '.last_updated // "unknown"' "$EVIDENCE_FILE" 2>/dev/null)

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              Evidence Verification Status                  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Session:${NC}         $session_id"
    echo -e "${YELLOW}Created:${NC}         $created_at"
    echo -e "${YELLOW}Last Updated:${NC}    $last_updated"
    echo ""

    # Display each gate
    local gates=("tests_passed" "documentation_exists" "cli_functional" "files_modified" "commits_made" "fix_plan_complete")
    local gate_names=("Tests Passed" "Documentation" "CLI Functional" "Files Modified" "Commits Made" "Fix Plan Complete")

    for i in "${!gates[@]}"; do
        local gate="${gates[$i]}"
        local name="${gate_names[$i]}"
        local status=$(jq -r ".verification_gates.$gate.status // \"PENDING\"" "$EVIDENCE_FILE" 2>/dev/null)

        local color=""
        local icon=""
        case $status in
            "$GATE_VERIFIED")
                color=$GREEN
                icon="✓"
                ;;
            "$GATE_FAILED")
                color=$RED
                icon="✗"
                ;;
            "$GATE_SKIPPED")
                color=$YELLOW
                icon="○"
                ;;
            *)
                color=$NC
                icon="?"
                ;;
        esac

        printf "  ${color}%s${NC} %-20s ${color}%s${NC}\n" "$icon" "$name:" "$status"
    done

    echo ""

    # Overall status
    local exit_allowed=$(jq -r '.overall_status.exit_allowed // false' "$EVIDENCE_FILE" 2>/dev/null)
    if [[ "$exit_allowed" == "true" ]]; then
        echo -e "${GREEN}Exit Allowed: YES${NC}"
    else
        echo -e "${RED}Exit Allowed: NO${NC}"
    fi
    echo ""
}

# Log evidence failures for debugging
# Usage: log_evidence_failures
log_evidence_failures() {
    if [[ ! -f "$EVIDENCE_FILE" ]]; then
        return 1
    fi

    echo -e "${RED}Evidence verification failures:${NC}"

    local gates=("tests_passed" "documentation_exists" "cli_functional" "files_modified" "commits_made" "fix_plan_complete")

    for gate in "${gates[@]}"; do
        local status=$(jq -r ".verification_gates.$gate.status // \"PENDING\"" "$EVIDENCE_FILE" 2>/dev/null)
        if [[ "$status" == "$GATE_FAILED" ]]; then
            echo -e "  ${RED}• $gate: FAILED${NC}"
            # Show relevant evidence
            case $gate in
                "tests_passed")
                    local summary=$(jq -r '.verification_gates.tests_passed.evidence.output_summary // ""' "$EVIDENCE_FILE" 2>/dev/null)
                    echo "    $summary"
                    ;;
                "fix_plan_complete")
                    local uncompleted=$(jq -r '.verification_gates.fix_plan_complete.evidence.uncompleted_items | join(", ")' "$EVIDENCE_FILE" 2>/dev/null)
                    echo "    Uncompleted: $uncompleted"
                    ;;
            esac
        fi
    done
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f init_evidence_collector
export -f verify_tests
export -f verify_documentation
export -f verify_cli
export -f verify_file_changes
export -f verify_commits
export -f verify_fix_plan
export -f run_all_verifications
export -f is_exit_allowed
export -f get_evidence_summary
export -f show_evidence_status
export -f log_evidence_failures
