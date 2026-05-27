# Sample payloads for the mock REST API

Drop the real `/ai/extract` JSON responses here. The mock server reads these
files and serves them verbatim so the shape matches production exactly.

## Naming

One file per dataset, named `<dataset>.json`:

```
employees.json
line_managers.json
user_data.json
expense_priv.json
```

If the **full** and **delta** responses have a different shape (not just
fewer rows), split them:

```
employees.full.json
employees.delta.json
```

If they're the same shape (delta = subset of rows), a single
`<dataset>.json` is enough — the mock will filter/echo as needed.

## Anything goes for now

Don't worry about trimming or anonymising unless you want to — this stays in
the (gitignored once we decide) working folder. Just drop what the API
returns and tell me which datasets you've covered.
