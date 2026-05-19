#!/bin/zsh

function select_db() {
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

        echo "Selected: ${labels[$selected_index]} ($selected_db)"
        
        # set CUSTOM_ENV in the system
        # set DB_NAME 
        # Stop all docker containers
        # stop django
        # Restart them maybe?
    else
        echo "No database selected"
    fi
}

# Execute the function
select_db 