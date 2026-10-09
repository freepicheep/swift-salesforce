#!/usr/bin/env python3
"""Pin a major's minimum supported Crypto version for CI compatibility testing."""
import pathlib, sys
version = {'4': '4.5.2', '5': '5.0.0'}[sys.argv[1]]
p = pathlib.Path('Package.swift')
s = p.read_text().replace('"4.5.2"..<"6.0.0"', 'exact: "' + version + '"')
p.write_text(s)
pathlib.Path('Package.resolved').unlink(missing_ok=True)
