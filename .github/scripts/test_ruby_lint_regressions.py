import unittest

from ruby_lint_regressions import regressions


class LintComparisonTest(unittest.TestCase):
    def test_only_preexisting_unworsened_offenses_are_accepted(self):
        def offense(message='Complexity [8/7]', line=1, cop='Metrics/CyclomaticComplexity'):
            return {'cop_name': cop, 'message': message, 'location': {'start_line': line}}

        original = offense()
        cases = [
            ([original], 'def old', 0),
            ([offense('Complexity [9/7]')], 'def old', 1),
            ([original], 'def new', 1),
            ([original, original], 'def old', 1),
            ([offense(line=2)], '\ndef old', 0),
            ([offense('Complexity [7/7]')], 'def old', 0),
            ([offense(cop='Layout/Indentation')], 'def old', 1),
        ]
        for index, (current, source, expected) in enumerate(cases):
            with self.subTest(case=index):
                new, _ = regressions(current, [original], source, 'def old')
                self.assertEqual(len(new), expected)


if __name__ == '__main__':
    unittest.main()
