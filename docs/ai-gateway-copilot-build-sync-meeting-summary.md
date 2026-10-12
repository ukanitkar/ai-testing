# Endpoint AI Security sync — 2026-10-09

Summary of a call between Umesh and the other team covering AI Protect's endpoint coverage, the AI gateway merge path, and recurring MR build failures. Full transcript: `transcript.txt` in the Zoom recording folder (`Documents/Zoom/2026-10-09 16.38.28 Endpoint AI Security/`).

## Scope of AI Protect coverage

- GitHub Copilot is covered across all access mediums (VS Code extension, CLI, etc.) because Copilot exposes local hooks they can intercept.
- M365 Copilot (Word/PowerPoint/etc.) is **not** covered — M365 doesn't expose local hooks; it's web-based (file goes to cloud, processing happens there, result comes back), so there's no local execution to intercept.
- Their agent protects the **endpoint**, not the network layer — can't sit inside a cloud/Anthropic session or a cursor-cloud session.
- They protect the machine, and indirectly the data flowing through hooked apps, but not data once it's gone to the cloud.

## AI Gateway merge / collaboration

- A new `AI gateway` folder has been created under AI Protect; intent is to eventually merge this into the other team's main.
- Most of the work is isolated in its own folder, but some changes touch shared AI Protect code.
- Next step: work with **Jesven**, who has more context on the integration and merge requirements — he can advise on gating criteria.

## Build/CI failures on MRs

- Recurring build failures on MRs from feature branches → pseudo-main (`main-08272026`), with errors like "ran out of disk."
- Builds succeed locally and succeed when the other team runs them directly on GitHub — suggesting a **quota/configuration issue tied to external-collaborator status**, not a code problem.
- Likely cause: GitHub Actions runs on virtual cards (migrated from SquareX-era cards) with spending caps; when caps hit, finance has to top them up — can take a few days.
- Action: share a link/example of the failing build; the other team (admins: them + Jesven) will check if it's a quota allocation issue and whether finance needs to be engaged. Goal: resolve before the branch needs to merge into real main.

## Licensing

- The other team doesn't hold M365 Copilot licenses for testing — pointed toward **Gauri Shankar / Dakshin Murthy** or the Zscaler licensing team instead.
- Team previously had GitHub/other licenses via SquareX virtual carts, now migrating to Zscaler-owned licenses.
- Zero Trust Browser team (not this team) previously had a Copilot SKU/license for testing prompt capture via browser extension on copilot.microsoft.com — unclear if still active.

## Lowe's engagement

- There's an engagement with Lowe's testing "AI gateway + endpoint," using builds from branch `main-08272026` — the same branch already shared. No outstanding action, just confirming context.

## Logistics / wrap-up

- Other party heading back to Singapore ~Oct 29; Sean also returning end of month.
- Agreed to reconvene **Monday** — share the build-failure link before then.
