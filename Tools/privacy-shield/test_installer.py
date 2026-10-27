"""Execute the real restart sequence with stubbed OS commands, never system audio."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class AudioRestartTests(unittest.TestCase):
    def run_restart(self, changed=True, kill_status=0):
        script = (Path(__file__).parent / 'install-driver.sh').read_text()
        restart = script[script.index('STEP="restarting system audio"'):]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # State is on disk because command substitutions run in subshells.
            prefix = '''set -euo pipefail
pgrep() {
  if [[ ! -f "$TEST_DIR/queried" ]]; then
    touch "$TEST_DIR/queried"; echo 479
  else
    echo "$TEST_NEW_PID"
  fi
}
killall() { echo "$*" > "$TEST_DIR/killed"; return "$TEST_KILL_STATUS"; }
sleep() { :; }
'''
            restart = restart.replace('/usr/bin/pgrep', 'pgrep').replace('/usr/bin/killall', 'killall').replace('/bin/sleep', 'sleep')
            result = subprocess.run(['/bin/bash', '-c', prefix + restart], capture_output=True, text=True,
                env={**os.environ, 'TEST_DIR': str(root), 'TEST_NEW_PID': '480' if changed else '479',
                     'TEST_KILL_STATUS': str(kill_status)})
            self.assertEqual((root / 'killed').read_text().strip(), '-KILL coreaudiod')
            return result

    def test_success_requires_a_replacement_process(self):
        result = self.run_restart()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('system audio restarted', result.stdout)

    def test_unchanged_process_is_not_success(self):
        result = self.run_restart(changed=False)
        self.assertEqual(result.returncode, 75)
        self.assertIn('system audio did not restart', result.stderr)

    def test_termination_failure_is_preserved(self):
        self.assertEqual(self.run_restart(kill_status=1).returncode, 1)
