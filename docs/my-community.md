# My Communities

Track multiple Campfire groups, then create a map of their meetups on a chosen day. Each group also keeps its own private map.

## Connect your group

1. Ask the administrator to configure the [shared Campfire token](campfire-credentials.md).
2. Open **My Communities**.
3. Paste one group or invitation link per line and select **Track groups**.
4. Select a group to manage its monitoring and private invitations.

Adding more links preserves your existing groups, maps, and invitations. Repeated links are ignored. You can pause each group separately.

Supported links include `https://campfire.onelink.me/...` invitations,
`https://cmpf.re/...` short links that resolve to a group, and direct links such
as `https://campfire.nianticlabs.com/discover/clubs/...`. An invitation must
identify a group, rather than an individual meetup. Your Campfire account must
be able to access that group; saving a link does not join it for you.

The first check fetches the community and its upcoming events. Subsequent checks run once a day. Each check follows all available pages of upcoming events.

Use **Update now** for an immediate refresh. The update panel shows when data was last updated and when the next update is scheduled.

Images are downloaded once per URL and served from local storage. Meetup cards and map popups show square cover photos and the host's name and profile picture when available. Meetups without a cover photo use their community's existing cached logo, including on maps that combine multiple communities. Newly imported pasted meetups can also use a tracked community logo through their Campfire group ID. Older pasted meetups need an update to record that ID. Meetups sharing a location appear in one popup with the next meetup first.

Finished meetups leave map pins when their Campfire end time passes. They are hidden from meetup lists by default; select **Show past meetups** to see them again. Meetups without an end time remain visible.

## Create a meetup map

1. Open **My Maps** and choose **Communities** under **Make a new map**.
2. Enter a name and select a date.
3. Check the groups to include and select **Create meetup map**.

Both the creation form and the map's community panel show up to five community rows at a time. Scroll to reach the remaining groups, or use **Search communities** to filter by name. Searching preserves checked and unchecked communities, including groups hidden by the filter.

The date covers the whole day using your browser's local time. Each map stays linked to its selected groups. New meetups appear as imports finish, and changed titles, locations, photos, and hosts update automatically. Events moved to another day leave that map. Duplicate meetups appear once.

If a selected group adds its meetup later, select **Find meetups from communities** on the date map. The side panel lists all your current communities, including groups added after you created the map, with the map's existing groups selected. Choose the groups to include and select **Save and find meetups**. This saves the selection and reloads meetups for the map's saved date from the local database, then reports how many new meetups it found. Closing the panel without saving leaves the selection unchanged. Unchecking a group removes its meetups from this map. This action does not contact Campfire or queue imports. The meetup must already be stored locally through community monitoring.

A new map may be empty while groups are still being discovered or imported. Open its linked communities to check progress and errors. **Update now** refreshes the selected events. Date maps read the community event records directly without copying them.

Date maps and group maps start private. To share a map publicly, open it from **My Maps** and select **Make public** beside **Export KML** and **Updates**, then **Copy public link**. On **My Communities**, **Manage public link** opens those controls for the selected group. Anyone with a public link can view the map without an account; editing remains restricted to you.

## Invite people to a group map

1. Under **Private sharing**, enter the person's account email and select **Invite**.
2. Select **Copy link** and send the community link to them.
3. They create or sign in to a confirmed account using that email.

Invitations grant read access to the map and its KML export. Visitors cannot
edit your map, change monitoring, or see your group invitation link, source
links, saved token, or invitation list. Access does not require membership
in the Campfire group.

Select **Revoke** beside an email to remove access. An open map checks access
again every few seconds. Downloaded files remain with their recipients.
Pogo Meetups does not send invitation emails; you send the link yourself.

## Pause monitoring or change groups

Clear **Monitor for new meetups** and save to pause discovery. Already queued
meetup imports can still finish. Enable it again to resume checks.

Changing the group link replaces the community map and clears its invitations.
Invite people again and send the new map link. The old map link stops working.
Deleting a community or its group map stops monitoring, removes its invitations, and unlinks it from date maps. Add its link again to track it later.

If a check fails, the message appears beside the group settings. Fix the link
or ask the administrator to replace the shared token as needed. Checks resume at the next interval. See
[troubleshooting](troubleshooting.md) for import failures.
