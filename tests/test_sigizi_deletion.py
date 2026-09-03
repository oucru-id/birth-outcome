"""Offline regression checks of the production deletion predicate.

Executes the actual SQL CASE expression in SQLite (same NULL/equality behavior).
This is NOT a BigQuery compilation or live-data test. All fixtures are synthetic.
Also emits a BigQuery-native fixture script to stdout with --emit-bigquery.
"""
from pathlib import Path
import json
import re
import sqlite3
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'sql/source_preparation/03_sigizi_source.sql'
SQL = SOURCE.read_text()
FUNCTIONS = SQL.split('-- BEGIN DELETION MATCH FUNCTIONS', 1)[1].split(
    '-- END DELETION MATCH FUNCTIONS', 1)[0]
FUNCTIONS = 'CREATE TEMP FUNCTION' + FUNCTIONS.split('CREATE TEMP FUNCTION', 1)[1]
BODY = re.search(r'RETURNS STRING AS \(\s*(CASE.*?)\s*\);', FUNCTIONS, re.S).group(1)
KEYS = ('s_nik', 's_name', 's_dob', 's_anchor', 'd_nik', 'd_name', 'd_dob', 'd_anchor')
BASE = dict(zip(KEYS, ('1111222233334444', 'synthetic mother', '1990-01-01', '2025-12-01',
                      '1111222233334444', 'synthetic mother', '1990-01-01', '2025-12-01')))
NIK = 'NIK_AND_PREGNANCY_ANCHOR'
FALLBACK = 'NAME_DOB_AND_PREGNANCY_ANCHOR'
CASES = [
    ('exact_nik_and_anchor', {}, NIK),
    ('same_mother_other_pregnancy', {'s_anchor': '2026-12-01'}, None),
    ('no_fuzzy_date_matching', {'s_anchor': '2025-12-02'}, None),
    ('missing_source_anchor', {'s_anchor': None}, None),
    ('missing_registry_anchor', {'d_anchor': None}, None),
    ('both_anchors_missing', {'s_anchor': None, 'd_anchor': None}, None),
    ('source_nik_missing', {'s_nik': None}, FALLBACK),
    ('registry_nik_missing', {'d_nik': None}, FALLBACK),
    ('both_niks_missing', {'s_nik': None, 'd_nik': None}, FALLBACK),
    ('conflicting_usable_niks', {'d_nik': '5555666677778888'}, None),
    ('fallback_wrong_birth_date', {'s_nik': None, 's_dob': '1991-01-01'}, None),
    ('fallback_missing_birth_date', {'s_nik': None, 's_dob': None}, None),
    ('fallback_missing_registry_birth_date', {'s_nik': None, 'd_dob': None}, None),
    ('fallback_wrong_name', {'s_nik': None, 's_name': 'other synthetic mother'}, None),
    ('fallback_missing_name', {'s_nik': None, 's_name': None}, None),
    ('fallback_missing_registry_name', {'s_nik': None, 'd_name': None}, None),
    ('nik_match_does_not_require_name', {'s_name': None, 'd_name': None}, NIK),
    ('nik_match_does_not_require_dob', {'s_dob': None, 'd_dob': None}, NIK),
]


class DeletionRegression(unittest.TestCase):
    def test_production_predicate(self):
        con = sqlite3.connect(':memory:')
        body = BODY
        for key in KEYS:
            body = re.sub(r'\b' + key + r'\b', ':' + key, body)
        for name, changes, expected in CASES:
            with self.subTest(name=name):
                self.assertEqual(con.execute('SELECT ' + body, BASE | changes).fetchone()[0], expected)
        con.close()

    def test_original_projection_is_preserved(self):
        self.assertIn('SELECT source_record.*\nFROM sigizi_deletion_decisions', SQL)
        self.assertIn('s AS source_record', SQL)
        self.assertIn('FROM normalized;', SQL)
        self.assertIn('LEFT JOIN sigizi_deletion_matches AS m USING (source_row_instance)', SQL)
        self.assertIn('GROUP BY s.source_row_instance;', SQL)

    def test_registry_is_not_in_clinical_union(self):
        union = SQL.split('WITH source_union AS (', 1)[1].split('extracted AS (', 1)[0]
        self.assertNotIn('bumil_hapus', union.lower())
        self.assertIn('vs_sigizi_bumil_hapus', SQL)

    def test_pregnancy_anchor_is_specific(self):
        self.assertIn('COALESCE(hpht_date, DATE_SUB(hpl_date, INTERVAL 280 DAY))', SQL)
        self.assertNotIn('DATE_DIFF', FUNCTIONS)

    def test_v3_registry_setup(self):
        setup = (ROOT / 'sql/setup/01a_sigizi_deleted_registry.sql').read_text()
        self.assertIn('kohort_bumil_v3.vs_sigizi_bumil_hapus', setup)
        self.assertIn('raw_data.sigizi_bumil_hapus_new', setup)
        self.assertNotIn('kohort_bumil_v2.', setup)
        self.assertRegex(setup, r'`no`,\s+uuid,')

    def test_function_copies_are_in_sync(self):
        validation = (ROOT / 'validation/91_sigizi_deletion_checks.sql').read_text()
        self.assertIn(FUNCTIONS.strip(), validation)
        native = (ROOT / 'tests/91_sigizi_deletion_regression.sql').read_text()
        self.assertIn(FUNCTIONS.strip(), native)


