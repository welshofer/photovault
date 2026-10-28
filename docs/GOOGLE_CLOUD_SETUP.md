# Google Cloud Setup Guide

Complete step-by-step guide to creating a Google Cloud project and OAuth credentials for PhotoVault.

**Time required:** ~10 minutes

---

## Prerequisites

- A Google account (personal Gmail or Google Workspace)
- Google Drive storage sufficient for your library (see [pricing](#cost) below)

---

## Step 1: Create a Google Cloud Project

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Click the **project dropdown** at the top of the page
3. Click **New Project**
4. Configure:
   - **Project name:** `PhotoVault` (or your preference)
   - **Organization:** Leave as default
   - **Location:** Leave as default
5. Click **Create**
6. Wait for the project to be created, then **select it** from the project dropdown

---

## Step 2: Enable the Google Drive API

1. In the Cloud Console sidebar, go to **APIs & Services** → **Library**
2. Search for **Google Drive API**
3. Click on it
4. Click **Enable**
5. Wait for activation (usually instant)

---

## Step 3: Configure the OAuth Consent Screen

This tells Google what your app is and what permissions it needs.

1. Go to **APIs & Services** → **OAuth consent screen**

2. Select **User Type:**
   - **External** — Choose this for personal use (anyone with a Google account)
   - **Internal** — Only available with Google Workspace

3. Click **Create**

4. Fill in **App Information:**

   | Field | Value |
   |-------|-------|
   | App name | `PhotoVault` |
   | User support email | Your email address |
   | App logo | Skip (optional) |

5. **App domain:** Leave all fields blank for personal use

6. **Developer contact information:** Enter your email

7. Click **Save and Continue**

8. **Scopes** page:
   - Click **Add or Remove Scopes**
   - Find and check these scopes:

   | Scope | Purpose |
   |-------|---------|
   | `https://www.googleapis.com/auth/drive.file` | Access files created by PhotoVault only |
   | `https://www.googleapis.com/auth/userinfo.email` | Display your email in Settings |
   | `https://www.googleapis.com/auth/userinfo.profile` | Display your name in Settings |

   - Click **Update**, then **Save and Continue**

9. **Test users** page:
   - Click **Add Users**
   - Enter the Google account email you'll use with PhotoVault
   - Click **Add**
   - Click **Save and Continue**

10. Review the summary and click **Back to Dashboard**

> **Important:** While your app is in "Testing" mode, only the test users you added can authenticate. This is fine for personal use — you can have up to 100 test users.

---

## Step 4: Create OAuth Credentials

1. Go to **APIs & Services** → **Credentials**

2. Click **Create Credentials** → **OAuth client ID**

3. Configure:
   - **Application type:** **Desktop app**
   - **Name:** `PhotoVault macOS`

4. Click **Create**

5. A dialog appears with your credentials:
   - **Client ID:** `XXXXXX.apps.googleusercontent.com`
   - **Client Secret:** `GOCSPX-XXXXXXXXXX`

6. **Copy both values** — you'll need them in the next step

7. Click **OK**

> **Security note:** The client secret for Desktop apps is not truly secret (it's embedded in the app binary). Google knows this — security relies on the user granting consent, not on the secret being hidden. This is standard for all desktop OAuth apps.

---

## Step 5: Configure PhotoVault

You have two options for providing credentials to PhotoVault:

### Option A: Environment Variables (recommended)

Create a `.env` file in the project root:

```bash
GOOGLE_CLIENT_ID=209153289523-xxxxx.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-xxxxxxxxxxxxx
```

Then set them in your Xcode scheme:
1. Product → Scheme → Edit Scheme (or `Cmd+<`)
2. Select **Run** in the sidebar
3. Go to the **Arguments** tab
4. Under **Environment Variables**, add:
   - `GOOGLE_CLIENT_ID` = your client ID
   - `GOOGLE_CLIENT_SECRET` = your client secret

### Option B: Edit Source (simpler)

Update the fallback values in `Sources/PhotoVaultApp.swift`:

```swift
private var clientID: String {
    ProcessInfo.processInfo.environment["GOOGLE_CLIENT_ID"]
        ?? "YOUR_CLIENT_ID_HERE.apps.googleusercontent.com"
}
private var clientSecret: String {
    ProcessInfo.processInfo.environment["GOOGLE_CLIENT_SECRET"]
        ?? "GOCSPX-YOUR_SECRET_HERE"
}
```

> **Warning:** If using Option B, do not commit your credentials to a public repository.

---

## Step 6: Authenticate

1. Launch PhotoVault
2. Click **Sign in with Google**
3. Your default browser opens to Google's consent page
4. Sign in with your Google account

   > If you see **"This app isn't verified"**: Click **Advanced** → **Go to PhotoVault (unsafe)**. This is expected for apps in testing mode.

5. Grant PhotoVault access to Google Drive
6. You'll see **"Authentication Successful"** in the browser
7. Return to PhotoVault — the sync dashboard appears
8. Check Settings (`Cmd+,`) to verify your account and storage

### How Authentication Works

PhotoVault uses a **loopback HTTP server** for the OAuth redirect:

1. A temporary HTTP server starts on `127.0.0.1` with a random port
2. PhotoVault generates a random `state` value and a PKCE code verifier for this sign-in attempt
3. The authorization URL includes `redirect_uri=http://127.0.0.1:<port>`, the `state`, and a `code_challenge` (SHA-256 of the verifier, `code_challenge_method=S256`)
4. After you grant consent, Google redirects your browser to the loopback server
5. PhotoVault accepts the redirect only if it is `GET /` and carries the same `state`; anything else is rejected and ignored
6. The code is exchanged for access + refresh tokens together with the PKCE `code_verifier`, so an intercepted code can't be redeemed without it
7. Tokens are stored securely in the macOS **Keychain**

This is Google's recommended approach for Desktop app clients. No custom URL schemes needed.

---

## API Quotas and Limits

### Default Quotas (free)

| Quota | Limit |
|-------|-------|
| Queries per day | 1,000,000,000 |
| Queries per 100 seconds per user | 1,000 |
| Queries per 100 seconds (project) | 10,000 |

### Upload Limits

| Limit | Value |
|-------|-------|
| Max file size | 5 TB per file |
| Resumable upload session | Expires after 1 week of inactivity |
| Min chunk size | 256 KB |
| Recommended chunk size | 10 MB (PhotoVault default) |

### PhotoVault Rate Limiting

PhotoVault enforces its own rate limit of **5 requests per second** (200ms between requests) to stay well within Google's limits. On 429/5xx errors, it uses exponential backoff with jitter.

---

## Scopes Reference

| Scope | What It Does | Why PhotoVault Needs It |
|-------|-------------|------------------------|
| `drive.file` | Access **only** files the app creates | Upload photos, create folders and manifests |
| `userinfo.email` | Read your email address | Display in Settings pane |
| `userinfo.profile` | Read your name | Display in Settings pane |

**What PhotoVault cannot do:**
- Cannot see your other Google Drive files
- Cannot delete files (even its own — Drive API with `drive.file` scope is append-focused)
- Cannot access your contacts, calendar, or any other Google service

---

## Cost

**Google Drive API usage is free** for reasonable volumes.

**Google Drive storage** pricing (if you need more than the free 15 GB):

| Plan | Storage | Price (US) |
|------|---------|------------|
| Google One Basic | 100 GB | $1.99/month |
| Google One Standard | 200 GB | $2.99/month |
| Google One Premium | 2 TB | $9.99/month |
| Google One 5 TB | 5 TB | $24.99/month |
| Google One 10 TB | 10 TB | $49.99/month |
| Google One 20 TB | 20 TB | $99.99/month |
| Google One 30 TB | 30 TB | $149.99/month |

> **Tip:** For an 11 TB library, you need at least the 20 TB plan. After deduplication, actual storage used will be less than your raw library size.

---

## Publishing Your App (Optional)

For personal use, you can stay in **"Testing" mode** permanently (up to 100 test users). No need to publish.

If you want to distribute PhotoVault to others:

1. Go to OAuth consent screen → **Publish App**
2. Google will require:
   - Privacy policy URL
   - Terms of service URL
   - A homepage for the app
   - Security assessment (for sensitive scopes)
3. Review takes 2-6 weeks

---

## Troubleshooting

### "Access blocked: This app's request is invalid"
- Verify your **Client ID** is correct
- Make sure you selected **Desktop app** as the application type (not Web application)
- Check that you added yourself as a **test user** in the consent screen

### "This app isn't verified"
- Expected for testing mode
- Click **Advanced** → **Go to PhotoVault (unsafe)**

### "Error: redirect_uri_mismatch"
- The OAuth client type must be **Desktop app**, not Web application
- Desktop app clients use `http://127.0.0.1:<port>` redirects, which Google allows automatically
- You do NOT need to configure redirect URIs in the Cloud Console for Desktop apps

### "Rate Limit Exceeded" (HTTP 429)
- PhotoVault handles this automatically with exponential backoff
- If it persists, try reducing `maxConcurrentUploads` to 1 or 2

### "Upload session expired" (HTTP 410)
- Upload sessions expire after 1 week of inactivity
- PhotoVault handles this automatically by restarting the upload with a fresh session
- No action needed

### "Invalid Credentials" / Token Errors
- Refresh tokens can expire after 6 months of inactivity
- Sign out (Settings → Sign Out) and sign in again
- Check if you revoked access at [myaccount.google.com/permissions](https://myaccount.google.com/permissions)

### OAuth window never completes
- Make sure no firewall is blocking localhost connections
- Try quitting and relaunching PhotoVault
- Check Console.app for `[PhotoVault]` log messages

---

## Security Best Practices

1. **Never commit credentials** to version control (`.env` is gitignored)
2. **Keychain storage** — Tokens are stored in macOS Keychain, not in files
3. **Minimal scope** — `drive.file` can only access files PhotoVault creates
4. **No plain-text secrets** — Use environment variables or Keychain
5. **Revoke access** if needed at [myaccount.google.com/permissions](https://myaccount.google.com/permissions)
