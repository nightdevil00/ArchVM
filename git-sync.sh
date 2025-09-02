#!/bin/bash

# Fixed path to your repo
REPO_DIR="$HOME/ArchVM"

if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "Error: No Git repository found at $REPO_DIR"
    exit 1
fi

cd "$REPO_DIR" || exit 1
echo "Working in repo: $REPO_DIR"

# Detect current branch
BRANCH=$(git branch --show-current)
if [[ -z "$BRANCH" ]]; then
    echo "Error: Cannot determine current branch."
    exit 1
fi
echo "Current branch: $BRANCH"

# Check for changes
if [[ -z $(git status --porcelain) ]]; then
    CHANGES_EXIST=false
else
    CHANGES_EXIST=true
fi

# Menu
echo "Select action:"
echo "1) Pull latest changes"
echo "2) Push local changes"
read -rp "Enter 1 or 2: " choice

case "$choice" in
    1)
        git pull origin "$BRANCH"
        ;;
    2)
        if [[ "$CHANGES_EXIST" = false ]]; then
            echo "Nothing to commit. Push aborted."
            exit 0
        fi
        read -rp "Enter commit message: " msg
        git add -u
        git commit -m "$msg"
        git push origin "$BRANCH"
        ;;
    *)
        echo "Invalid option. Exiting."
        exit 1
        ;;
esac

