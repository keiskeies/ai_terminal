# Knowledge Database Version Management

## Overview
The knowledge database download section on www/index.html now supports dynamic version management. Instead of hardcoding version links, versions are managed through a JavaScript configuration array.

## How to Add a New Version

When you release a new version of the knowledge database (e.g., `knowledge-1.3.1.db`), follow these steps:

### 1. Upload the New Database File
Place the new `.db` file in the `www/knowledge/` directory:
```
www/knowledge/knowledge-1.3.1.db
```

### 2. Update the Version Configuration
Open `www/index.html` and locate the `knowledgeVersions` array (around line 1071):

```javascript
const knowledgeVersions = [
  {
    version: '1.3.1',      // New version number
    date: '2025-05-15',    // Release date (YYYY-MM-DD)
    size: '70 KB',         // File size
    isLatest: true         // Mark as latest
  },
  {
    version: '1.3.0',
    date: '2025-05-11',
    size: '68 KB',
    isLatest: false        // Set previous version to false
  }
];
```

### 3. Important Notes
- **Order matters**: List versions from newest to oldest
- **isLatest flag**: Only ONE version should have `isLatest: true`
- **File naming**: Ensure the actual file matches the pattern `knowledge-{version}.db`
- **Size accuracy**: Update the file size to match the actual file

### 4. Example: Adding Version 1.4.0

```javascript
const knowledgeVersions = [
  {
    version: '1.4.0',
    date: '2025-06-01',
    size: '75 KB',
    isLatest: true
  },
  {
    version: '1.3.1',
    date: '2025-05-15',
    size: '70 KB',
    isLatest: false
  },
  {
    version: '1.3.0',
    date: '2025-05-11',
    size: '68 KB',
    isLatest: false
  }
];
```

## Features
- ✅ Dynamic version rendering
- ✅ Multi-language support (English/Chinese)
- ✅ Automatic "Latest" badge for current version
- ✅ Easy to maintain - just update the array
- ✅ No HTML duplication

## Technical Details
The `renderKnowledgeVersions()` function automatically:
1. Generates download links based on version numbers
2. Displays "Latest" or "最新版本" for the current version
3. Shows release dates for older versions
4. Updates when language is switched