def emit_bigquery():
    print('-- Synthetic fixtures only; no production tables read or written.\n' + FUNCTIONS)
    print('CREATE TEMP TABLE deletion_test_results AS\nWITH fixtures AS (')
    for index, (name, changes, expected) in enumerate(CASES):
        row = BASE | changes
        fields = [json.dumps(name) + ' AS test_name']
        for key in KEYS:
            typ = 'DATE' if key.endswith(('_dob', '_anchor')) else 'STRING'
            value = 'NULL' if row[key] is None else json.dumps(row[key])
            fields.append(f'CAST({value} AS {typ}) AS {key}')
        fields.append('CAST(' + ('NULL' if expected is None else json.dumps(expected)) + ' AS STRING) AS expected')
        print(('SELECT ' if index == 0 else 'UNION ALL SELECT ') + ', '.join(fields))
    print(') SELECT *, deletion_match_rule(' + ', '.join(KEYS) + ') AS actual FROM fixtures;')
    print('SELECT test_name, expected, actual FROM deletion_test_results WHERE actual IS DISTINCT FROM expected;')
    print("ASSERT NOT EXISTS (SELECT 1 FROM deletion_test_results WHERE actual IS DISTINCT FROM expected) AS 'Deletion predicate regression';")
    print("ASSERT deletion_name_key('  SYNTHETIC-Mother.  ') = 'synthetic mother' AS 'Name normalization';")
    print("ASSERT deletion_name_key('   ') IS NULL AS 'Empty name';")
    print("ASSERT deletion_name_key(NULL) IS NULL AS 'Null name';")
    print("ASSERT COALESCE(CAST(NULL AS DATE), DATE_SUB(DATE '2026-09-07', INTERVAL 280 DAY)) = DATE '2025-12-01' AS 'HPL fallback';")
    print("ASSERT COALESCE(DATE '2025-12-02', DATE_SUB(DATE '2026-09-07', INTERVAL 280 DAY)) = DATE '2025-12-02' AS 'HPHT takes precedence';")
    print('''
-- Execute the production row-decision stages with duplicate registry hits and
-- duplicate source IDs. Matching must not multiply or silently deduplicate rows.
CREATE TEMP TABLE sigizi_source_unfiltered AS
SELECT 'DUPLICATED_SOURCE_ID' AS source_record_id,
  '1111222233334444' AS nik_clean, 'synthetic mother' AS nama_norm,
  'Synthetic Mother' AS nama, DATE '1990-01-01' AS tanggal_lahir,
  DATE '2025-12-01' AS hpht_date, CAST(NULL AS DATE) AS hpl_date
UNION ALL SELECT 'DUPLICATED_SOURCE_ID', '1111222233334444', 'synthetic mother',
  'Synthetic Mother', DATE '1990-01-01', DATE '2025-12-01', NULL
UNION ALL SELECT 'KEEP_OTHER_PREGNANCY', '1111222233334444', 'synthetic mother',
  'Synthetic Mother', DATE '1990-01-01', DATE '2026-12-01', NULL;
CREATE TEMP TABLE sigizi_deletion_registry AS
SELECT 'REGISTRY_A' AS source_record_id, 'DELETION_A' AS deleted_sigizi_pregnancy_key,
  '1111222233334444' AS nik_clean, 'synthetic mother' AS deletion_name_norm,
  DATE '1990-01-01' AS tanggal_lahir, DATE '2025-12-01' AS hpht_date,
  DATE '2026-01-01' AS tanggal_hapus_date
UNION ALL SELECT 'REGISTRY_B', 'DELETION_B', '1111222233334444',
  'synthetic mother', DATE '1990-01-01', DATE '2025-12-01', DATE '2026-01-02';
''')
    gate = 'CREATE TEMP TABLE sigizi_deletion_features AS' + SQL.split(
        'CREATE TEMP TABLE sigizi_deletion_features AS', 1)[1].split(
        'CREATE TEMP TABLE sigizi_deletion_run AS', 1)[0]
    print(gate)
    print("ASSERT (SELECT COUNT(*) FROM sigizi_deletion_decisions) = 3 AS 'Source multiplicity';")
    print("ASSERT (SELECT COUNTIF(ARRAY_LENGTH(deletion_matches) = 2) FROM sigizi_deletion_decisions) = 2 AS 'All duplicate registry references preserved';")
    print("ASSERT (SELECT COUNTIF(source_record.source_record_id = 'KEEP_OTHER_PREGNANCY' AND ARRAY_LENGTH(deletion_matches) = 0) FROM sigizi_deletion_decisions) = 1 AS 'Other pregnancy retained';")
    print("SELECT 'PASS' AS regression_status;")


if __name__ == '__main__':
    if '--emit-bigquery' in sys.argv:
        emit_bigquery()
    else:
        unittest.main()
