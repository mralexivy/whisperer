import unittest
from benchmark import edits, error_rate, normalize, summarize, transcript_metrics

class BenchmarkTests(unittest.TestCase):
    def test_edit_operations(self):
        self.assertEqual(edits(['a','b','c'], ['a','x']), dict(substitutions=1,deletions=1,insertions=0,reference_units=3))
        self.assertEqual(error_rate(edits(['a'], ['b','c','d'])), 3)
    def test_multilingual(self):
        self.assertEqual(normalize('Hello, שלום! ПРИВЕТ.'), 'hello שלום привет')
        for phrase in ['שלום עולם', 'привет мир', 'hello שלום']:
            self.assertEqual(transcript_metrics(phrase, phrase, [])['wer'], 0)
    def test_facts_use_token_boundaries(self):
        self.assertEqual(transcript_metrics('pay 5', 'pay 15', ['5'])['literal_key_facts_recovered'], 0)
    def test_paired_and_stratified(self):
        row = dict(id='1', speaker='s1', language='he', engine='asr', condition='receiver', reference='שלום עולם', clean='שלום עולם', processed='טעות', split='evaluation')
        result = summarize([row])
        self.assertEqual(result['groups'][0]['wer_delta'], 1)
        self.assertIsNone(result['groups'][0]['speaker_bootstrap_95pct_wer_delta'])
        self.assertNotIn('שלום', str(result))
        with self.assertRaises(ValueError): summarize([row,row])
        with self.assertRaises(ValueError): summarize([dict(row, split='training')])
    def test_reference_required(self):
        with self.assertRaises(ValueError): transcript_metrics('', 'hallucination', [])

if __name__ == '__main__': unittest.main()

class RunnerTests(unittest.TestCase):
    def test_adapter_roundtrip_and_remote_gate(self):
        import json, sys, tempfile
        from pathlib import Path
        from benchmark import run_engines
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'clean.wav').touch(); (root / 'processed.wav').touch()
            manifest = root / 'manifest.jsonl'
            manifest.write_text(json.dumps(dict(id='one', speaker='s1', language='en', condition='unit-test',
                split='evaluation', reference='one two', clean_audio='clean.wav', processed_audio='processed.wav')))
            adapter = root / 'adapter.py'
            adapter.write_text('import sys\nfrom pathlib import Path\nPath(sys.argv[2]).write_text("one two" if Path(sys.argv[1]).name == "clean.wav" else "three four")\n')
            config = root / 'engines.json'
            engine = dict(name='fake-test-only', role='holdout', remote=True, command=[sys.executable, str(adapter), '{audio}', '{output}'])
            config.write_text(json.dumps(dict(engines=[engine])))
            with self.assertRaises(ValueError): run_engines(manifest, config, root / 'work', False)
            engine['remote'] = False
            config.write_text(json.dumps(dict(engines=[engine])))
            result = run_engines(manifest, config, root / 'work', False)
            self.assertEqual(result['groups'][0]['wer_delta'], 1)
            self.assertEqual(list((root / 'work').iterdir()), [])
            (root / 'work' / 'stale').touch()
            with self.assertRaises(ValueError): run_engines(manifest, config, root / 'work', False)
