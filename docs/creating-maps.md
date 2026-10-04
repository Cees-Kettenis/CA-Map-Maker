# Creating a map

The administrator must configure the [shared Campfire token](campfire-credentials.md) first. To build a map for a date using tracked groups, follow [My Communities](my-community.md). For individual meetup links, choose **Paste links**.

1. Open **My Maps**.
2. Under **Make a new map**, enter a name and an optional description.
3. Choose **Private** for your own use or **Public** to share a link.
4. Paste one meetup link per line and select **Create Map**.
5. Open the map to check progress. Select a marker to see its meetup details and cover photo. Meetups at the same coordinates share a marker, with the soonest upcoming meetup first.

## Supported links

Use Campfire meetup or event links, including these forms:

```text
https://cmpf.re/...
https://campfire.nianticlabs.com/discover/meetup/...
https://campfire.nianticlabs.com/discover/meetups/...
https://campfire.nianticlabs.com/discover/events/...
https://niantic-social.nianticlabs.com/public/meetup/...
```

Use [My Communities](my-community.md) to monitor a group. Club links are not supported in this meetup form. The Campfire account associated with the shared token
must be able to access the meetups.

## Import behavior

Repeated links are removed from the submission. Different links resolving to
the same event produce one location on the map. Meetups without usable
coordinates cannot be plotted.

You can submit up to 10,000 links. Imports process up to 50 links every 10 minutes
across your maps, and continue after you leave the page.

See [import management](imports.md) for progress and retries, or
[sharing](sharing-maps.md) when your map is ready.

## Editing or deleting a map

Open the map and select **Edit map** to change its name, description, or
visibility. **Delete map** removes it and its imported locations permanently.

Meetup dates and times on cards and map popups use the viewer's browser time zone, including daylight saving. Time ranges show the date once, followed by the start and end times.

Update details are hidden initially. Use **Updates** beside **Export KML** to see the last update, scheduled update and **Update now** action. **Delete map** is the first map action and opens a confirmation dialog. Finished meetups are hidden from maps and exports; the list's **Show past meetups** toggle reveals their cards only. Community map cards use the group's locally cached Campfire icon when available.

For maps you create yourself, open **Edit map** to upload a square image. PNG, JPEG, WebP and GIF files up to 5 MB are supported. Save changes to use it on the map card and beside the title, including the shared page. Community maps use their Campfire group logo. Images are resized to at most 500 × 500 pixels without cropping or enlarging them, then stored locally as WebP at up to 100 KB.

Use **All Maps**, **Created Maps**, or **Community Maps** above the map cards to filter the list. Created maps include date maps you build from tracked communities. Community maps are the automatically created group maps.
