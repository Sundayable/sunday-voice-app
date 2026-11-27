# Trademark Notice — Sundayable & Sunday Voice

Copyright (C) 2026 Sundayable Inc. All rights reserved.

The names **Sundayable**, **Sunday Voice**, and **Sunday Voice by Sundayable**, together with the Sundayable wordmarks, app icons (`AppIcon.appiconset`), menu bar marks, and visual brand assets in this repository, are trademarks and brand assets of **Sundayable Inc.**

## What the Open-Source License Does and Does Not Grant

The open-core source code license (`AGPL-3.0-or-later` for the macOS client and local speech engines) grants broad rights to inspect, build, modify, and redistribute the code under AGPL-3.0 terms. It does **not** grant any license or right to use Sundayable Inc.'s trademarks, trade names, bundle identifiers, or logos.

## Rules for Forks and Redistributed Builds

If you modify or redistribute Sunday Voice (in source or binary form):

1. **Rebrand before distributing:** Change `APP_DISPLAY_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`, `URL_SCHEME`, and signing metadata in `identity.env` (and run `scripts/sync-identity.sh`) so your build does not use `Sunday Voice`, `Sundayable`, or `ca.sundayable.*`.
2. **Replace brand artwork:** Replace the Sundayable wordmark SVGs and `AppIcon` assets with your own marks.
3. **Permitted truthful attribution:** You may accurately state *"Based on Sunday Voice by Sundayable"* in documentation, READMEs, or About credits, provided it is clear your distribution is independent and not endorsed by or affiliated with Sundayable Inc.
4. **No confusing impersonation:** Do not distribute unmodified or modified binaries signed or packaged in a way that implies official Sundayable release, notarization, or cloud support.

For commercial licensing or brand inquiries, contact Sundayable Inc. (`hello@sundayable.com`).
