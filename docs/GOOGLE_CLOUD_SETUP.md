# Google Cloud Setup Guide

## Prerequisites

- Google Account (personal Gmail or Google Workspace)
- Google Drive with sufficient storage (30TB recommended for 11TB library)
- macOS computer for development

---

## Step 1: Create Google Cloud Project

1. Go to [Google Cloud Console](https://console.cloud.google.com/)

2. Click the project dropdown at the top → **New Project**

3. Configure the project:
   - **Project name**: `PhotoVault` (or your preference)
   - **Organization**: Leave as-is (or select if using Workspace)
   - **Location**: Leave as-is

4. Click **Create**

5. Wait for project creation, then select it from the dropdown

---

## Step 2: Enable Google Drive API

1. In the Cloud Console, go to **APIs & Services** → **Library**

2. Search for **Google Drive API**

3. Click on it, then click **Enable**

4. Wait for activation (usually instant)

---

## Step 3: Configure OAuth Consent Screen

1. Go to **APIs & Services** → **OAuth consent screen**

2. Select User Type:
   - **External**: For personal use (anyone with Google account)
   - **Internal**: Only if using Google Workspace (organization only)
   
   For personal use, select **External** → **Create**

3. Fill in the OAuth consent screen:

   **App Information**:
   - App name: `PhotoVault`
   - User support email: Your email
   - App logo: Optional (skip for personal use)

   **App domain**: Leave blank for personal use

   **Developer contact information**:
   - Email: Your email

4. Click **Save and Continue**

5. **Scopes** page:
   - Click **Add or Remove Scopes**
   - Find and select: `https://www.googleapis.com/auth/drive.file`
   - This scope allows access ONLY to files created by the app
   - Click **Update**

6. Click **Save and Continue**

7. **Test users** (required for External apps in testing):
   - Click **Add Users**
   - Add your Google account email
   - Click **Add**

8. Click **Save and Continue**

9. Review summary, click **Back to Dashboard**

---

## Step 4: Create OAuth Credentials

1. Go to **APIs & Services** → **Credentials**

2. Click **Create Credentials** → **OAuth client ID**

3. Configure:
   - **Application type**: **Desktop app**
   - **Name**: `PhotoVault macOS`

4. Click **Create**

5. A dialog shows your credentials:
   - **Client ID**: `XXXXXX.apps.googleusercontent.com`
   - **Client Secret**: `GOCSPX-XXXXXXXXXX`

6. Click **Download JSON** to save credentials file

7. Click **OK**

---

## Step 5: Configure PhotoVault with Credentials

### Option A: Environment Variables (Recommended)

Create a `.env` file (do NOT commit to git):

```bash
GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-your-client-secret
```

### Option B: Direct Configuration

Update `PhotoVaultApp.swift`:

```swift
private let clientID = "your-client-id.apps.googleusercontent.com"
private let clientSecret = "GOCSPX-your-client-secret"
```

### Option C: Secure Storage

Store in Keychain at first launch, never hardcode.

---

## Step 6: Configure URL Scheme

The OAuth flow redirects back to your app via a custom URL scheme.

1. In Xcode, select your target → **Info** tab

2. Expand **URL Types**

3. Click **+** to add a new URL type:
   - **Identifier**: `com.yourname.photovault.oauth`
   - **URL Schemes**: `com.yourname.photovault`
   - **Role**: Editor

4. The redirect URI will be: `com.yourname.photovault:/oauth2callback`

5. This must match what you use in `GoogleDriveClient`:
   ```swift
   private let redirectURI = "com.yourname.photovault:/oauth2callback"
   ```

---

## Step 7: Handle OAuth Callback

In your `App` struct, handle the URL:

```swift
@main
struct PhotoVaultApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // Handle OAuth callback
                    if url.scheme == "com.yourname.photovault" {
                        handleOAuthCallback(url: url)
                    }
                }
        }
    }
}
```

---

## API Quotas and Limits

### Default Quotas

| Quota | Limit |
|-------|-------|
| Queries per day | 1,000,000,000 |
| Queries per 100 seconds per user | 1,000 |
| Queries per 100 seconds | 10,000 |

### Upload Limits

| Limit | Value |
|-------|-------|
| File size limit | 5 TB per file |
| Upload session duration | 1 week |
| Resumable upload chunk size | Min 256 KB |

### Recommendations

- Use 10 MB chunks for resumable uploads
- Implement rate limiting (100ms between requests)
- Use exponential backoff on 5xx errors
- Cache folder IDs to reduce lookup calls

---

## Scopes Reference

| Scope | Description | Use Case |
|-------|-------------|----------|
| `drive.file` | Access files created by app | **Use this** |
| `drive` | Full access to all files | Not needed |
| `drive.readonly` | Read-only access | Not sufficient |
| `drive.metadata` | Metadata only | Not sufficient |

**We use `drive.file`** because:
- Most restrictive scope that works
- Can only see/modify files we create
- Cannot access user's other Drive files
- Safer for users

---

## Publishing (Optional)

For personal use, you can stay in "Testing" mode permanently (up to 100 test users).

To publish for wider use:

1. OAuth consent screen → **Publish App**

2. Google will review your app

3. Requirements for verification:
   - Privacy policy URL
   - Terms of service URL
   - Homepage URL
   - Demonstrate scope usage
   - Security assessment (for sensitive scopes)

---

## Troubleshooting

### "Access blocked: This app's request is invalid"

- Verify redirect URI matches exactly
- Check client ID is correct
- Ensure user is added as test user

### "This app isn't verified"

- Expected for testing mode
- Click "Advanced" → "Go to PhotoVault (unsafe)"
- Or add yourself as test user

### "Rate Limit Exceeded"

- Reduce `maxConcurrentUploads` to 1-2
- Increase delay between requests
- Check quota usage in Cloud Console

### "Upload session expired"

- Sessions expire after 1 week of inactivity
- App automatically restarts expired uploads
- Check if upload URI is still valid before resuming

### "Invalid Credentials"

- Refresh token may have expired (6 months inactive)
- Re-authenticate user
- Check if OAuth consent was revoked

---

## Cost

**Google Drive API is free** for reasonable usage.

**Google Drive Storage** pricing (if exceeding free 15GB):

| Plan | Storage | Price |
|------|---------|-------|
| Google One 100GB | 100 GB | $1.99/month |
| Google One 200GB | 200 GB | $2.99/month |
| Google One 2TB | 2 TB | $9.99/month |
| Google One 5TB | 5 TB | $24.99/month |
| Google One 10TB | 10 TB | $49.99/month |
| Google One 20TB | 20 TB | $99.99/month |
| Google One 30TB | 30 TB | $149.99/month |

For 11TB library, you'll need at least Google One 20TB.

---

## Security Best Practices

1. **Never commit credentials** to version control
2. **Use Keychain** for token storage on macOS
3. **Minimal scope** (`drive.file` only)
4. **Validate redirect URIs** to prevent token theft
5. **Handle token refresh** securely
6. **Clear tokens** on sign-out
