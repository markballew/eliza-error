#!/bin/bash

# Script to squash commits while preserving one commit per author per day
# This maintains GitHub contribution activity while reducing repository size

set -e  # Exit on error

# Check if we're in a git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "Error: Not in a git repository"
  exit 1
fi

# Make sure we have a clean working directory
if ! git diff-index --quiet HEAD --; then
  echo "Error: You have uncommitted changes. Please commit or stash them first."
  exit 1
fi

# Check if target branch exists
if git show-ref --verify --quiet refs/heads/v2-squashed; then
  echo "Branch v2-squashed already exists. Do you want to overwrite it? (y/n)"
  read answer
  if [ "$answer" != "y" ]; then
    echo "Operation cancelled."
    exit 0
  fi
  git branch -D v2-squashed
fi

# Get the current branch
current_branch=$(git symbolic-ref --short HEAD)
echo "Current branch is $current_branch"

# Create a new branch for the squashed history
git checkout -b v2-squashed

# Get all commits in reverse order (oldest first)
echo "Analyzing commit history..."
commit_data=$(git log --reverse --pretty=format:"%H %an %ad %P" --date=short)

# Process the commit data to identify which commits to keep
keep_commits_file=$(mktemp)
previous_keys_file=$(mktemp)
merge_commits_file=$(mktemp)

while IFS=" " read -r hash author date parents rest; do
  # Check if this is a merge commit (has more than one parent)
  parent_count=$(echo "$parents" | wc -w)
  if [ "$parent_count" -gt 1 ]; then
    echo "$hash" >> "$merge_commits_file"
    echo "Detected merge commit: $hash by $author on $date"
  fi
  
  key="${author}:${date}"
  
  # Check if we've already seen this author:date combination
  if ! grep -q "^$key$" "$previous_keys_file"; then
    # This is the first commit by this author on this date, mark it to keep
    echo "$hash" >> "$keep_commits_file"
    echo "$key" >> "$previous_keys_file"
    echo "Keeping commit $hash by $author on $date"
  else
    echo "Will squash commit $hash by $author on $date"
  fi
done <<< "$commit_data"

# Now create a git filter-branch command to rewrite history
echo "Creating new squashed history..."

# Get the total number of commits
total_commits=$(echo "$commit_data" | wc -l)
echo "Total commits to process: $total_commits"

# Start the interactive rebase
git_commands_file=$(mktemp)

# Function to check if a commit is a merge commit
is_merge_commit() {
  grep -q "^$1$" "$merge_commits_file"
  return $?
}

# Get all commits in reverse order again for the rebase script
git log --reverse --pretty=format:"%H %an %ad %P" --date=short | while IFS=" " read -r hash author date parents rest; do
  if grep -q "^$hash$" "$keep_commits_file"; then
    # If it's a merge commit we want to keep, use the -m option
    if is_merge_commit "$hash"; then
      echo "pick $hash # merge" >> "$git_commands_file"
    else
      echo "pick $hash" >> "$git_commands_file"
    fi
  else
    # For merge commits we need to use a different approach, as 'fixup' doesn't work well
    if is_merge_commit "$hash"; then
      echo "# Skipping merge $hash - will handle with cherry-pick if needed" >> "$git_commands_file"
    else
      echo "fixup $hash" >> "$git_commands_file"
    fi
  fi
done

# Function to handle cleanup
cleanup() {
  rm -f "$git_commands_file" "$keep_commits_file" "$previous_keys_file" "$merge_commits_file"
}

# Function to check if there are merge conflicts
has_conflicts() {
  git status --porcelain | grep -q "^UU " || git status --porcelain | grep -q "^.U "
  return $?
}

# Function to handle rebase conflicts
handle_conflicts() {
  echo
  echo "Rebase encountered conflicts."
  echo "Options:"
  echo "  1. Abort the rebase and return to original branch"
  echo "  2. Open a shell for you to resolve conflicts manually"
  echo "  3. Skip the current commit and continue rebasing"
  echo "  4. Try to automatically use 'ours' strategy for all conflicts"
  echo
  echo "Enter your choice (1-4):"
  read choice

  case "$choice" in
    1)
      echo "Aborting rebase..."
      git rebase --abort
      git checkout "$current_branch"
      git branch -D v2-squashed
      cleanup
      echo "Returned to original branch $current_branch"
      exit 1
      ;;
    2)
      echo "Opening shell for manual conflict resolution."
      echo "Once you've resolved all conflicts, run:"
      echo "  git add <resolved-files>"
      echo "  git rebase --continue"
      echo "  exit"
      echo
      echo "To abort the rebase and the script, run:"
      echo "  git rebase --abort"
      echo "  exit 1"
      $SHELL
      if [ $? -ne 0 ]; then
        echo "Shell exited with an error. Aborting."
        git rebase --abort 2>/dev/null || true
        git checkout "$current_branch" 2>/dev/null || true
        cleanup
        exit 1
      fi
      ;;
    3)
      echo "Skipping current commit..."
      git rebase --skip
      return 0
      ;;
    4)
      echo "Attempting to use 'ours' strategy for all conflicts..."
      git status --porcelain | grep "^UU " | awk '{print $2}' | xargs -I{} git checkout --ours {} 2>/dev/null || true
      git status --porcelain | grep "^.U " | awk '{print $2}' | xargs -I{} git checkout --ours {} 2>/dev/null || true
      git add . 2>/dev/null || true
      git rebase --continue
      return 0
      ;;
    *)
      echo "Invalid choice. Aborting."
      git rebase --abort
      git checkout "$current_branch"
      git branch -D v2-squashed
      cleanup
      exit 1
      ;;
  esac
}

