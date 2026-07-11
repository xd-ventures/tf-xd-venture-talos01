# SPDX-License-Identifier: Apache-2.0
# Copyright Maciej Sawicki

"""Unit tests for the stale-device selection logic (#312).

The acceptance case: a simulated sibling set (node-1/node-2/node-3 live plus
one stale incarnation) must delete only the stale device — cleanup for one
node can never touch a live sibling.
"""

import importlib.util
import pathlib
import unittest
from datetime import datetime, timedelta, timezone

_SCRIPT = pathlib.Path(__file__).resolve().parent.parent.parent / "modules" / "talos-cluster" / "scripts" / "tailscale-device-cleanup.py"
_spec = importlib.util.spec_from_file_location("tailscale_device_cleanup", _SCRIPT)
cleanup = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cleanup)

NOW = datetime(2026, 7, 10, 12, 0, 0, tzinfo=timezone.utc)


def _device(device_id, hostname, last_seen_minutes_ago=None):
    d = {"id": device_id, "hostname": hostname}
    if last_seen_minutes_ago is not None:
        d["lastSeen"] = (NOW - timedelta(minutes=last_seen_minutes_ago)).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
    return d


def _select(devices, hostname, cluster_hostnames=()):
    return cleanup.select_stale_devices(
        devices, hostname, cluster_hostnames, now=NOW
    )


class SelectStaleDevicesTest(unittest.TestCase):
    def test_sibling_set_deletes_only_the_stale_incarnation(self):
        """Ticket #312 acceptance: node-1/2/3 live + one stale incarnation."""
        cluster = ["node-1", "node-2", "node-3"]
        devices = [
            _device("d1", "node-1", last_seen_minutes_ago=1),  # target's old self
            _device("d2", "node-2", last_seen_minutes_ago=1),  # live sibling
            _device("d3", "node-3", last_seen_minutes_ago=1),  # live sibling
            _device("d4", "node-1-1", last_seen_minutes_ago=600),  # stale dedup
        ]
        to_delete, _ = _select(devices, "node-1", cluster)
        self.assertEqual(sorted(d["id"] for d in to_delete), ["d1", "d4"])

    def test_sibling_exact_name_never_deleted_even_when_offline(self):
        """Cleanup for a base name must not delete a suffix-named sibling."""
        cluster = ["talos-cp", "talos-cp-2"]
        devices = [_device("d2", "talos-cp-2", last_seen_minutes_ago=600)]
        to_delete, skipped = _select(devices, "talos-cp", cluster)
        self.assertEqual(to_delete, [])
        self.assertEqual(len(skipped), 1)
        self.assertIn("another cluster node", skipped[0][1])

    def test_exact_match_deleted_even_if_recently_online(self):
        """The node's own previous incarnation goes, reinstall is imminent."""
        devices = [_device("d1", "node-1", last_seen_minutes_ago=0)]
        to_delete, _ = _select(devices, "node-1", ["node-1"])
        self.assertEqual([d["id"] for d in to_delete], ["d1"])

    def test_recently_online_suffixed_device_skipped(self):
        devices = [_device("d4", "node-1-1", last_seen_minutes_ago=2)]
        to_delete, skipped = _select(devices, "node-1", ["node-1"])
        self.assertEqual(to_delete, [])
        self.assertIn("recently online", skipped[0][1])

    def test_offline_suffixed_device_deleted(self):
        devices = [_device("d4", "node-1-1", last_seen_minutes_ago=120)]
        to_delete, skipped = _select(devices, "node-1", ["node-1"])
        self.assertEqual([d["id"] for d in to_delete], ["d4"])
        self.assertEqual(skipped, [])

    def test_missing_last_seen_skipped_fail_safe(self):
        devices = [_device("d4", "node-1-1")]
        to_delete, skipped = _select(devices, "node-1", ["node-1"])
        self.assertEqual(to_delete, [])
        self.assertIn("not provably stale", skipped[0][1])

    def test_unrelated_hostnames_untouched(self):
        devices = [
            _device("d5", "gateway", last_seen_minutes_ago=600),
            _device("d6", "node-10", last_seen_minutes_ago=600),  # not node-1-N
        ]
        to_delete, skipped = _select(devices, "node-1", ["node-1"])
        self.assertEqual(to_delete, [])
        self.assertEqual(skipped, [])

    def test_regex_metacharacters_in_hostname_escaped(self):
        devices = [_device("d7", "nodeX1", last_seen_minutes_ago=600)]
        to_delete, _ = _select(devices, "node.1", ["node.1"])
        self.assertEqual(to_delete, [])


class NamingConflictTest(unittest.TestCase):
    def test_numeric_suffix_extension_detected(self):
        conflicts = cleanup.find_naming_conflicts(["talos-cp", "talos-cp-2"])
        self.assertEqual(conflicts, [("talos-cp", "talos-cp-2")])

    def test_safe_names_pass(self):
        self.assertEqual(
            cleanup.find_naming_conflicts(["talos-cp-1", "talos-cp-2", "talos-w-1"]),
            [],
        )

    def test_non_numeric_extension_is_not_a_conflict(self):
        self.assertEqual(
            cleanup.find_naming_conflicts(["talos", "talos-cp"]),
            [],
        )


if __name__ == "__main__":
    unittest.main()
