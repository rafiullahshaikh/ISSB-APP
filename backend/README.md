# Backend

This directory is reserved for the Qiyadat backend. The working frontend lives separately under `frontend/`.

The planned backend responsibilities are:

- FastAPI application and versioned API routes
- Input validation and consistent JSON responses
- Supabase authentication and database access
- WAT session and response persistence
- Secure image upload validation
- OCR processing and candidate text confirmation
- Environment-based secret management

Suggested future structure:

```text
backend/
├── app/
│   ├── main.py
│   ├── api/
│   ├── models/
│   ├── schemas/
│   ├── services/
│   └── core/
├── tests/
├── .env.example
└── requirements.txt
```

Do not place Supabase service keys, OCR credentials, or other secrets in frontend JavaScript or commit them to Git.

