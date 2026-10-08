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
bad=""
for f in $(find doc -name '*.md' | sort); do
  first=$(sed -n '1p' "$f")
  second=$(sed -n '2p' "$f")
  zero=$(sed -n '3p' "$f")
  last=$(awk 'NR>2 && $0=="---"{print "yes"; exit}' "$f")
  if [ "$first" != '{**' ] || [ "$second" != '---' ] ||
     [ "$zero" != 'license: TBD-LICENCE' ] || [ "$last" != 'yes' ]; then
    bad="$bad $f"
  fi
done
if [ -n "$bad" ]; then
  report "the front matter is not the pasdoc YAML form" "$bad"
else
  echo "PASS every document carries the pasdoc YAML front matter"
fi

# 3. The placeholder licence is present in every document, so the licence
#    sweep of the licence story reaches all of them.
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
