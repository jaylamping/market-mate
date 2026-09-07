import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import doctor
import check_agent_context


class MigrationInspectionTests(unittest.TestCase):
    def test_whitespace_drift_is_detected_without_rewriting_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "0001_base.sql"
            source.write_bytes(b"SELECT 1;\n")
            applied = [{"version": 1, "name": "base", "checksum": hashlib.sha256(source.read_bytes()).hexdigest()}]
            self.assertEqual(doctor.migration_check(root, applied)[0], "pass")
            source.write_bytes(b"SELECT 1;\n\n")
            self.assertEqual(doctor.migration_check(root, applied)[0], "fail")
            self.assertEqual(source.read_bytes(), b"SELECT 1;\n\n")
            source.unlink()
            self.assertEqual(doctor.migration_check(root, applied)[0], "fail")

    def test_unapplied_source_is_distinct_from_checksum_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "0001_base.sql").write_text("SELECT 1;")
            self.assertEqual(doctor.migration_check(root, [])[0], "warn")

    def test_missing_runtime_does_not_run_mutations_or_claim_health(self):
        with patch.object(doctor.shutil, "which", return_value=None), patch.object(doctor, "run", return_value=None) as run:
            report = doctor.inspect(runtime=True)
        self.assertTrue(any(c["check"] == "migrations" and c["status"] == "warn" for c in report["checks"]))
        commands = [c.args[0] for c in run.call_args_list]
        self.assertIn(["docker", "compose", "ps", "--all", "--format", "json"], commands)
        self.assertFalse(any(word in command for command in commands for word in ["up", "down", "restart", "migrate", "fetch"]))


class ContextInspectionTests(unittest.TestCase):
    def test_missing_instructions_and_broken_link_report_errors_without_crashing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["README.md", "docs/architecture.md", "frontend/AGENTS.md"]:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("")
            (root / "README.md").write_text("[missing](docs/nonexistent.md)")
            with patch.object(check_agent_context, "ROOT", root):
                errors = check_agent_context.check()
            self.assertIn("Missing AGENTS.md", errors)
            self.assertTrue(any("Broken or external local link" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
