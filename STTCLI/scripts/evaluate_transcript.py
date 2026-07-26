#!/usr/bin/env python3
import argparse
import re
import sys
from pathlib import Path
from typing import Sequence, Union


def normalize(text: str) -> str:
    text = text.lower()
    text = re.sub(r"[^a-z0-9\s']", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def distance(left: Union[Sequence[str], str], right: Union[Sequence[str], str]) -> int:
    previous = list(range(len(right) + 1))
    for i, left_value in enumerate(left, start=1):
        current = [i]
        for j, right_value in enumerate(right, start=1):
            current.append(
                min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (left_value != right_value),
                )
            )
        previous = current
    return previous[-1]


def extract_plain_transcript(text: str) -> str:
    if "FULL TRANSCRIPTION:" in text:
        return text.split("FULL TRANSCRIPTION:", 1)[1]
    return text


def rate(errors: int, total: int) -> float:
    if total == 0:
        return 0.0 if errors == 0 else 1.0
    return errors / total


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Evaluate an STT transcript against a reference using WER and CER."
    )
    parser.add_argument("reference", type=Path)
    parser.add_argument("hypothesis", type=Path)
    parser.add_argument("--max-wer", type=float, default=None)
    parser.add_argument("--max-cer", type=float, default=None)
    args = parser.parse_args()

    reference = normalize(args.reference.read_text(encoding="utf-8"))
    hypothesis = normalize(extract_plain_transcript(args.hypothesis.read_text(encoding="utf-8")))

    reference_words = reference.split()
    hypothesis_words = hypothesis.split()

    word_errors = distance(reference_words, hypothesis_words)
    char_errors = distance(reference, hypothesis)
    wer = rate(word_errors, len(reference_words))
    cer = rate(char_errors, len(reference))

    print(f"Reference words: {len(reference_words)}")
    print(f"Hypothesis words: {len(hypothesis_words)}")
    print(f"Word errors: {word_errors}")
    print(f"WER: {wer:.2%}")
    print(f"CER: {cer:.2%}")

    failed = False
    if args.max_wer is not None and wer > args.max_wer:
        print(f"WER exceeds threshold: {wer:.2%} > {args.max_wer:.2%}", file=sys.stderr)
        failed = True
    if args.max_cer is not None and cer > args.max_cer:
        print(f"CER exceeds threshold: {cer:.2%} > {args.max_cer:.2%}", file=sys.stderr)
        failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
