#!/usr/bin/env python3
"""Remove only the preference suites derived from explicit diagnostic roots."""
import hashlib
import subprocess
import sys

for directory in sys.argv[1:]:
    suite = 'com.deskcapture.qa.' + hashlib.sha256(directory.encode()).hexdigest()[:24]
    subprocess.run(['/usr/bin/defaults', 'delete', suite], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
