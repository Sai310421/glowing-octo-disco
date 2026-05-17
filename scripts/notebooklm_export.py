#!/usr/bin/env python3
from pathlib import Path
import shutil

SOURCE = Path('docs/inbox')
TARGET = Path('exports/notebooklm')
TARGET.mkdir(parents=True, exist_ok=True)

for md in SOURCE.glob('*.md'):
    shutil.copy(md, TARGET / md.name)
    print(f'Exported {md.name}')
