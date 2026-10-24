import csv
import json
import sys
from collections import defaultdict
from pathlib import Path


def analyze(path: Path) -> dict:
    if not path.is_file() or not path.resolve().is_relative_to(Path('/inputs').resolve()):
        raise ValueError('Expected a mounted file under /inputs')
    if path.stat().st_size > 20 * 1024 * 1024:
        raise ValueError('File exceeds the mounted input limit')
    totals = defaultdict(float)
    top = None
    with path.open(newline='', encoding='utf-8-sig') as source:
        for row_number, row in enumerate(csv.DictReader(source), start=2):
            category = row['category'].strip()
            amount = float(row['amount'])
            totals[category] += amount
            if top is None or amount > top['amount']:
                top = {'row': row_number, 'category': category, 'amount': amount}
    return {'rows': row_number - 1 if top else 0, 'totals': dict(sorted(totals.items())), 'highest': top}


if __name__ == '__main__':
    print(json.dumps(analyze(Path(sys.argv[1])), sort_keys=True))
