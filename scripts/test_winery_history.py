"""Behaviour checks for durable history collection and backup boundaries."""
import gzip
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('archive', Path(__file__).with_name('winery-history.py'))
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)
NOW = datetime(2026, 9, 15, 5, 15, tzinfo=timezone.utc)


def history(url, token, start, end):
    return [[{'entity_id': entity, 'state': state, 'last_changed': archive.iso(start+timedelta(seconds=i)),
              'last_updated': archive.iso(start+timedelta(seconds=i)), 'attributes': {'unit_of_measurement': 'L'}}
             for i, state in enumerate(['100', 'unavailable', '120', '0', '10'])]
            for entity in archive.ENTITIES]


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)/'archive'
        self.root.mkdir()
        self.credential = Path(self.temp.name)/'credential'
        self.credential.write_text('HA_TOKEN=test-only\n')
        self.destination = Path(self.temp.name)/'backup'
        self.destination.mkdir()

    def collect(self, getter=history, now=NOW):
        archive.collect(self.root, 'https://example.invalid', self.credential, now=now, getter=getter)

    def test_retains_original_outage_reset_and_timestamps(self):
        self.collect()
        files = list((self.root/'chunks').glob('*.gz'))
        self.assertEqual(len(files), 10)
        document = json.loads(gzip.decompress(files[0].read_bytes()))
        original = history('', '', datetime.fromisoformat(document['query_start']), None)
        self.assertEqual(document['history'], original)
        self.assertEqual(document['quality']['unavailable_records'][archive.ENTITIES[0]], 1)
        self.assertEqual(archive.read_json(self.root/'capture.json')['through'], '2026-09-15T05:00:00+00:00')

    def test_retry_is_idempotent_and_continues_after_committed_boundary(self):
        self.collect()
        before = {p.name:p.read_bytes() for p in (self.root/'chunks').glob('*.gz')}
        self.collect(getter=lambda *args: self.fail('Already archived interval fetched again'))
        self.assertEqual(before, {p.name:p.read_bytes() for p in (self.root/'chunks').glob('*.gz')})
        self.collect(now=NOW+timedelta(hours=1))
        self.assertEqual(len(list((self.root/'chunks').glob('*.gz'))), 11)

    def test_failure_does_not_advance_cursor(self):
        self.collect()
        before = (self.root/'capture.json').read_bytes()
        with self.assertRaises(ValueError):
            self.collect(getter=lambda *args: [], now=NOW+timedelta(hours=1))
        self.assertEqual(before, (self.root/'capture.json').read_bytes())

    def test_missing_one_entity_is_not_success(self):
        with self.assertRaises(ValueError):
            self.collect(getter=lambda *args: history(*args)[:-1])
        self.assertFalse((self.root/'capture.json').exists())

    def test_crash_after_chunk_write_recovers_without_network(self):
        self.collect()
        state = archive.read_json(self.root/'capture.json')
        state['through'] = '2026-09-14T05:00:00+00:00'
        archive.save_json(self.root/'capture.json', state)
        self.collect(getter=lambda *args: self.fail('Durable chunk should be recovered'))
        self.assertEqual(archive.read_json(self.root/'capture.json')['through'], '2026-09-15T05:00:00+00:00')

    def test_verified_backup_and_corruption_detection(self):
        self.collect()
        archive.backup(self.root, self.destination)
        state = archive.read_json(self.root/'capture.json')
        self.assertEqual((self.root/state['chunk']).read_bytes(), (self.destination/state['chunk']).read_bytes())
        self.assertEqual((self.destination/state['chunk']).stat().st_mode & 0o777, 0o644)
        (self.destination/state['chunk']).write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            archive.backup(self.root, self.destination)

    def test_collection_continues_without_backup(self):
        self.collect()
        self.collect(now=NOW+timedelta(hours=1))
        self.assertFalse((self.root/'backup.json').exists())
        self.assertEqual(archive.read_json(self.root/'capture.json')['through'], '2026-09-15T06:00:00+00:00')

    def test_long_outage_is_recorded_as_gap(self):
        archive.save_json(self.root/'capture.json', {'through': archive.iso(NOW-timedelta(days=20))})
        self.collect()
        gap = archive.read_json(next((self.root/'gaps').glob('*.json')))
        self.assertEqual(gap['start'], archive.iso(NOW-timedelta(days=20)))
        self.assertEqual(gap['end'], '2026-09-05T05:00:00+00:00')

    def test_failed_checkpoint_write_leaves_previous_state_intact(self):
        self.collect()
        old = (self.root/'capture.json').read_bytes()
        with patch.object(archive.os, 'replace', side_effect=OSError('disk failure')):
            with self.assertRaises(OSError):
                archive.save_json(self.root/'capture.json', {'through':'wrong'})
        self.assertEqual(old, (self.root/'capture.json').read_bytes())


if __name__ == '__main__':
    unittest.main()
