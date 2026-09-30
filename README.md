# Qiyadat — ISSB WAT Practice

Qiyadat is a mobile-first Word Association Test (WAT) practice prototype for ISSB candidates. The current release runs entirely in the browser with vanilla HTML, CSS, and JavaScript.

## Current user flow

```text
index.html
    ↓
wat-practice.html
    ↓
wat-results.html
    ↓
wat-dashboard.html
```

## Project structure

```text
.
├── frontend/
│   ├── index.html             # Landing page
│   ├── wat-practice.html      # Timed WAT practice session
│   ├── wat-results.html       # Latest-session results
│   ├── wat-dashboard.html     # Progress and session history
│   └── assets/
│       └── images/            # Frontend screenshots and images
├── backend/
│   └── README.md              # Backend boundary and planned API work
├── sources/                   # Read-only project reference material
├── .gitignore
└── README.md
```

All frontend pages stay together under `frontend/`, so their existing relative navigation continues to work. Backend code will live separately under `backend/` when implementation begins.

## Run locally

The pages can be opened directly, starting with `frontend/index.html`. For reliable shared `localStorage` behavior, serve the project through a simple local web server and open the local URL in a browser.

No packages or build step are required for the current frontend. A future GitHub Pages deployment will need to publish the `frontend/` directory through a workflow or copy its contents into the deployment artifact.

## Browser storage

The WAT flow currently uses:

- `issb_wat_latest_session` for the result currently being viewed.
- `issb_wat_session_history` for dashboard history.

This data stays in the user's browser and may be lost if browser storage is cleared. The planned backend will replace browser-only persistence with authenticated API storage.

## Current scope

- Responsive landing page
- Training and Simulation WAT modes
- Typing and Paper response modes
- Timed word progression
- Session result review
- Local progress dashboard

## Planned backend

The backend will be added after the frontend flow is stable. Planned work includes FastAPI endpoints, Supabase persistence, authentication, secure image uploads, and OCR processing. API credentials and service keys must remain in backend environment variables and must never be committed.

## Disclaimer

Qiyadat is an independent preparation project. It is not affiliated with ISSB, the Pakistan Armed Forces, or any government organization. Practice statistics are not an official psychological assessment or selection prediction.

