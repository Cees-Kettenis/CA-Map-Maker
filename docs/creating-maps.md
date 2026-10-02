# Creating a map

Save your [Campfire token](campfire-credentials.md) first.

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

Use [My Community](my-community.md) to monitor a group. Club links are not supported in this meetup form. The Campfire account associated with your token
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
