# Testing

## Unit suite

```
swift test
```

The suite covers the pure logic behind the `UsageProviding` seam: the decoder,
the `UsageStore` state machine (load/keep-last-good/backoff), the menu-bar
derivation, alerts, and countdowns. Providers and transport are injected, so no
network is touched.

## Reality gate (don't skip)

This is an integration feature: passing tests are necessary but **not
sufficient**. The original decoder shipped broken because every test used
invented JSON.

- The PRIMARY decoder fixture,
  `Tests/DashboardTests/Fixtures/oauth-usage-real.json`, is captured from the
  **real** API, not invented. `testDecodesRealCapturedFixture` loads it from
  disk. Refresh it whenever the endpoint shape may have changed:

  ```
  python3 ../claude_usage.py --raw   # prints the live /oauth/usage body
  ```

  and update the fixture with the sanitized result (keep the structure;
  numbers can be rounded).

- Before shipping a build, run the reality gate against the **live** endpoint:

  ```
  ./build-app.sh && open Dashboard.app
  ```

  Confirm the popover shows real gauges (not an error view).

## Rate limiting

The `/oauth/usage` endpoint rate-limits (HTTP 429). The app maps 429 to
`FetchError.rateLimited`, keeps the last-good gauges visible on a transient
failure (instead of blanking to the error screen), and backs off for 5 minutes
before fetching again. The gauges show a quiet "stale" hint while backing off.
