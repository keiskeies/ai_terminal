# Local Fonts Setup Guide

## Current Status
The website currently uses **fonts.loli.net** (China-friendly Google Fonts mirror) for faster loading in China.

## Option 1: Using China-Friendly CDN (Current - Recommended)
✅ **Already configured** - No action needed!

The site uses `fonts.loli.net` which is a reliable mirror of Google Fonts that works well in China.

**Pros:**
- No additional files to download
- Automatic updates
- Smaller HTML file size
- Good performance in China

**Cons:**
- Still depends on external CDN
- May be blocked in some restricted networks

---

## Option 2: Using Completely Local Fonts (Zero External Dependencies)

If you want 100% offline capability with no external dependencies, follow these steps:

### Step 1: Download Font Files

Download the following font files and place them in `www/fonts/` directory:

#### JetBrains Mono (3 weights)
- **Regular (400)**: https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip
  - Extract: `JetBrainsMono-Regular.woff2` and `JetBrainsMono-Regular.woff`
- **Medium (500)**: Same zip file
  - Extract: `JetBrainsMono-Medium.woff2` and `JetBrainsMono-Medium.woff`
- **Bold (700)**: Same zip file
  - Extract: `JetBrainsMono-Bold.woff2` and `JetBrainsMono-Bold.woff`

#### Space Grotesk (5 weights)
Download from: https://github.com/floriankarsten/space-grotesk/releases
- **Light (300)**: `SpaceGrotesk-Light.woff2` and `SpaceGrotesk-Light.woff`
- **Regular (400)**: `SpaceGrotesk-Regular.woff2` and `SpaceGrotesk-Regular.woff`
- **Medium (500)**: `SpaceGrotesk-Medium.woff2` and `SpaceGrotesk-Medium.woff`
- **SemiBold (600)**: `SpaceGrotesk-SemiBold.woff2` and `SpaceGrotesk-SemiBold.woff`
- **Bold (700)**: `SpaceGrotesk-Bold.woff2` and `SpaceGrotesk-Bold.woff`

### Step 2: Update index.html

Replace lines 9-11 in `www/index.html`:

**Current (CDN):**
```html
<!-- Using China-friendly CDN for fonts -->
<link rel="preconnect" href="https://fonts.loli.net">
<link rel="preconnect" href="https://gstatic.loli.net" crossorigin>
<link href="https://fonts.loli.net/css2?family=JetBrains+Mono:wght@400;500;700&family=Space+Grotesk:wght@300;400;500;600;700&display=swap" rel="stylesheet">
```

**Change to (Local):**
```html
<!-- Using local fonts -->
<link href="fonts/local-fonts.css" rel="stylesheet">
```

### Step 3: Verify File Structure

Your `www/fonts/` directory should contain:
```
www/fonts/
├── local-fonts.css
├── JetBrainsMono-Regular.woff2
├── JetBrainsMono-Regular.woff
├── JetBrainsMono-Medium.woff2
├── JetBrainsMono-Medium.woff
├── JetBrainsMono-Bold.woff2
├── JetBrainsMono-Bold.woff
├── SpaceGrotesk-Light.woff2
├── SpaceGrotesk-Light.woff
├── SpaceGrotesk-Regular.woff2
├── SpaceGrotesk-Regular.woff
├── SpaceGrotesk-Medium.woff2
├── SpaceGrotesk-Medium.woff
├── SpaceGrotesk-SemiBold.woff2
├── SpaceGrotesk-SemiBold.woff
├── SpaceGrotesk-Bold.woff2
└── SpaceGrotesk-Bold.woff
```

### Step 4: Test

Open `www/index.html` in a browser and verify:
1. No network requests to external font CDNs
2. Fonts load correctly
3. Page displays properly

---

## Comparison

| Feature | CDN (Current) | Local Fonts |
|---------|--------------|-------------|
| Setup Complexity | ✅ None | ⚠️ Requires downloading fonts |
| Load Speed (China) | ✅ Fast | ✅ Fastest (no DNS lookup) |
| Offline Capability | ❌ No | ✅ Yes |
| File Size | ✅ Small HTML | ⚠️ Larger (~500KB fonts) |
| Maintenance | ✅ Auto-updates | ⚠️ Manual updates |
| Reliability | ⚠️ Depends on CDN | ✅ 100% reliable |

---

## Recommendation

**For most users**: Keep the current CDN setup (fonts.loli.net). It's fast, simple, and works well in China.

**For maximum reliability**: Use local fonts if you need:
- Complete offline functionality
- Zero external dependencies
- Maximum control over font rendering
- Deployment in highly restricted networks

---

## Quick Switch Commands

To quickly switch between CDN and local fonts:

### Switch to Local Fonts:
```bash
# Comment out CDN links and uncomment local fonts in index.html
sed -i '' 's|<!-- Using China-friendly CDN for fonts -->|<!-- Using local fonts -->|' www/index.html
sed -i '' 's|<link rel="preconnect" href="https://fonts.loli.net">|<!--<link rel="preconnect" href="https://fonts.loli.net">-->|' www/index.html
sed -i '' 's|<link rel="preconnect" href="https://gstatic.loli.net" crossorigin>|<!--<link rel="preconnect" href="https://gstatic.loli.net" crossorigin>-->|' www/index.html
sed -i '' 's|<link href="https://fonts.loli.net/css2.*|<!--<link href="https://fonts.loli.net/css2...">-->\n  <link href="fonts/local-fonts.css" rel="stylesheet">|' www/index.html
```

### Switch back to CDN:
Just reverse the changes or use git to restore the original file.
