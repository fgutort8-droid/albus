# albus-app.netlify.app

Static privacy (`/privacy/`) and support (`/support/`) pages. No build step.
The app links to these paths from `AppLinks.swift`.

**Not published yet.** The support address is approved: fgutort8@gmail.com.
Before publishing, account deletion must be finished and merged. The pages also
require the payments app and backend changes, because they describe subscriptions,
Restore purchases and Manage subscription. Do not publish these promises while
those features are only on an unmerged branch. The owner deploys the backend.

The privacy audit is recorded in `privacy-audit.md`. Keep it current when changing
marking, authentication, retention or billing. In particular, saved marking
feedback includes short excerpts: do not promise that no submitted text is stored.
