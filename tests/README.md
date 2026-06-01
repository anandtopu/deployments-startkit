Place your test suites in your application repository.

Suggested folders:

```text
tests/unit/
tests/integration/
tests/e2e/
tests/regression/
tests/uat/
```

Suggested behavior:

- Unit tests should not need AWS.
- Integration tests can use Docker Compose, service containers, or local mocks.
- E2E, regression, and UAT tests should read the deployed app URL from `APP_BASE_URL`.

Example Python test:

```python
import os
import requests


def test_homepage_responds():
    base_url = os.environ["APP_BASE_URL"]
    response = requests.get(base_url, timeout=10)
    assert response.status_code < 500
```
