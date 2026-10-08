#!/bin/sh
# Check the documentation tree against the source rules.
#
#   sh tools/check/doc_rules.sh
#
# The rules come from AGENTS.md:
#   - a document never uses the imperative mood,
#   - a document never refers to a file in plan/,
#   - a document never refers to a file in .ai/,
#   - a document never names a story,
#   - a document carries the pasdoc YAML front matter.
set -u

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 2

status=0

report() {
  echo "FAIL $1"
  shift
  for line in "$@"; do
    echo "     $line"
  done
  status=1
}

# 1. No reference to plan/, .ai/ or a story number.
hits=$(grep -rn 'plan/\|\.ai/\|[Ss]tory' doc/ 2>/dev/null)
if [ -n "$hits" ]; then
  report "doc/ refers to plan/, .ai/ or a story" "$hits"
else
  echo "PASS no document refers to plan/, .ai/ or a story"
fi

# 2. Every document starts with the pasdoc YAML front matter.
licence='LGPL-2.1-only WITH Independent-modules-exception'
bad=""
for f in $(find doc -name '*.md' | sort); do
  first=$(sed -n '1p' "$f")
  second=$(sed -n '2p' "$f")
  zero=$(sed -n '3p' "$f")
  last=$(awk 'NR>2 && $0=="---"{print "yes"; exit}' "$f")
  if [ "$first" != '{**' ] || [ "$second" != '---' ] ||
     [ "$zero" != "license: $licence" ] || [ "$last" != 'yes' ]; then
    bad="$bad $f"
  fi
done
if [ -n "$bad" ]; then
  report "the front matter is not the pasdoc YAML form" "$bad"
else
  echo "PASS every document carries the pasdoc YAML front matter"
fi

# 2a. No placeholder licence survives anywhere.
#     Two files must hold the string, because their job is to find it: the
#     check script itself and the licence test unit.  Both are skipped.
PLACEHOLDER='TBD-LICENCE'
hits=$(grep -rn "$PLACEHOLDER" src test examples doc tools Makefile Taskfile.yaml NOTICE LICENSE README.md 2>/dev/null \
  | grep -v '^tools/check/doc_rules.sh:' \
  | grep -v '^test/Http2Server.Licence.Test.pas:')
if [ -n "$hits" ]; then
  report "the placeholder licence is still present" "$hits"
else
  echo "PASS the placeholder licence is gone"
fi

# 2b. Every Pascal file header names the chosen licence expression.
bad=""
for f in $(find src test examples -name '*.pas' | sort); do
  grep -q "^license: $licence$" "$f" || bad="$bad $f"
done
if [ -n "$bad" ]; then
  report "a Pascal file names another licence" "$bad"
else
  echo "PASS every Pascal file names the chosen licence"
fi

# 3. Every document names the copyright holder.
missing=""
for f in $(find doc -name '*.md' | sort); do
  grep -q '^copyright: Copyright 2026 Liam Seamus Coughlin$' "$f" ||
    missing="$missing $f"
done
if [ -n "$missing" ]; then
  report "a document holds no copyright key" "$missing"
else
  echo "PASS every document names the copyright holder"
fi

# 4. Every document is reachable from the index.
notinindex=""
for f in $(find doc -name '*.md' -not -name README.md | sed 's|^doc/||' | sort); do
  grep -q "$f" doc/README.md || notinindex="$notinindex $f"
done
if [ -n "$notinindex" ]; then
  report "a document is not linked from doc/README.md" "$notinindex"
else
  echo "PASS every document is linked from doc/README.md"
fi

# 5. A sentence-initial verb is a rough test for the imperative mood. The
#    check reports the hits and lets a reader judge each one.
hits=$(grep -rnoE '(^|[.!?] )(Add|Write|Use|Set|Call|Read|Make|Check|Keep|Put|Run|Build|Hold|Avoid|See|Take|Give|Move|Remove|Ensure|Replace|Change|Report|Fix|Do not) [a-z]' doc/ 2>/dev/null | grep -v '\.md:[0-9]*:---')
if [ -n "$hits" ]; then
  report "a document may hold an imperative sentence" "$hits"
else
  echo "PASS the tree shows no imperative sentence"
fi

if [ "$status" -eq 0 ]; then
  echo "doc rules OK"
else
  echo "doc rules FAILED"
fi
exit "$status"
