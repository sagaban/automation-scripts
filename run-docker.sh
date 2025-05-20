#!/bin/zsh

function run-docker() {
    # Define arrays for labels and values
    local labels=(
        "Main Database"
        "Development Database"
        "PRS Database"
        "Hotfix Database"
        "Fede's Database"
        "Production Database"
        "Testing Database"
    )
    local values=(
        ""
        "_dev"
        "_prs"
        "_hotfix"
        "_fede"
        "_prod"
        "_testing"
    )
    
    # Get the selected index using fzf
    local selected_index=$(printf '%s\n' "${labels[@]}" | nl | fzf --height 33% --reverse --border | awk '{print $1}')
    
    if [ -n "$selected_index" ]; then
        # Get the corresponding value from the values array
        local selected_db=${values[$selected_index]}
        echo "Selected: ${labels[$selected_index]} ($selected_db)"
        zellij action rename-pane "${labels[$selected_index]} (concntric_db$selected_db)"
        CUSTOM_ENV=$selected_db WORKING_DIR=$(pwd) COMPOSE_PROFILES=backend GIT_HASH=$(git rev-parse --short HEAD) GIT_LONG_HASH=$(git rev-parse HEAD) docker compose up database mailhog localstack auth --build 
    else
        echo "No database selected"
    fi
}

# Execute the function
run-backend 