#!/bin/bash
# Automated release script for Jellyfin Plugin

set -e

# Configuration
REPO="sraja7272/jellyfin-plugin-media-bar"
BUILD_DIR="src/Jellyfin.Plugin.MediaBar/bin/Release/net9.0"
DLL_PATH="$BUILD_DIR/Jellyfin.Plugin.MediaBar.dll"
MANIFEST_FILE="manifest.json"

echo "=== Jellyfin Plugin Release Automation ==="
echo ""

# Fetch version and release notes from upstream repo
echo "Fetching latest release from upstream repo (IAmParadox27/jellyfin-plugin-media-bar)..."
UPSTREAM_RELEASE=$(curl -s https://api.github.com/repos/IAmParadox27/jellyfin-plugin-media-bar/releases/latest 2>/dev/null)

if [ -z "$UPSTREAM_RELEASE" ]; then
    echo "ERROR: Could not fetch upstream release information"
    exit 1
fi

# Extract version (tag_name)
VERSION=$(echo "$UPSTREAM_RELEASE" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
if [ -z "$VERSION" ] || [ "$VERSION" == "null" ]; then
    echo "ERROR: Could not parse version from upstream release"
    exit 1
fi

# Remove 'v' prefix if present
VERSION="${VERSION#v}"

# Validate version format
if ! [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid version format from upstream: $VERSION"
    exit 1
fi

TAG="v${VERSION}"

# Extract release notes (body)
RELEASE_NOTES=$(echo "$UPSTREAM_RELEASE" | grep -o '"body": "[^"]*"' | cut -d'"' -f4 | sed 's/\\n/\n/g' | sed 's/\\r//g')
if [ -z "$RELEASE_NOTES" ]; then
    RELEASE_NOTES="Release $TAG"
fi

echo "✓ Upstream version: $TAG"
echo "✓ Release notes fetched"
echo ""

# Show what will be released
echo "=== Release Summary ==="
echo "Version: $TAG"
echo ""
echo "Release Notes:"
echo "----------------------------------------"
echo "$RELEASE_NOTES"
echo "----------------------------------------"
echo ""

# Confirm before proceeding
if [ "$PREVIEW_ONLY" = "true" ]; then
    echo "Preview mode - stopping here. Approve the workflow to continue with the release."
    exit 0
elif [ -z "$CI" ]; then
    # Interactive mode (local execution)
    echo "Continue with this release? (y/n)"
    read -r CONFIRM
    if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
        echo "Release cancelled."
        exit 0
    fi
    echo ""
else
    # CI mode - already approved via environment, proceed automatically
    echo "Running in CI environment - proceeding with release"
    echo ""
fi

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    echo "ERROR: GitHub CLI (gh) is not installed"
    echo "Install it with: brew install gh"
    echo "Then authenticate with: gh auth login"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo "ERROR: Not authenticated with GitHub"
    echo "Run: gh auth login"
    exit 1
fi

# Build the plugin
echo "Building plugin..."
cd src/Jellyfin.Plugin.MediaBar
dotnet clean -c Release > /dev/null 2>&1
dotnet build -c Release --no-restore
cd ../..

if [ ! -f "$DLL_PATH" ]; then
    echo "ERROR: DLL not found at $DLL_PATH"
    exit 1
fi

echo "✓ Build successful!"
echo ""

# Calculate DLL checksum (for reference only)
echo "Calculating DLL checksum..."
if command -v md5sum &> /dev/null; then
    CHECKSUM=$(md5sum "$DLL_PATH" | awk '{print $1}')
elif command -v md5 &> /dev/null; then
    CHECKSUM=$(md5 -q "$DLL_PATH")
else
    echo "ERROR: Neither md5sum nor md5 found"
    exit 1
fi

echo "DLL MD5: $CHECKSUM"
echo ""

# Create ZIP package
echo "Creating ZIP package..."
ZIP_NAME="jellyfin-plugin-mediabar_${VERSION}.zip"
ZIP_PATH="$ZIP_NAME"

# Define all files to include in the package
DEPS_FILE="$BUILD_DIR/Jellyfin.Plugin.MediaBar.deps.json"
PDB_FILE="$BUILD_DIR/Jellyfin.Plugin.MediaBar.pdb"
LOGO_FILE="$BUILD_DIR/logo.png"

# Verify all required files exist
if [ ! -f "$DLL_PATH" ]; then
    echo "ERROR: DLL not found at $DLL_PATH"
    exit 1
fi

if [ ! -f "$DEPS_FILE" ]; then
    echo "ERROR: deps.json not found at $DEPS_FILE"
    exit 1
fi

if [ ! -f "$PDB_FILE" ]; then
    echo "ERROR: PDB not found at $PDB_FILE"
    exit 1
fi

if [ ! -f "$LOGO_FILE" ]; then
    echo "ERROR: logo.png not found at $LOGO_FILE"
    exit 1
fi

# Use -j to junk paths (don't include directory structure)
zip -j -q "$ZIP_PATH" "$DLL_PATH" "$DEPS_FILE" "$PDB_FILE" "$LOGO_FILE"

if [ ! -f "$ZIP_PATH" ]; then
    echo "ERROR: ZIP file not found at $ZIP_PATH"
    exit 1
fi

echo "✓ ZIP package created with all required files: $ZIP_PATH"
echo ""

# Calculate ZIP checksum (MD5 as required by Jellyfin)
echo "Calculating ZIP MD5 checksum..."
if command -v md5sum &> /dev/null; then
    ZIP_CHECKSUM=$(md5sum "$ZIP_PATH" | awk '{print $1}')
elif command -v md5 &> /dev/null; then
    ZIP_CHECKSUM=$(md5 -q "$ZIP_PATH")
else
    echo "ERROR: Neither md5sum nor md5 found"
    exit 1
fi

echo "ZIP MD5: $ZIP_CHECKSUM"
echo ""

# Create GitHub release
echo "Creating GitHub release $TAG..."
if gh release view "$TAG" --repo "$REPO" &> /dev/null; then
    echo "Release $TAG already exists. Deleting and recreating..."
    gh release delete "$TAG" --repo "$REPO" -y
fi

gh release create "$TAG" "$ZIP_PATH" \
    --repo "$REPO" \
    --title "$TAG" \
    --notes "$RELEASE_NOTES"

echo "✓ GitHub release created!"
echo ""

# Clean up ZIP file
rm -f "$ZIP_PATH"

# Update version numbers in all files
echo "Updating version numbers in project files..."

if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    # Update manifest.json - version and checksum
    sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"${VERSION}\"/" "$MANIFEST_FILE"
    sed -i '' "s/\"checksum\": \"[^\"]*\"/\"checksum\": \"$ZIP_CHECKSUM\"/" "$MANIFEST_FILE"
    sed -i '' "s|releases/download/v[0-9.]*/[^\"]*|releases/download/$TAG/jellyfin-plugin-mediabar_${VERSION}.zip|" "$MANIFEST_FILE"
    
    # Update build.yaml
    sed -i '' "s/^version: .*/version: \"${VERSION}\"/" build.yaml
    
    # Update .csproj file
    sed -i '' "s/<Version>[^<]*<\/Version>/<Version>${VERSION}<\/Version>/" src/Jellyfin.Plugin.MediaBar/Jellyfin.Plugin.MediaBar.csproj
    
    # Update MediaBarPlugin.cs (if it has a version comment)
    if grep -q "Version" src/Jellyfin.Plugin.MediaBar/MediaBarPlugin.cs; then
        sed -i '' "s/Version [0-9.]*/Version ${VERSION}/" src/Jellyfin.Plugin.MediaBar/MediaBarPlugin.cs
    fi
    
    # Update config.html (if it has version references)
    if grep -q "version" src/Jellyfin.Plugin.MediaBar/Configuration/config.html; then
        sed -i '' "s/v[0-9.]*<\/span>/v${VERSION}<\/span>/g" src/Jellyfin.Plugin.MediaBar/Configuration/config.html
        sed -i '' "s/version: '[0-9.]*'/version: '${VERSION}'/g" src/Jellyfin.Plugin.MediaBar/Configuration/config.html
    fi
else
    # Linux
    sed -i "s/\"version\": \"[^\"]*\"/\"version\": \"${VERSION}\"/" "$MANIFEST_FILE"
    sed -i "s/\"checksum\": \"[^\"]*\"/\"checksum\": \"$ZIP_CHECKSUM\"/" "$MANIFEST_FILE"
    sed -i "s|releases/download/v[0-9.]*/[^\"]*|releases/download/$TAG/jellyfin-plugin-mediabar_${VERSION}.zip|" "$MANIFEST_FILE"
    
    sed -i "s/^version: .*/version: \"${VERSION}\"/" build.yaml
    
    sed -i "s/<Version>[^<]*<\/Version>/<Version>${VERSION}<\/Version>/" src/Jellyfin.Plugin.MediaBar/Jellyfin.Plugin.MediaBar.csproj
    
    if grep -q "Version" src/Jellyfin.Plugin.MediaBar/MediaBarPlugin.cs; then
        sed -i "s/Version [0-9.]*/Version ${VERSION}/" src/Jellyfin.Plugin.MediaBar/MediaBarPlugin.cs
    fi
    
    if grep -q "version" src/Jellyfin.Plugin.MediaBar/Configuration/config.html; then
        sed -i "s/v[0-9.]*<\/span>/v${VERSION}<\/span>/g" src/Jellyfin.Plugin.MediaBar/Configuration/config.html
        sed -i "s/version: '[0-9.]*'/version: '${VERSION}'/g" src/Jellyfin.Plugin.MediaBar/Configuration/config.html
    fi
fi

echo "✓ Version numbers updated in all files!"
echo ""

# Commit and push all version changes
echo "Committing and pushing version updates..."
git add "$MANIFEST_FILE" build.yaml src/Jellyfin.Plugin.MediaBar/Jellyfin.Plugin.MediaBar.csproj src/Jellyfin.Plugin.MediaBar/MediaBarPlugin.cs src/Jellyfin.Plugin.MediaBar/Configuration/config.html
git commit -m "Release $TAG"
git push origin main

echo ""
echo "=== Release Complete! ==="
echo ""
echo "Repository URL: https://sraja7272.github.io/jellyfin-plugin-media-bar/manifest.json"
echo "Release page: https://github.com/$REPO/releases/tag/$TAG"
echo ""
echo "Users can now install the plugin from the repository!"
echo ""
