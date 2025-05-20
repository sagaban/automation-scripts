#!/bin/zsh

function run-django() {
    # Check if pyenv is activated
    if ! command -v pyenv &> /dev/null; then
        echo "Error: pyenv is not installed or not in PATH"
        return 1
    fi

    # Verify Python is managed by pyenv, if not activate myenv
    if [[ ! $(which python) =~ .pyenv ]]; then
        echo "Python is not managed by pyenv, activating myenv..."
        eval "$(pyenv init -)"
        pyenv activate myenv
        if [[ ! $(which python) =~ .pyenv ]]; then
            echo "Error: Failed to activate myenv"
            return 1
        fi
        echo "Successfully activated myenv"
    fi

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
        db="concntric_db${selected_db}"
        echo "Selected: ${labels[$selected_index]} ($db)"
        zellij action rename-pane "${labels[$selected_index]} ($db)"
        DB_NAME=$db python manage.py runserver
    else
        echo "No database selected"
    fi
}

# Execute the function
run-django 