"""Archived compatibility entry point for the previous one-pass synthesis flow.

The maintained hierarchical Python synthesizer supersedes this retired script.
"""
from __future__ import annotations
import argparse, subprocess, sys
from pathlib import Path
def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--repository-root', default=str(Path(__file__).resolve().parents[2])); args = parser.parse_args(); repo = Path(args.repository_root).resolve()
    print('The archived one-pass synthesizer now delegates to the maintained hierarchical Python workflow.')
    subprocess.run([sys.executable, str(repo / 'scripts' / 'synthesize_kb_hierarchical_with_groq.py'), '--repository-root', str(repo)], check=True)
if __name__ == '__main__': main()