# Check if the todo file needs manual editing due to merge commits
echo "Checking if the rebase plan needs manual editing..."
if grep -q "^pick.*# merge" "$git_commands_file"; then
  echo "The rebase plan contains merge commits."
  echo "I'll open an editor for you to manually check and adjust the plan."
  echo "Press any key to continue..."
  read -n 1
  ${EDITOR:-nano} "$git_commands_file"
fi

# Perform the rebase with error handling
echo "Starting rebase. This may take a while..."
set +e  # Don't exit on error for this section

# Use a custom rebase approach to handle merge commits better
git_backup_dir=$(mktemp -d)
cp -r .git/* "$git_backup_dir"

# Use --rebase-merges to preserve merge commits
GIT_SEQUENCE_EDITOR="cat $git_commands_file >" git rebase -i --root --rebase-merges
rebase_status=$?

# Handle rebase conflicts if any
while [ $rebase_status -ne 0 ]; do
  # Simple check for merge conflicts by looking at git status
  if has_conflicts; then
    echo "Detected merge conflicts."
    handle_conflicts
    # Check if the conflicts were resolved
    rebase_status=$?
  elif [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
    # Could be a merge commit issue
    if grep -q "is a merge but no -m option was given" "$(git rev-parse --git-dir)/rebase-merge/message" 2>/dev/null; then
      echo "Detected an issue with a merge commit."
      echo "Options:"
      echo "  1. Edit the todo list manually"
      echo "  2. Skip this commit"
      echo "  3. Abort the rebase"
      read choice
      
      case "$choice" in
        1)
          git rebase --edit-todo
          git rebase --continue
          rebase_status=$?
          ;;
        2)
          git rebase --skip
          rebase_status=$?
          ;;
        3)
          git rebase --abort
          git checkout "$current_branch"
          git branch -D v2-squashed
          cleanup
          echo "Returned to original branch $current_branch"
          exit 1
          ;;
        *)
          echo "Invalid choice. Skipping commit."
          git rebase --skip
          rebase_status=$?
          ;;
      esac
    else
      # We're in some rebase state but not sure what's happening
      echo "In rebase state with issues."
      handle_conflicts
      rebase_status=$?
    fi
  else
    # Something else went wrong
    echo "Rebase failed but no conflicts detected. This could be due to:"
    echo "1. Non-conflict errors in the rebase process"
    echo "2. The repository structure or state preventing clean rebasing"
    echo
    echo "Options:"
    echo "  1. Abort and return to original branch"
    echo "  2. Try skipping the current problematic commit"
    echo "  3. Continue with what we have so far"
    echo
    echo "Enter your choice (1-3):"
    read choice
    
    case "$choice" in
      1)
        git rebase --abort 2>/dev/null || true
        git checkout "$current_branch" 2>/dev/null || true
        git branch -D v2-squashed 2>/dev/null || true
        cleanup
        echo "Returned to original branch $current_branch"
        exit 1
        ;;
      2)
        echo "Attempting to skip the problematic commit..."
        git rebase --skip 2>/dev/null || true
        rebase_status=$?
        ;;
      3)
        echo "Continuing with what we have so far..."
        break
        ;;
      *)
        echo "Invalid choice. Aborting."
        git rebase --abort 2>/dev/null || true
        git checkout "$current_branch" 2>/dev/null || true
        git branch -D v2-squashed 2>/dev/null || true
        cleanup
        exit 1
        ;;
    esac
  fi
  
  # If we're no longer in a rebase state, we're done
  if [ ! -d ".git/rebase-merge" ] && [ ! -d ".git/rebase-apply" ]; then
    break
  fi
done

# Reset error handling
set -e

# Clean up
cleanup
rm -rf "$git_backup_dir"

echo "Squashing complete! New branch 'v2-squashed' created."
echo "Number of commits in original branch: $total_commits"
new_commit_count=$(git rev-list --count HEAD)
echo "Number of commits in squashed branch: $new_commit_count"
authors_count=$(git log --format='%an' | sort -u | wc -l | tr -d ' ')
echo "Number of unique authors: $authors_count"

# Verify that we have at least one commit per author
echo "Checking for at least one commit per author..."
git log --format='%an' | sort | uniq -c | sort -nr | head -20

echo ""
echo "To push the squashed branch to remote:"
echo "  git push -f origin v2-squashed"
echo ""
echo "To switch back to your original branch:"
echo "  git checkout $current_branch"
