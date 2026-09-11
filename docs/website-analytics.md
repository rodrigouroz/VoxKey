# Website analytics

VoxKey's static website runs on GitHub Pages. `analytics.js` sends website events
to the **VoxKey** PostHog project (US Cloud, project `604593`):

- [Web analytics](https://us.posthog.com/project/604593/web): visitors, pageviews,
  traffic sources, campaigns, country, device, and web performance.
- [Project dashboards](https://us.posthog.com/project/604593/dashboard): download
  clicks and visitor-to-download conversion.

The project token in the JavaScript is public and write-only. No personal API key
or Cloudflare credential is required. The native Mac app never loads this script
and does not send these analytics.

## Events

PostHog captures pageviews, page leaves, web vitals, and masked interaction events.
`voxkey_download_clicked` records activation of a direct GitHub release link:

| Property | Meaning |
| --- | --- |
| `language` | Website language (`en` or `es`) |
| `placement` | Download link in `hero` or `install` |
| `release_version` | Version extracted from the GitHub release URL |
| `download_url` | Original GitHub release asset URL |
| `site` | Always `voxkey` |
| `is_test` | True when the page URL includes `analytics_test=1` |

Left click, keyboard activation, and middle click are measured. Context-menu
downloads, blocked analytics, completed transfers, and installations are not.
Repeated clicks count as repeated events; unique visitors are an approximation
based on browser identifiers. Analytics never delays or rewrites the download.

## Privacy and verification

An anonymous identifier persists in local storage on the website's origin.
Person profiles, session replay, surveys, heatmaps, and exception capture are
disabled. Autocaptured text and element attributes are masked. PostHog receives
standard web metadata, including URLs, referrers, device details, and IP-derived
location. Never put personal information in campaign URLs.

For browser verification, visit either language with `?analytics_test=1` and
activate a download link. Verify `voxkey_download_clicked` in PostHog with the
expected language, placement, version, and test flag. Reporting insights exclude
`is_test=true`; apply the same filter to ad-hoc reports. The production-origin
guard prevents localhost and preview sites from sending events.

When adding another download link, use `data-download-placement="hero"` or
`data-download-placement="install"` on its existing anchor. Keep the direct
GitHub URL. No changes to Sparkle updates or signed appcasts are necessary.
