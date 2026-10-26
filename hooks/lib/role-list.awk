# Frontmatter task lists for the role guard. Prints one task per line for the
# requested key (read|run|act|inputless) and exits 3 on anything it does not
# fully understand, so the guard fails closed instead of guessing:
#   - tasks: at column 0, closed by the next top-level key or the closing ---
#   - only the four known sub-keys, each a block list of `- name` items
#   - names must match ^[a-z0-9_-]+(:[a-z0-9_-]+)+$
# Usage: awk -v key=read -f role-list.awk ROLE.md
BEGIN { fm = 0; intasks = 0; cur = ""; seen_tasks = 0 }
/\r$/ { print "role-list: CRLF line ending" > "/dev/stderr"; exit 3 }
/^---$/ { fm++; if (fm == 2) { exit } ; next }
fm != 1 { next }
/^tasks:[ \t]*$/ { if (seen_tasks) { print "role-list: duplicate tasks: key" > "/dev/stderr"; exit 3 }; seen_tasks = 1; intasks = 1; cur = ""; next }
intasks && /^[^ \t]/ { intasks = 0; cur = "" }
!intasks { next }
/^  (read|run|act|inputless):[ \t]*(\[\])?[ \t]*$/ { cur = $1; sub(":", "", cur); next }
/^  [A-Za-z_"'][^:]*:/ { print "role-list: unknown key under tasks: " $0 > "/dev/stderr"; exit 3 }
/^    - / {
  if (cur == "") { print "role-list: list item outside a known sub-key" > "/dev/stderr"; exit 3 }
  name = $0; sub(/^    - /, "", name); sub(/[ \t]+$/, "", name)
  if (name !~ /^[a-z0-9_-]+(:[a-z0-9_-]+)+$/) { print "role-list: bad task name: " name > "/dev/stderr"; exit 3 }
  if (cur == key) print name
  next
}
/^[ \t]*$/ { next }
{ print "role-list: unexpected line under tasks: " $0 > "/dev/stderr"; exit 3 }
END { if (fm < 2) { print "role-list: frontmatter not closed" > "/dev/stderr"; exit 3 } }
