import json
import os
import tempfile
from pathlib import Path


def atomic_json(path, value):
    """Replace generated artifacts without following repository-owned symlinks."""
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix='.open-kritt-write-', suffix='.tmp')
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
            json.dump(value, handle, ensure_ascii=False)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
