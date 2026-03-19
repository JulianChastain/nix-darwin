#!/usr/bin/env bash
set -euo pipefail

# @azureOrg@ and @azureProject@ are substituted at build time by Nix (substituteAll).
bold="\033[1m"
reset="\033[0m"
ORG="@azureOrg@"
PROJECT="@azureProject@"
export WI_BASE="${ORG}/${PROJECT}/_workitems/edit"

osc_link() {
  # Usage: osc_link <url> <text> <width>
  local url="$1" text="$2" width="$3"
  local padded
  padded=$(printf "%-${width}s" "$text")
  printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$url" "$padded"
}

# ── Active Work Items ────────────────────────────────────────────────
echo -e "\n${bold}Work Items (assigned to me, active)${reset}\n"

wiql="SELECT [System.Id], [System.WorkItemType], [System.Title], [System.State], [System.AssignedTo] \
FROM WorkItems \
WHERE [System.AssignedTo] = @Me \
  AND [System.State] <> 'Closed' \
  AND [System.State] <> 'Removed' \
  AND [System.State] <> 'Done' \
ORDER BY [System.WorkItemType] ASC, [System.State] ASC, [System.ChangedDate] DESC"

story_json=$(az boards query --wiql "$wiql" -o json 2>&1)

echo "$story_json" | python3 -c "
import json, sys, os
wi_base = os.environ['WI_BASE']
rows = json.load(sys.stdin)
if not rows:
    print('  No active work items.')
    sys.exit(0)

hdr = f\"{'ID':<10}{'Type':<15}{'State':<15}{'Title'}\"
print(hdr)
print('─' * len(hdr))
for r in rows:
    f = r['fields']
    wid   = f['System.Id']
    wtype = f['System.WorkItemType']
    state = f['System.State']
    title = f['System.Title'][:60]
    link  = f'{wi_base}/{wid}'
    padded_id = str(wid).ljust(10)
    linked_id = f'\033]8;;{link}\033\\\\{padded_id}\033]8;;\033\\\\'
    print(f'{linked_id}{wtype:<15}{state:<15}{title}')
"

# ── Active Pull Requests ─────────────────────────────────────────────
echo -e "\n${bold}Pull Requests (created by me or assigned to review)${reset}\n"

pr_json=$(python3 -c "
import json, subprocess, sys

def get_prs(flag):
    result = subprocess.run(
        ['az', 'repos', 'pr', 'list', '--status', 'active', flag, 'me', '-o', 'json'],
        capture_output=True, text=True
    )
    return json.loads(result.stdout) if result.returncode == 0 else []

def get_linked_stories(pr_id):
    result = subprocess.run(
        ['az', 'repos', 'pr', 'work-item', 'list', '--id', str(pr_id), '-o', 'json'],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return []
    items = json.loads(result.stdout)
    return [
        str(wi['id']) for wi in items
        if wi.get('fields', {}).get('System.WorkItemType') == 'User Story'
    ]

created = get_prs('--creator')
reviewing = get_prs('--reviewer')

created_ids = {pr['pullRequestId'] for pr in created}
all_prs = created + [pr for pr in reviewing if pr['pullRequestId'] not in created_ids]

rows = []
for pr in all_prs:
    stories = get_linked_stories(pr['pullRequestId'])
    rows.append({
        'id':      pr['pullRequestId'],
        'role':    'Author' if pr['pullRequestId'] in created_ids else 'Reviewer',
        'title':   pr['title'][:55],
        'repo':    pr['repository']['name'],
        'creator': pr['createdBy']['displayName'],
        'date':    pr['creationDate'][:10],
        'link':    f\"{pr['repository']['url'].split('/_apis/')[0]}/_git/{pr['repository']['name']}/pullrequest/{pr['pullRequestId']}\",
        'stories': stories,
    })

rows.sort(key=lambda r: r['date'], reverse=True)
print(json.dumps(rows))
")

if [ "$(echo "$pr_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -eq 0 ]; then
    echo "  No active pull requests."
else
    echo "$pr_json" | python3 -c "
import json, sys, os
wi_base = os.environ['WI_BASE']
rows = json.load(sys.stdin)
hdr = f\"{'ID':<8}{'Role':<11}{'Created':<13}{'Creator':<25}{'Repository':<20}{'Story':<10}{'Title'}\"
print(hdr)
print('─' * len(hdr))
for r in rows:
    padded_id = str(r['id']).ljust(8)
    link_id = f'\033]8;;{r[\"link\"]}\033\\\\{padded_id}\033]8;;\033\\\\'
    if r['stories']:
        story_ids = []
        for sid in r['stories']:
            padded_sid = sid.ljust(10) if len(r['stories']) == 1 else sid
            story_ids.append(f'\033]8;;{wi_base}/{sid}\033\\\\{padded_sid}\033]8;;\033\\\\')
        story_col = ', '.join(story_ids)
    else:
        story_col = '—'.ljust(10)
    print(f\"{link_id}{r['role']:<11}{r['date']:<13}{r['creator']:<25}{r['repo']:<20}{story_col}{r['title']}\")
"
fi

echo ""
