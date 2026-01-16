#!/bin/bash

# Ralph Status Monitor - Live terminal dashboard for the Ralph loop
set -e

STATUS_FILE="status.json"
LOG_FILE="logs/ralph.log"
REFRESH_INTERVAL=2

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Clear screen and hide cursor
clear_screen() {
    clear
    printf '\033[?25l'  # Hide cursor
}

# Show cursor on exit
show_cursor() {
    printf '\033[?25h'  # Show cursor
}

# Cleanup function
cleanup() {
    show_cursor
    echo
    echo "Monitor stopped."
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM EXIT

# Main display function
display_status() {
    clear_screen
    
    # Header
    echo -e "${WHITE}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                           🤖 RALPH MONITOR                              ║${NC}"
    echo -e "${WHITE}║                        Live Status Dashboard                           ║${NC}"
    echo -e "${WHITE}╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    # Status section
    if [[ -f "$STATUS_FILE" ]]; then
        # Parse JSON status
        local status_data=$(cat "$STATUS_FILE")
        local loop_count=$(echo "$status_data" | jq -r '.loop_count // "0"' 2>/dev/null || echo "0")
        local calls_made=$(echo "$status_data" | jq -r '.calls_made_this_hour // "0"' 2>/dev/null || echo "0")
        local max_calls=$(echo "$status_data" | jq -r '.max_calls_per_hour // "100"' 2>/dev/null || echo "100")
        local status=$(echo "$status_data" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        
        echo -e "${CYAN}┌─ Current Status ────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${NC} Loop Count:     ${WHITE}#$loop_count${NC}"
        echo -e "${CYAN}│${NC} Status:         ${GREEN}$status${NC}"
        echo -e "${CYAN}│${NC} API Calls:      $calls_made/$max_calls"
        echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo
        
    else
        echo -e "${RED}┌─ Status ────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}│${NC} Status file not found. Ralph may not be running."
        echo -e "${RED}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo
    fi
    
    # Claude Code Progress section
    if [[ -f "progress.json" ]]; then
        local progress_data=$(cat "progress.json" 2>/dev/null)
        local progress_status=$(echo "$progress_data" | jq -r '.status // "idle"' 2>/dev/null || echo "idle")
        
        if [[ "$progress_status" == "executing" ]]; then
            local indicator=$(echo "$progress_data" | jq -r '.indicator // "⠋"' 2>/dev/null || echo "⠋")
            local elapsed=$(echo "$progress_data" | jq -r '.elapsed_seconds // "0"' 2>/dev/null || echo "0")
            local last_output=$(echo "$progress_data" | jq -r '.last_output // ""' 2>/dev/null || echo "")
            
            echo -e "${YELLOW}┌─ Claude Code Progress ──────────────────────────────────────────────────┐${NC}"
            echo -e "${YELLOW}│${NC} Status:         ${indicator} Working (${elapsed}s elapsed)"
            if [[ -n "$last_output" && "$last_output" != "" ]]; then
                # Truncate long output for display
                local display_output=$(echo "$last_output" | head -c 60)
                echo -e "${YELLOW}│${NC} Output:         ${display_output}..."
            fi
            echo -e "${YELLOW}└─────────────────────────────────────────────────────────────────────────┘${NC}"
            echo
        fi
    fi

    # Evidence verification section
    if [[ -f ".ralph_evidence.json" ]]; then
        local gates_verified=$(jq -r '.overall_status.gates_verified // 0' .ralph_evidence.json 2>/dev/null)
        local gates_failed=$(jq -r '.overall_status.gates_failed // 0' .ralph_evidence.json 2>/dev/null)
        local gates_skipped=$(jq -r '.overall_status.gates_skipped // 0' .ralph_evidence.json 2>/dev/null)
        local exit_allowed=$(jq -r '.overall_status.exit_allowed // false' .ralph_evidence.json 2>/dev/null)
        local tests_status=$(jq -r '.verification_gates.tests_passed.status // "PENDING"' .ralph_evidence.json 2>/dev/null)
        local docs_status=$(jq -r '.verification_gates.documentation_exists.status // "PENDING"' .ralph_evidence.json 2>/dev/null)
        local files_status=$(jq -r '.verification_gates.files_modified.status // "PENDING"' .ralph_evidence.json 2>/dev/null)
        local commits_status=$(jq -r '.verification_gates.commits_made.status // "PENDING"' .ralph_evidence.json 2>/dev/null)

        echo -e "${PURPLE}┌─ Evidence Verification ─────────────────────────────────────────────────┐${NC}"
        echo -e "${PURPLE}│${NC} Gates: ${GREEN}$gates_verified verified${NC}, ${RED}$gates_failed failed${NC}, ${YELLOW}$gates_skipped skipped${NC}"

        # Format gate statuses with colors
        local tests_color=$([[ "$tests_status" == "VERIFIED" ]] && echo "$GREEN" || ([[ "$tests_status" == "FAILED" ]] && echo "$RED" || echo "$YELLOW"))
        local docs_color=$([[ "$docs_status" == "VERIFIED" ]] && echo "$GREEN" || ([[ "$docs_status" == "FAILED" ]] && echo "$RED" || echo "$YELLOW"))
        local files_color=$([[ "$files_status" == "VERIFIED" ]] && echo "$GREEN" || ([[ "$files_status" == "FAILED" ]] && echo "$RED" || echo "$YELLOW"))
        local commits_color=$([[ "$commits_status" == "VERIFIED" ]] && echo "$GREEN" || ([[ "$commits_status" == "FAILED" ]] && echo "$RED" || echo "$YELLOW"))

        echo -e "${PURPLE}│${NC} Tests: ${tests_color}$tests_status${NC}  Docs: ${docs_color}$docs_status${NC}  Files: ${files_color}$files_status${NC}  Commits: ${commits_color}$commits_status${NC}"

        if [[ "$exit_allowed" == "true" ]]; then
            echo -e "${PURPLE}│${NC} Exit Allowed: ${GREEN}YES${NC}"
        else
            echo -e "${PURPLE}│${NC} Exit Allowed: ${RED}NO${NC}"
        fi
        echo -e "${PURPLE}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo
    fi

    # Recent logs
    echo -e "${BLUE}┌─ Recent Activity ───────────────────────────────────────────────────────┐${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 8 "$LOG_FILE" | while IFS= read -r line; do
            echo -e "${BLUE}│${NC} $line"
        done
    else
        echo -e "${BLUE}│${NC} No log file found"
    fi
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────────────────┘${NC}"
    
    # Footer
    echo
    echo -e "${YELLOW}Controls: Ctrl+C to exit | Refreshes every ${REFRESH_INTERVAL}s | $(date '+%H:%M:%S')${NC}"
}

# Main monitor loop
main() {
    echo "Starting Ralph Monitor..."
    sleep 2
    
    while true; do
        display_status
        sleep "$REFRESH_INTERVAL"
    done
}

main
