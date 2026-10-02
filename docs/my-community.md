# My Community

Connect one Campfire group to your account. Its upcoming meetups are discovered
in the background and added to a private map.

## Connect your group

1. Save your [Campfire token](campfire-credentials.md) in **Settings**.
2. Open **My Community**.
3. Paste the group's invitation link or direct group link.
4. Leave **Monitor for new meetups** enabled and select **Save community**.

Supported links include `https://campfire.onelink.me/...` invitations,
`https://cmpf.re/...` short links that resolve to a group, and direct links such
as `https://campfire.nianticlabs.com/discover/clubs/...`. An invitation must
identify a group, rather than an individual meetup. Your Campfire account must
be able to access that group; saving a link does not join it for you.

The first check runs in the background. Subsequent checks run every 10 minutes.
Each check reads a page of up to 100 upcoming meetups. Large groups continue
from the next page at the next check, then start over after the last page.
New meetup links use the existing [import queue](imports.md), including its
50-links-per-10-minutes limit across your maps.

Meetup cards and map popups show square cover photos and the host's name and profile picture when Campfire provides them. Meetups sharing a location appear in one popup with the next meetup first.

Select **View import progress** to inspect source errors or retry imports. For meetups imported before cover photos were supported, select **Refresh all links** once to fetch their photos and host details.
Discovery finds new meetups; use the map's refresh controls to update locations
that have already been imported. Existing locations stay on the map after a
meetup leaves Campfire's upcoming feed.

## Invite people to your map

1. Under **Private sharing**, enter the person's account email and select **Invite**.
2. Select **Copy link** and send the community link to them.
3. They create or sign in to a confirmed account using that email.

Invitations grant read access to the map and its KML export. Visitors cannot
edit your map, change monitoring, or see your group invitation link, source
links, saved token, or invitation list. Access does not require membership
in the Campfire group.

Select **Revoke** beside an email to remove access. An open map checks access
again every few seconds. Downloaded files remain with their recipients.
Campfire Atlas does not send invitation emails; you send the link yourself.

## Pause monitoring or change groups

Clear **Monitor for new meetups** and save to pause discovery. Already queued
meetup imports can still finish. Enable it again to resume checks.

Changing the group link replaces the community map and clears its invitations.
Invite people again and send the new map link. The old map link stops working.
Deleting the community map from **My Maps** removes its locations; save the
community settings again to create a replacement.

If a check fails, the message appears beside the group settings. Fix the link
or replace your token as needed. Checks resume at the next interval. See
[troubleshooting](troubleshooting.md) for import failures.
