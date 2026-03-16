"""Minimal TAP (Test Anything Protocol) v13 producer.

Produces TAP-compliant output for cluster validation checks.
No external dependencies — TAP is simple enough to emit directly.

See: https://testanything.org/tap-version-13-specification.html
"""

from dataclasses import dataclass, field


@dataclass
class TestResult:
    ok: bool
    description: str
    directive: str = ""
    diagnostic: list[str] = field(default_factory=list)


class TAPProducer:
    def __init__(self):
        self.results: list[TestResult] = []

    def ok(self, description: str) -> TestResult:
        r = TestResult(ok=True, description=description)
        self.results.append(r)
        return r

    def not_ok(self, description: str, **diagnostic: str) -> TestResult:
        diag = [f"{k}: {v}" for k, v in diagnostic.items()]
        r = TestResult(ok=False, description=description, diagnostic=diag)
        self.results.append(r)
        return r

    def skip(self, description: str, reason: str = "") -> TestResult:
        r = TestResult(
            ok=True,
            description=description,
            directive=f"SKIP {reason}".strip(),
        )
        self.results.append(r)
        return r

    def emit(self) -> int:
        """Print TAP output. Returns exit code: 0 = all pass, 1 = any fail."""
        print("TAP version 13")
        print(f"1..{len(self.results)}")
        failures = 0
        for i, r in enumerate(self.results, 1):
            status = "ok" if r.ok else "not ok"
            directive = f" # {r.directive}" if r.directive else ""
            print(f"{status} {i} - {r.description}{directive}")
            if r.diagnostic:
                print("  ---")
                for line in r.diagnostic:
                    print(f"  {line}")
                print("  ...")
            if not r.ok and "SKIP" not in (r.directive or ""):
                failures += 1
        return 1 if failures > 0 else 0
