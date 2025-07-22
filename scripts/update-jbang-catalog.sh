#!/usr/bin/env bash

set -euo pipefail

# Check for required commands
for cmd in jq curl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed."
        exit 1
    fi
done

VERSION="$1"
CATALOG_FILE="${2:-jbang-catalog.json}"
MAX_VERSIONS="${3:-3}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [catalog-file] [max-versions]"
    echo "Example: $0 0.12.4-M1"
    exit 1
fi

if [ ! -f "$CATALOG_FILE" ]; then
    echo "Error: Catalog file '$CATALOG_FILE' not found"
    exit 1
fi

echo "Updating JBang catalog for version $VERSION..."

# Detect GitHub repository from git remote or use environment variable
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    # In GitHub Actions, use the GITHUB_REPOSITORY environment variable
    REPO_SLUG="$GITHUB_REPOSITORY"
else
    # Try to detect from git remote
    REPO_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
    if [ -n "$REPO_URL" ]; then
        # Extract owner/repo from various Git URL formats using sed
        if echo "$REPO_URL" | grep -q "github.com"; then
            REPO_SLUG=$(echo "$REPO_URL" | sed -E 's|.*github\.com[:/]([^/]+)/([^/.]+)(\.git)?.*|\1/\2|')
            # Validate the extraction worked
            if [ "$REPO_SLUG" = "$REPO_URL" ]; then
                echo "Warning: Could not parse repository from git remote: $REPO_URL"
                REPO_SLUG="BrokkAi/brokk"
            fi
        else
            echo "Warning: Remote is not a GitHub repository: $REPO_URL"
            REPO_SLUG="BrokkAi/brokk"
        fi
    else
        echo "Warning: No git remote found, using default repository"
        REPO_SLUG="BrokkAi/brokk"
    fi
fi

echo "Using repository: $REPO_SLUG"

# Create the new JAR URL
JAR_URL="https://github.com/${REPO_SLUG}/releases/download/${VERSION}/brokk-${VERSION}.jar"

# Check if the JAR URL exists (only in CI environment)
if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "Running in CI - checking if JAR exists at: $JAR_URL"

    MAX_RETRIES=5
    RETRY_DELAY=10
    attempt=1

    # Initial delay to allow GitHub to process the uploaded asset
    echo "Waiting 10s for GitHub to process the uploaded asset..."
    sleep 10

    while [ $attempt -le $MAX_RETRIES ]; do
        echo "Attempt $attempt/$MAX_RETRIES..."

        # Use --fail-with-body for better error handling across curl versions
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 30 "$JAR_URL" 2>/dev/null || echo "000")

        if [ "$HTTP_STATUS" = "200" ]; then
            echo "✓ JAR confirmed to exist at $JAR_URL"
            break
        fi

        if [ $attempt -eq $MAX_RETRIES ]; then
            echo "Error: JAR not found at $JAR_URL after $MAX_RETRIES attempts (HTTP status: $HTTP_STATUS)"
            echo "This could be due to:"
            echo "  - Release asset still being processed by GitHub"
            echo "  - Asset upload failed"
            echo "  - Network connectivity issues"
            echo "Please check the release page and try again in a few minutes."
            exit 1
        fi

        echo "JAR not yet available (HTTP status: $HTTP_STATUS). Retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
        attempt=$((attempt + 1))
    done
else
    echo "Running locally - skipping JAR URL check"
    echo "Target JAR URL: $JAR_URL"
fi

# Create new entry for this version
NEW_ENTRY=$(jq -n --arg version "brokk-$VERSION" --arg url "$JAR_URL" '{
    ($version): {
        "script-ref": $url,
        "java": "21",
        "java-options": ["--add-modules=jdk.incubator.vector"]
    }
}')

# Process the catalog: update main alias, keep previous main + 2 other previous versions
jq --arg url "$JAR_URL" --arg new_version "brokk-$VERSION" --arg repo_slug "$REPO_SLUG" --argjson max "$MAX_VERSIONS" '
    # Extract the current main version from its URL to create a versioned alias
    (.aliases.brokk."script-ref" | match(".*/download/([^/]+)/.*").captures[0].string) as $current_main_version |
    # Update main brokk alias to point to new version
    .aliases.brokk."script-ref" = $url |
    # Get existing versioned aliases (excluding main "brokk" and the new version)
    ([.aliases | to_entries | .[] |
      select(.key | startswith("brokk-")) |
      select(.key != "brokk") |
      select(.key != $new_version)] |
     sort_by(.key | gsub("brokk-"; "") | split(".") | map(tonumber? // 0)) |
     .[-($max-1):]) as $previous |
    # Create previous main version alias
    ("brokk-" + $current_main_version) as $previous_main_key |
    # Rebuild the aliases object with proper structure
    .aliases = (
        {"brokk": .aliases.brokk} +
        {($previous_main_key): {
            "script-ref": ("https://github.com/" + $repo_slug + "/releases/download/" + $current_main_version + "/brokk-" + $current_main_version + ".jar"),
            "java": "21",
            "java-options": ["--add-modules=jdk.incubator.vector"]
        }} +
        (($previous | reverse) | from_entries)
    )
' "$CATALOG_FILE" > "${CATALOG_FILE}.tmp"

# Move the updated file back
mv "${CATALOG_FILE}.tmp" "$CATALOG_FILE"

# Show what was done
VERSIONED_ALIASES=$(jq -r '[.aliases | to_entries | .[] | select(.key | startswith("brokk-")) | .key] | sort | join(", ")' "$CATALOG_FILE")
echo "Updated catalog:"
echo "- Main 'brokk' alias now points to: $JAR_URL"
echo "- Added versioned alias: brokk-$VERSION"
echo "- Kept latest $MAX_VERSIONS versioned aliases: $VERSIONED_ALIASES"

# Ensure the script ends with a newline
exit 0
